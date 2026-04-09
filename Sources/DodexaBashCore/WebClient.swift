import Foundation

// MARK: - WebClient: HTTP Client with Sessions, Cookies, Redirects
// Full browser-like HTTP client using Foundation URLSession.
// Manages cookies, follows redirects, handles forms, tracks history.

// MARK: - Types

public struct WebResponse: Sendable {
    public let url: String
    public let statusCode: Int
    public let headers: [String: String]
    public let body: String
    public let bodyData: Data
    public let cookies: [String: String]
    public let redirectChain: [String]
    public let latencyMs: Int
    public let contentType: String
    public let contentLength: Int

    public var isSuccess: Bool { (200..<300).contains(statusCode) }
    public var isRedirect: Bool { (300..<400).contains(statusCode) }
    public var isHTML: Bool { contentType.contains("html") }
    public var isJSON: Bool { contentType.contains("json") }
}

public struct WebRequest: Sendable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: String?
    public var formData: [String: String]?
    public var followRedirects: Bool
    public var timeoutSeconds: Double

    public init(url: String, method: String = "GET", headers: [String: String] = [:],
                body: String? = nil, formData: [String: String]? = nil,
                followRedirects: Bool = true, timeoutSeconds: Double = 30) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.formData = formData
        self.followRedirects = followRedirects
        self.timeoutSeconds = timeoutSeconds
    }
}

// MARK: - WebClient

public final class WebClient: @unchecked Sendable {
    private let session: URLSession
    private let cookieStorage: HTTPCookieStorage
    private var defaultHeaders: [String: String]
    private var history: [(url: String, status: Int, timestamp: Date)] = []
    public var userAgent: String

    public init(userAgent: String = "dodexabash/1.0 (macOS; Swift)") {
        self.userAgent = userAgent
        self.cookieStorage = HTTPCookieStorage.shared
        self.defaultHeaders = [
            "User-Agent": self.userAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Accept-Encoding": "gzip, deflate, br",
            "Connection": "keep-alive",
            "DNT": "1"
        ]

        let config = URLSessionConfiguration.default
        config.httpCookieStorage = cookieStorage
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60

        self.session = URLSession(configuration: config)
    }

    @available(*, deprecated, message: "Stealth mode has been removed. Use explicit assessment policy and accountable egress.")
    public convenience init(userAgent: String = "dodexabash/1.0 (macOS; Swift)", stealthMode: Bool) {
        self.init(userAgent: userAgent)
    }

    // MARK: - Core Request

    public func request(_ req: WebRequest) -> WebResponse {
        guard var urlObj = URL(string: req.url) else {
            return errorResponse(url: req.url, error: "Invalid URL")
        }

        // Default to HTTPS only when the caller omitted a scheme.
        if urlObj.scheme == nil, let httpsURL = URL(string: "https://\(req.url)") {
            urlObj = httpsURL
        }

        if urlObj.isFileURL {
            let response = localFileResponse(url: urlObj, method: req.method, originalURL: req.url)
            history.append((response.url, response.statusCode, Date()))
            if history.count > 100 { history.removeFirst() }
            return response
        }

        var urlRequest = URLRequest(url: urlObj)
        urlRequest.httpMethod = req.method
        urlRequest.timeoutInterval = req.timeoutSeconds

        // Merge headers
        for (key, value) in defaultHeaders { urlRequest.setValue(value, forHTTPHeaderField: key) }
        for (key, value) in req.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }

        // Body
        if let formData = req.formData {
            let encoded = formData.map { "\($0.key)=\(percentEncode($0.value))" }.joined(separator: "&")
            urlRequest.httpBody = Data(encoded.utf8)
            urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        } else if let body = req.body {
            urlRequest.httpBody = Data(body.utf8)
        }

        let start = DispatchTime.now()
        let sem = DispatchSemaphore(value: 0)
        var responseData = Data()
        var httpResponse: HTTPURLResponse?
        var redirects: [String] = []

        let task = session.dataTask(with: urlRequest) { data, response, _ in
            responseData = data ?? Data()
            httpResponse = response as? HTTPURLResponse
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + req.timeoutSeconds + 5)

