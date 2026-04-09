import Foundation
import JavaScriptCore

// MARK: - WebBrowser: High-Level Browser API
// Navigate, extract, fill forms, execute JS — like Playwright but native Swift.
// Uses WebClient for HTTP, HTMLParser for DOM, JavaScriptCore for JS eval.

public final class WebBrowser: @unchecked Sendable {
    public let client: WebClient
    public let parser: HTMLParser
    private let jsContext: JSContext
    private var currentURL: String = ""
    private var currentDoc: HTMLDocument?
    private var currentHTML: String = ""
    private var pageHistory: [(url: String, title: String, timestamp: Date)] = []

    public init() {
        self.client = WebClient()
        self.parser = HTMLParser()
        self.jsContext = JSContext()!
        setupJSContext()
    }

    @available(*, deprecated, message: "Stealth mode has been removed. Use explicit assessment policy and accountable egress.")
    public convenience init(stealthMode: Bool) {
        self.init()
    }

    // MARK: - Navigation

    public func navigate(_ url: String) -> BrowseResult {
        let fullURL = url.contains("://") ? url : "https://\(url)"
        let start = DispatchTime.now()
        let response = client.get(fullURL)

        guard response.isSuccess else {
            return BrowseResult(url: fullURL, title: "", status: response.statusCode,
                               latencyMs: response.latencyMs, text: "", links: [],
                               forms: [], meta: [:], headers: response.headers, error: "HTTP \(response.statusCode)")
        }

        currentURL = response.url
        currentHTML = response.body
        currentDoc = parser.parse(response.body)

        let doc = currentDoc!
        pageHistory.append((doc.title.isEmpty ? response.url : doc.title, response.url, Date()))

        return BrowseResult(
            url: response.url,
            title: doc.title,
            status: response.statusCode,
            latencyMs: response.latencyMs,
            text: doc.text,
            links: doc.links,
            forms: doc.forms,
            meta: doc.meta,
            headers: response.headers,
            error: nil
        )
    }

    // MARK: - CSS Selector Query

    public func select(_ selector: String) -> [HTMLElement] {
        guard let doc = currentDoc else { return [] }
        return parser.querySelectorAll(elements: doc.elements, selector: selector)
    }

    public func selectFirst(_ selector: String) -> HTMLElement? {
        select(selector).first
    }

    public func selectText(_ selector: String) -> [String] {
        select(selector).map(\.textContent)
    }

    public func selectAttr(_ selector: String, attr: String) -> [String] {
        select(selector).compactMap { $0.attributes[attr] }
    }

    // MARK: - Text Extraction

    public func extractText() -> String {
        currentDoc?.text ?? ""
    }

    public func extractLinks() -> [String] {
        currentDoc?.links ?? []
    }

    public func extractHeadings() -> [(level: Int, text: String)] {
        var headings: [(Int, String)] = []
        for level in 1...6 {
            let elements = select("h\(level)")
            for el in elements {
                headings.append((level, el.textContent))
            }
        }
        return headings.sorted { $0.0 < $1.0 }
    }

    public func extractImages() -> [(src: String, alt: String)] {
        select("img").map { ($0.src ?? "", $0.attributes["alt"] ?? "") }
    }

    public func extractTableData() -> [[String]] {
        var rows: [[String]] = []
        let trElements = select("tr")
        for tr in trElements {
            let cells = tr.children.filter { $0.tag == "td" || $0.tag == "th" }
            rows.append(cells.map(\.textContent))
        }
        return rows
    }

    // MARK: - Form Interaction

    public func submitForm(index: Int = 0, data: [String: String] = [:]) -> BrowseResult {
        guard let doc = currentDoc, index < doc.forms.count else {
            return BrowseResult(url: currentURL, title: "", status: 0, latencyMs: 0,
                               text: "", links: [], forms: [], meta: [:], headers: [:], error: "No form at index \(index)")
        }

        let form = doc.forms[index]
        var formData: [String: String] = [:]

        // Pre-fill with default values from form
        for input in form.inputs where !input.name.isEmpty {
            formData[input.name] = input.value
        }
        // Override with provided data
        for (key, value) in data {
            formData[key] = value
        }

        // Resolve action URL
        let action: String
        if form.action.isEmpty || form.action == "#" {
            action = currentURL
        } else if form.action.hasPrefix("http") {
            action = form.action
        } else if form.action.hasPrefix("/") {
            if let base = URL(string: currentURL) {
                action = "\(base.scheme ?? "https")://\(base.host ?? "")\(form.action)"
            } else {
                action = form.action
            }
        } else {
            action = currentURL + "/" + form.action
        }

        let response: WebResponse
        if form.method == "POST" {
            response = client.post(action, formData: formData)
        } else {
            let query = formData.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
            response = client.get("\(action)?\(query)")
        }

        if response.isSuccess || response.isHTML {
            currentURL = response.url
            currentHTML = response.body
            currentDoc = parser.parse(response.body)
        }

        return BrowseResult(
            url: response.url,
            title: currentDoc?.title ?? "",
            status: response.statusCode,
            latencyMs: response.latencyMs,
            text: currentDoc?.text ?? "",
            links: currentDoc?.links ?? [],
            forms: currentDoc?.forms ?? [],
            meta: currentDoc?.meta ?? [:],
            headers: response.headers,
            error: response.isSuccess ? nil : "HTTP \(response.statusCode)"
        )
    }

