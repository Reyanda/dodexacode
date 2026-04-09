import Foundation

// MARK: - HTML Parser: Native HTML Tag Parser + CSS Selector Engine
// Pure Swift, zero dependencies. Parses HTML into a DOM-like tree
// and supports CSS selector queries for extraction.

// MARK: - DOM Types

public struct HTMLElement: Sendable {
    public let tag: String
    public let attributes: [String: String]
    public let text: String                // direct text content
    public let innerHTML: String           // raw inner HTML
    public var children: [HTMLElement]
    public let depth: Int

    public var id: String? { attributes["id"] }
    public var className: String? { attributes["class"] }
    public var classes: [String] { (attributes["class"] ?? "").split(separator: " ").map(String.init) }
    public var href: String? { attributes["href"] }
    public var src: String? { attributes["src"] }
    public var value: String? { attributes["value"] }
    public var name: String? { attributes["name"] }
    public var type: String? { attributes["type"] }
    public var title: String? { attributes["title"] }

    public var textContent: String {
        var result = text
        for child in children {
            result += child.textContent
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var outerHTML: String {
        var html = "<\(tag)"
        for (key, value) in attributes.sorted(by: { $0.key < $1.key }) {
            html += " \(key)=\"\(value)\""
        }
        if innerHTML.isEmpty && Self.voidTags.contains(tag) {
            return html + " />"
        }
        html += ">\(innerHTML)</\(tag)>"
        return html
    }

    private static let voidTags: Set<String> = ["br", "hr", "img", "input", "meta", "link", "area", "base", "col", "embed", "source", "track", "wbr"]
}

public struct HTMLDocument: Sendable {
    public let elements: [HTMLElement]
    public let title: String
    public let rawHTML: String
    public let links: [String]
    public let forms: [HTMLForm]
    public let meta: [String: String]

    public var text: String {
        elements.map(\.textContent).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct HTMLForm: Sendable {
    public let action: String
    public let method: String
    public let inputs: [(name: String, type: String, value: String)]
}

// MARK: - HTML Parser

public final class HTMLParser: @unchecked Sendable {

    public init() {}

    public func parse(_ html: String) -> HTMLDocument {
        let elements = parseElements(html, depth: 0)
        let title = extractTitle(html)
        let links = extractLinks(html)
        let forms = extractForms(html)
        let meta = extractMeta(html)

        return HTMLDocument(
            elements: elements,
            title: title,
            rawHTML: html,
            links: links,
            forms: forms,
            meta: meta
        )
    }

    // MARK: - CSS Selector Query

    public func query(_ html: String, selector: String) -> [HTMLElement] {
        let doc = parse(html)
        return querySelectorAll(elements: doc.elements, selector: selector)
    }

    public func querySelectorAll(elements: [HTMLElement], selector: String) -> [HTMLElement] {
        let parts = parseSelector(selector)
        var results: [HTMLElement] = []
        matchElements(elements, parts: parts, into: &results)
        return results
    }

    private func matchElements(_ elements: [HTMLElement], parts: SelectorParts, into results: inout [HTMLElement]) {
        for element in elements {
            if matchesSelector(element, parts: parts) {
                results.append(element)
            }
            matchElements(element.children, parts: parts, into: &results)
        }
    }

    private struct SelectorParts {
        let tag: String?
        let id: String?
        let classes: [String]
        let attributes: [(key: String, value: String?)]
    }

    private func parseSelector(_ selector: String) -> SelectorParts {
        var tag: String?
        var id: String?
        var classes: [String] = []
        var attrs: [(String, String?)] = []

        var current = selector.trimmingCharacters(in: .whitespaces)

        // Extract [attr=value] patterns
        while let bracketStart = current.firstIndex(of: "[") {
            if let bracketEnd = current[bracketStart...].firstIndex(of: "]") {
                let attrStr = String(current[current.index(after: bracketStart)..<bracketEnd])
                if let eqIdx = attrStr.firstIndex(of: "=") {
                    let key = String(attrStr[..<eqIdx])
                    let val = String(attrStr[attrStr.index(after: eqIdx)...]).trimmingCharacters(in: .init(charactersIn: "\"'"))
                    attrs.append((key, val))
                } else {
                    attrs.append((attrStr, nil))
                }
                current = String(current[..<bracketStart]) + String(current[current.index(after: bracketEnd)...])
            } else { break }
        }

        // Extract #id
        if let hashIdx = current.firstIndex(of: "#") {
            let afterHash = current[current.index(after: hashIdx)...]
            let idEnd = afterHash.firstIndex(where: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" }) ?? afterHash.endIndex
            id = String(afterHash[..<idEnd])
            current = String(current[..<hashIdx]) + String(afterHash[idEnd...])
        }

        // Extract .class
        while let dotIdx = current.firstIndex(of: ".") {
            let afterDot = current[current.index(after: dotIdx)...]
            let classEnd = afterDot.firstIndex(where: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" }) ?? afterDot.endIndex
            classes.append(String(afterDot[..<classEnd]))
            current = String(current[..<dotIdx]) + String(afterDot[classEnd...])
        }

        // Remaining is tag name
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { tag = trimmed.lowercased() }

        return SelectorParts(tag: tag, id: id, classes: classes, attributes: attrs)
    }

    private func matchesSelector(_ element: HTMLElement, parts: SelectorParts) -> Bool {
        if let tag = parts.tag, element.tag.lowercased() != tag { return false }
        if let id = parts.id, element.id != id { return false }
        for cls in parts.classes {
            if !element.classes.contains(cls) { return false }
        }
        for (key, value) in parts.attributes {
            guard let attrVal = element.attributes[key] else { return false }
            if let value, attrVal != value { return false }
        }
        return true
    }

    // MARK: - Element Parsing

    private func parseElements(_ html: String, depth: Int) -> [HTMLElement] {
        var elements: [HTMLElement] = []
        var pos = html.startIndex

        while pos < html.endIndex {
            // Find next tag
            guard let tagStart = html[pos...].firstIndex(of: "<") else { break }

            // Skip comments and doctypes
            let afterOpen = html.index(after: tagStart)
            if afterOpen < html.endIndex {
                if html[afterOpen] == "!" || html[afterOpen] == "?" {
                    if let closeIdx = html[tagStart...].range(of: ">") {
                        pos = closeIdx.upperBound
                        continue
                    }
                    break
                }
                // Skip closing tags at this level
                if html[afterOpen] == "/" {
                    if let closeIdx = html[tagStart...].firstIndex(of: ">") {
                        pos = html.index(after: closeIdx)
                        continue
                    }
                    break
                }
            }

            // Parse opening tag
            guard let tagEnd = html[tagStart...].firstIndex(of: ">") else { break }
            let tagContent = String(html[html.index(after: tagStart)..<tagEnd])
                .trimmingCharacters(in: .whitespaces)

            // Self-closing?
            let selfClosing = tagContent.hasSuffix("/")
            let cleanTag = selfClosing ? String(tagContent.dropLast()).trimmingCharacters(in: .whitespaces) : tagContent

            // Parse tag name and attributes
            let parts = cleanTag.split(separator: " ", maxSplits: 1)
            let tagName = String(parts.first ?? "").lowercased()
            let attrString = parts.count > 1 ? String(parts[1]) : ""
            let attributes = parseAttributes(attrString)

            guard !tagName.isEmpty else { pos = html.index(after: tagEnd); continue }

            let voidTags: Set<String> = ["br", "hr", "img", "input", "meta", "link", "area", "base", "col", "embed", "source", "track", "wbr"]

            if selfClosing || voidTags.contains(tagName) {
                elements.append(HTMLElement(
                    tag: tagName, attributes: attributes,
                    text: "", innerHTML: "", children: [], depth: depth
                ))
                pos = html.index(after: tagEnd)
            } else {
                // Find matching closing tag
                let innerStart = html.index(after: tagEnd)
                let closingTag = "</\(tagName)>"
                if let closeRange = html[innerStart...].range(of: closingTag, options: .caseInsensitive) {
                    let innerHTML = String(html[innerStart..<closeRange.lowerBound])
                    let textContent = stripTags(innerHTML)
                    let children = depth < 5 ? parseElements(innerHTML, depth: depth + 1) : []

                    elements.append(HTMLElement(
                        tag: tagName, attributes: attributes,
                        text: textContent, innerHTML: innerHTML,
                        children: children, depth: depth
                    ))
                    pos = closeRange.upperBound
                } else {
                    // No closing tag found — treat as self-closing
                    elements.append(HTMLElement(
                        tag: tagName, attributes: attributes,
                        text: "", innerHTML: "", children: [], depth: depth
                    ))
                    pos = html.index(after: tagEnd)
                }
            }
        }

        return elements
    }

    private func parseAttributes(_ attrString: String) -> [String: String] {
        var attrs: [String: String] = [:]
        let pattern = #"(\w[\w-]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|(\S+)))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return attrs }

        let nsStr = attrString as NSString
        let matches = regex.matches(in: attrString, range: NSRange(location: 0, length: nsStr.length))

        for match in matches {
            let key = nsStr.substring(with: match.range(at: 1)).lowercased()
            var value = ""
            for group in [2, 3, 4] {
                let range = match.range(at: group)
                if range.location != NSNotFound {
                    value = nsStr.substring(with: range)
                    break
                }
            }
            attrs[key] = value
        }
        return attrs
    }

    // MARK: - Extraction

    private func extractTitle(_ html: String) -> String {
        guard let start = html.range(of: "<title", options: .caseInsensitive),
              let tagEnd = html[start.upperBound...].firstIndex(of: ">"),
              let closeRange = html[tagEnd...].range(of: "</title>", options: .caseInsensitive) else { return "" }
        return String(html[html.index(after: tagEnd)..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractLinks(_ html: String) -> [String] {
        var links: [String] = []
        let pattern = #"href\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let nsStr = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsStr.length))
        for match in matches {
            if match.range(at: 1).location != NSNotFound {
                links.append(nsStr.substring(with: match.range(at: 1)))
            }
        }
        return links
    }

    private func extractForms(_ html: String) -> [HTMLForm] {
        var forms: [HTMLForm] = []
        let formPattern = #"<form[^>]*>([\s\S]*?)</form>"#
        guard let regex = try? NSRegularExpression(pattern: formPattern, options: .caseInsensitive) else { return [] }
        let nsStr = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsStr.length))

        for match in matches {
            let fullTag = nsStr.substring(with: match.range)
            let attrs = parseAttributes(String(fullTag.prefix(200)))
            let action = attrs["action"] ?? ""
            let method = (attrs["method"] ?? "GET").uppercased()

            // Extract inputs
            var inputs: [(String, String, String)] = []
            let inputPattern = #"<input[^>]*>"#
            if let inputRegex = try? NSRegularExpression(pattern: inputPattern, options: .caseInsensitive) {
                let innerRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range
                let inputMatches = inputRegex.matches(in: html, range: innerRange)
                for inputMatch in inputMatches {
                    let inputTag = nsStr.substring(with: inputMatch.range)
                    let inputAttrs = parseAttributes(inputTag)
                    inputs.append((inputAttrs["name"] ?? "", inputAttrs["type"] ?? "text", inputAttrs["value"] ?? ""))
                }
            }

            forms.append(HTMLForm(action: action, method: method, inputs: inputs))
        }
        return forms
    }

    private func extractMeta(_ html: String) -> [String: String] {
        var meta: [String: String] = [:]
        let pattern = #"<meta[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [:] }
        let nsStr = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsStr.length))
        for match in matches {
            let tag = nsStr.substring(with: match.range)
            let attrs = parseAttributes(tag)
            if let name = attrs["name"] ?? attrs["property"], let content = attrs["content"] {
                meta[name] = content
            }
        }
        return meta
    }

    private func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Prune4Web DOM Distillation (Architecture Blueprint 2026)

    public func distillPrune4Web(_ html: String) -> String {
        // Prune4Web algorithm: removes stylistic markup, scripts, and non-interactive 
        // nested containers while preserving semantic roles, links, forms, and buttons.
        var distilled = html

        // 1. Remove non-semantic heavy elements
        let removals = ["<script[^>]*>[\\s\\S]*?</script>", "<style[^>]*>[\\s\\S]*?</style>", "<svg[^>]*>[\\s\\S]*?</svg>", "<!--[\\s\\S]*?-->"]
        for pattern in removals {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(location: 0, length: distilled.utf16.count)
                distilled = regex.stringByReplacingMatches(in: distilled, options: [], range: range, withTemplate: "")
            }
        }

        // 2. Flatten empty divs/spans
        let flattenPattern = #"<(div|span)[^>]*>\s*</\1>"#
        if let regex = try? NSRegularExpression(pattern: flattenPattern, options: .caseInsensitive) {
            var previous = ""
            while distilled != previous {
                previous = distilled
                let range = NSRange(location: 0, length: distilled.utf16.count)
                distilled = regex.stringByReplacingMatches(in: distilled, options: [], range: range, withTemplate: "")
            }
        }

        return distilled.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