        let latency = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)

        guard let http = httpResponse else {
            return errorResponse(url: req.url, error: "No response (timeout or network error)")
        }

        // Parse headers
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers["\(key)"] = "\(value)"
        }

        // Parse cookies
        var cookies: [String: String] = [:]
        if let url = http.url, let storedCookies = cookieStorage.cookies(for: url) {
            for cookie in storedCookies {
                cookies[cookie.name] = cookie.value
            }
        }

        // Decode body
        let bodyString: String
        if let encoding = http.textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(encoding as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                bodyString = String(data: responseData, encoding: String.Encoding(rawValue: nsEncoding)) ?? String(decoding: responseData, as: UTF8.self)
            } else {
                bodyString = String(decoding: responseData, as: UTF8.self)
            }
        } else {
            bodyString = String(decoding: responseData, as: UTF8.self)
        }

        let contentType = headers["Content-Type"] ?? http.mimeType ?? ""

        let response = WebResponse(
            url: http.url?.absoluteString ?? req.url,
            statusCode: http.statusCode,
            headers: headers,
            body: bodyString,
            bodyData: responseData,
            cookies: cookies,
            redirectChain: redirects,
            latencyMs: latency,
            contentType: contentType,
            contentLength: responseData.count
        )

        // Track history
        history.append((response.url, response.statusCode, Date()))
        if history.count > 100 { history.removeFirst() }

        return response
    }

    // MARK: - Convenience Methods

    public func get(_ url: String, headers: [String: String] = [:]) -> WebResponse {
        request(WebRequest(url: url, method: "GET", headers: headers))
    }

    public func post(_ url: String, body: String? = nil, formData: [String: String]? = nil, headers: [String: String] = [:]) -> WebResponse {
        request(WebRequest(url: url, method: "POST", headers: headers, body: body, formData: formData))
    }

    public func head(_ url: String) -> WebResponse {
        request(WebRequest(url: url, method: "HEAD"))
    }

    // MARK: - JSON

    public func getJSON(_ url: String) -> (data: Any?, response: WebResponse) {
        var req = WebRequest(url: url)
        req.headers["Accept"] = "application/json"
        let response = request(req)
        let json = try? JSONSerialization.jsonObject(with: response.bodyData)
        return (json, response)
    }

    public func postJSON(_ url: String, json: [String: Any]) -> (data: Any?, response: WebResponse) {
        var req = WebRequest(url: url, method: "POST")
        req.headers["Content-Type"] = "application/json"
        req.headers["Accept"] = "application/json"
        req.body = (try? JSONSerialization.data(withJSONObject: json)).flatMap { String(data: $0, encoding: .utf8) }
        let response = request(req)
        let responseJSON = try? JSONSerialization.jsonObject(with: response.bodyData)
        return (responseJSON, response)
    }

    // MARK: - Download

    public func download(_ url: String, to path: String) -> WebResponse {
        let response = request(WebRequest(url: url))
        if response.isSuccess {
            try? response.bodyData.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        return response
    }

    // MARK: - Cookie Management

    public func getCookies(for url: String) -> [String: String] {
        guard let urlObj = URL(string: url),
              let cookies = cookieStorage.cookies(for: urlObj) else { return [:] }
        return Dictionary(uniqueKeysWithValues: cookies.map { ($0.name, $0.value) })
    }

    public func setCookie(name: String, value: String, domain: String, path: String = "/") {
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path
        ]
        if let cookie = HTTPCookie(properties: properties) {
            cookieStorage.setCookie(cookie)
        }
    }

    public func clearCookies() {
        if let cookies = cookieStorage.cookies {
            for cookie in cookies { cookieStorage.deleteCookie(cookie) }
        }
    }

    // MARK: - History

    public var browsingHistory: [(url: String, status: Int, timestamp: Date)] { history }

    // MARK: - Helpers

    private func percentEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }

    private func localFileResponse(url: URL, method: String, originalURL: String) -> WebResponse {
        let start = DispatchTime.now()
        do {
            let fileData = try Data(contentsOf: url)
            let bodyData = method.uppercased() == "HEAD" ? Data() : fileData
            let latency = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            let path = url.path.lowercased()
            let contentType: String
            if path.hasSuffix(".html") || path.hasSuffix(".htm") {
                contentType = "text/html; charset=utf-8"
            } else if path.hasSuffix(".json") {
                contentType = "application/json"
            } else if path.hasSuffix(".txt") || path.hasSuffix(".md") {
                contentType = "text/plain; charset=utf-8"
            } else {
                contentType = "application/octet-stream"
            }

            return WebResponse(
                url: url.absoluteString,
                statusCode: 200,
                headers: [
                    "Content-Type": contentType,
                    "Content-Length": String(fileData.count)
                ],
                body: String(decoding: bodyData, as: UTF8.self),
                bodyData: bodyData,
                cookies: [:],
                redirectChain: [],
                latencyMs: latency,
                contentType: contentType,
                contentLength: fileData.count
            )
        } catch {
            return errorResponse(url: originalURL, error: "File read failed: \(error.localizedDescription)")
        }
    }

    private func errorResponse(url: String, error: String) -> WebResponse {
        WebResponse(url: url, statusCode: 0, headers: [:], body: error,
                   bodyData: Data(), cookies: [:], redirectChain: [],
                   latencyMs: 0, contentType: "", contentLength: 0)
    }
}