    // MARK: - JavaScript Execution

    public func evalJS(_ script: String) -> String {
        // Inject current page content into JS context
        jsContext.setObject(currentHTML, forKeyedSubscript: "document_html" as NSString)
        jsContext.setObject(currentURL, forKeyedSubscript: "document_url" as NSString)
        jsContext.setObject(currentDoc?.title ?? "", forKeyedSubscript: "document_title" as NSString)

        guard let result = jsContext.evaluateScript(script) else { return "" }
        return result.toString() ?? ""
    }

    // MARK: - Crawling

    public func crawl(startURL: String, maxPages: Int = 10, sameDomain: Bool = true) -> [BrowseResult] {
        var visited = Set<String>()
        var queue = [startURL]
        var results: [BrowseResult] = []

        while let url = queue.first, results.count < maxPages {
            queue.removeFirst()
            let normalized = normalizeURL(url)
            guard !visited.contains(normalized) else { continue }
            visited.insert(normalized)

            let result = navigate(normalized)
            results.append(result)

            // Add discovered links to queue
            for link in result.links {
                let absLink = resolveURL(link, base: normalized)
                if sameDomain {
                    guard let startHost = URL(string: startURL)?.host,
                          let linkHost = URL(string: absLink)?.host,
                          linkHost == startHost else { continue }
                }
                if !visited.contains(normalizeURL(absLink)) {
                    queue.append(absLink)
                }
            }
        }

        return results
    }

    // MARK: - API Testing

    public func apiGet(_ url: String) -> APIResult {
        let (json, response) = client.getJSON(url)
        return APIResult(url: response.url, status: response.statusCode,
                        latencyMs: response.latencyMs, json: json,
                        body: response.body, headers: response.headers)
    }

    public func apiPost(_ url: String, json: [String: Any]) -> APIResult {
        let (responseJSON, response) = client.postJSON(url, json: json)
        return APIResult(url: response.url, status: response.statusCode,
                        latencyMs: response.latencyMs, json: responseJSON,
                        body: response.body, headers: response.headers)
    }

    // MARK: - State

    public var url: String { currentURL }
    public var title: String { currentDoc?.title ?? "" }
    public var history: [(url: String, title: String, timestamp: Date)] { pageHistory }

    // MARK: - Helpers

    private func setupJSContext() {
        // Add console.log
        let consoleLog: @convention(block) (String) -> Void = { message in
            // Silent in shell context
        }
        jsContext.setObject(consoleLog, forKeyedSubscript: "console_log" as NSString)
        jsContext.evaluateScript("var console = { log: console_log, error: console_log, warn: console_log };")
    }

    private func normalizeURL(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.hasSuffix("/") { u = String(u.dropLast()) }
        if let fragment = u.firstIndex(of: "#") { u = String(u[..<fragment]) }
        return u
    }

    private func resolveURL(_ url: String, base: String) -> String {
        if url.hasPrefix("http") { return url }
        if url.hasPrefix("//") { return "https:" + url }
        if url.hasPrefix("/") {
            if let baseURL = URL(string: base) {
                return "\(baseURL.scheme ?? "https")://\(baseURL.host ?? "")\(url)"
            }
        }
        return base + "/" + url
    }
}

// MARK: - Result Types

public struct BrowseResult: Sendable {
    public let url: String
    public let title: String
    public let status: Int
    public let latencyMs: Int
    public let text: String
    public let links: [String]
    public let forms: [HTMLForm]
    public let meta: [String: String]
    public let headers: [String: String]
    public let error: String?

    public var isSuccess: Bool { error == nil && (200..<300).contains(status) }
}

public struct APIResult: @unchecked Sendable {
    public let url: String
    public let status: Int
    public let latencyMs: Int
    public let json: Any?
    public let body: String
    public let headers: [String: String]

    public var isSuccess: Bool { (200..<300).contains(status) }
}
