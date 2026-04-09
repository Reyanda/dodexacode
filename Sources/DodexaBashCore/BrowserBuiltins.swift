import Foundation

// MARK: - Browser Builtins: Shell commands for web browsing

extension Builtins {
    static func browseBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        if let error = rejectDeprecatedStealthFlag(args: args, command: "browse") {
            return error
        }

        let sub = args.first { !$0.hasPrefix("-") } ?? "help"
        var subArgs = Array(args.dropFirst())
        if let idx = subArgs.firstIndex(of: sub) { subArgs.remove(at: idx) }
        let browser = WebBrowser()

        switch sub {
        case "go", "nav", "open":
            return browseGo(args: subArgs, browser: browser)
        case "get", "fetch":
            return browseFetch(args: subArgs, browser: browser)
        case "select", "query", "css":
            return browseSelect(args: subArgs, browser: browser)
        case "text":
            return browseText(args: subArgs, browser: browser)
        case "links":
            return browseLinks(args: subArgs, browser: browser)
        case "headers":
            return browseHeaders(args: subArgs, browser: browser)
        case "forms":
            return browseForms(args: subArgs, browser: browser)
        case "submit":
            return browseSubmit(args: subArgs, browser: browser)
        case "api":
            return browseAPI(args: subArgs, browser: browser)
        case "crawl":
            return browseCrawl(args: subArgs, browser: browser)
        case "table":
            return browseTable(args: subArgs, browser: browser)
        case "js", "eval":
            return browseJS(args: subArgs, browser: browser)
        case "head":
            return browseHead(args: subArgs, browser: browser)
        case "download":
            return browseDownload(args: subArgs, browser: browser)
        case "sec", "security":
            return browseSec(args: subArgs, browser: browser, runtime: runtime)
        default:
            return browseHelp()
        }
    }

    // MARK: - Browser-based Security Audit

    private static func browseSec(args: [String], browser: WebBrowser, runtime: BuiltinRuntime) -> CommandResult {
        guard let urlStr = args.first else { return textResult("Usage: browse sec <url>\n") }
        let url = urlStr.contains("://") ? urlStr : "https://\(urlStr)"
        let domain = URL(string: url)?.host ?? urlStr

        if let error = requireSecurityAssessmentMode(
            runtime: runtime,
            minimum: .passive,
            command: "browse sec",
            rationale: "Browser-backed security review should remain explicitly in-scope."
        ) {
            return error
        }

        // Lease check
        if !checkSecLease(capability: "sec:scan", resource: domain, runtime: runtime) {
            return leaseRequiredError("sec:scan", domain)
        }

        let result = browser.navigate(url)
        if let error = result.error {
            return CommandResult(status: 1, io: ShellIO(stderr: Data("Error: \(error)\n".utf8)))
        }

        var lines: [String] = ["Browser Security Audit: \(url)"]
        lines.append(String(repeating: "=", count: 40))
        lines.append(securityAssessmentBanner(runtime: runtime))
        lines.append("")

        // 1. JS-aware CSP Check
        let hasCSP = result.headers.keys.contains { $0.lowercased() == "content-security-policy" }
        let cspIcon = hasCSP ? "\u{2713}" : "\u{2717}"
        lines.append("\(cspIcon) CSP: \(hasCSP ? "Present" : "Missing")")

        // 2. JS Execution Test (simulated)
        let jsTest = browser.evalJS("window.isVulnerable = true; window.isVulnerable")
        if jsTest == "true" {
            lines.append("\u{2713} JS Execution: Functional")
        }

        // 3. Form Security
        let insecureForms = result.forms.filter { !$0.action.hasPrefix("https") && !$0.action.isEmpty }
        if !insecureForms.isEmpty {
            lines.append("\u{2717} Insecure Forms: \(insecureForms.count) forms submit to HTTP")
        } else {
            lines.append("\u{2713} Form Submission: Secure (HTTPS)")
        }

        // 4. Sensitive info in DOM
        let domText = result.text.lowercased()
        let sensitiveKeywords = ["password", "secret", "token", "apikey", "key"]
        var foundSensitive: [String] = []
        for kw in sensitiveKeywords {
            if domText.contains(kw) { foundSensitive.append(kw) }
        }
        if !foundSensitive.isEmpty {
            lines.append("\u{26A0} Info Leak: Found sensitive keywords in DOM: \(foundSensitive.joined(separator: ", "))")
        }

        // 5. External Scripts
        let scripts = browser.select("script[src]")
        let externalScripts = scripts.filter {
            let src = $0.attributes["src"] ?? ""
            return !src.contains(domain) && src.hasPrefix("http")
        }
        if !externalScripts.isEmpty {
            lines.append("\u{26A0} External Scripts: \(externalScripts.count) scripts from third-party domains")
        }

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    private static func checkSecLease(capability: String, resource: String, runtime: BuiltinRuntime) -> Bool {
        let leases = runtime.runtimeStore.activeLeases()
        return leases.contains { lease in
            let capMatch = lease.capability == capability || lease.capability.hasPrefix("sec")
            let resMatch = lease.resource == resource || resource.contains(lease.resource)
            return capMatch && resMatch
        }
    }

    private static func leaseRequiredError(_ capability: String, _ resource: String) -> CommandResult {
        let msg = "Lease required: lease grant \(capability) \(resource) 600\n"
        return CommandResult(status: 1, io: ShellIO(stderr: Data(msg.utf8)))
    }

    // MARK: - Navigate

    private static func browseGo(args: [String], browser: WebBrowser) -> CommandResult {
        guard let url = args.first else { return textResult("Usage: browse go <url>\n") }
        let result = browser.navigate(url)
        if let error = result.error {
            return CommandResult(status: 1, io: ShellIO(stderr: Data("Error: \(error)\n".utf8)))
        }
        var lines: [String] = []
        lines.append("\u{001B}[1m\(result.title)\u{001B}[0m")
        lines.append("\u{001B}[2m\(result.url) [\(result.status)] \(result.latencyMs)ms\u{001B}[0m")
        lines.append("")
        let text = result.text
        let preview = text.count > 500 ? String(text.prefix(500)) + "\n..." : text
        lines.append(preview)
        lines.append("")
        lines.append("\u{001B}[2m\(result.links.count) links, \(result.forms.count) forms\u{001B}[0m")
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Fetch (raw)

    private static func browseFetch(args: [String], browser: WebBrowser) -> CommandResult {
        guard let url = args.first else { return textResult("Usage: browse fetch <url>\n") }
        let response = browser.client.get(url.contains("://") ? url : "https://\(url)")
        if args.contains("--json") && response.isJSON {
            return textResult(response.body + "\n")
        }
        return textResult(response.body)
    }

    // MARK: - CSS Select

    private static func browseSelect(args: [String], browser: WebBrowser) -> CommandResult {
        guard args.count >= 2 else { return textResult("Usage: browse select <url> <css-selector>\n") }
        let url = args[0]
        let selector = args.dropFirst().joined(separator: " ")
        _ = browser.navigate(url)
        let elements = browser.select(selector)
        if elements.isEmpty { return textResult("No elements matching '\(selector)'.\n") }
        var lines: [String] = ["Found \(elements.count) elements:"]
        for (i, el) in elements.prefix(20).enumerated() {
            let text = String(el.textContent.prefix(100))
            lines.append("  [\(i)] <\(el.tag)\(el.id.map { " id=\"\($0)\"" } ?? "")\(el.className.map { " class=\"\($0)\"" } ?? "")> \(text)")
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Extract Text

    private static func browseText(args: [String], browser: WebBrowser) -> CommandResult {
        guard let url = args.first else { return textResult("Usage: browse text <url>\n") }
        let result = browser.navigate(url)
        if let error = result.error { return CommandResult(status: 1, io: ShellIO(stderr: Data("Error: \(error)\n".utf8))) }
        return textResult(result.text + "\n")
    }

    // MARK: - Links

    private static func browseLinks(args: [String], browser: WebBrowser) -> CommandResult {
        guard let url = args.first else { return textResult("Usage: browse links <url>\n") }
        let result = browser.navigate(url)
        let links = result.links.filter { $0.hasPrefix("http") }
        if links.isEmpty { return textResult("No external links found.\n") }
        let unique = Array(Set(links)).sorted().prefix(50)
        return textResult(unique.joined(separator: "\n") + "\n")
    }

    // MARK: - Headers

    private static func browseHeaders(args: [String], browser: WebBrowser) -> CommandResult {
        guard let url = args.first else { return textResult("Usage: browse headers <url>\n") }
        let response = browser.client.head(url.contains("://") ? url : "https://\(url)")
        var lines: [String] = ["HTTP \(response.statusCode) — \(response.latencyMs)ms"]
        for (key, value) in response.headers.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(key): \(value)")
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Forms

    private static func browseForms(args: [String], browser: WebBrowser) -> CommandResult {
        guard let url = args.first else { return textResult("Usage: browse forms <url>\n") }
        let result = browser.navigate(url)
        if result.forms.isEmpty { return textResult("No forms found.\n") }
        var lines: [String] = ["Forms (\(result.forms.count)):"]
        for (i, form) in result.forms.enumerated() {
            lines.append("  [\(i)] \(form.method) \(form.action.isEmpty ? "(self)" : form.action)")
            for input in form.inputs {
                lines.append("    \(input.name.isEmpty ? "(unnamed)" : input.name) [\(input.type)]\(input.value.isEmpty ? "" : " = \"\(input.value)\"")")
            }
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Submit Form

    private static func browseSubmit(args: [String], browser: WebBrowser) -> CommandResult {
        guard args.count >= 1 else { return textResult("Usage: browse submit <url> [key=value ...]\n") }
        let url = args[0]
        _ = browser.navigate(url)
        var data: [String: String] = [:]
        for arg in args.dropFirst() {
            let parts = arg.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { data[String(parts[0])] = String(parts[1]) }
        }
        let result = browser.submitForm(data: data)
        if let error = result.error { return CommandResult(status: 1, io: ShellIO(stderr: Data("Error: \(error)\n".utf8))) }
        return textResult("\u{001B}[1m\(result.title)\u{001B}[0m\n\(result.url) [\(result.status)]\n\(String(result.text.prefix(500)))\n")
    }

    // MARK: - API

    private static func browseAPI(args: [String], browser: WebBrowser) -> CommandResult {
        guard let url = args.first else { return textResult("Usage: browse api <url> [--post key=val ...]\n") }
        let isPost = args.contains("--post")

        if isPost {
            var json: [String: Any] = [:]
            for arg in args.dropFirst() where arg.contains("=") && arg != "--post" {
                let parts = arg.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { json[String(parts[0])] = String(parts[1]) }
            }
            let result = browser.apiPost(url.contains("://") ? url : "https://\(url)", json: json)
            return formatAPIResult(result)
        }

        let result = browser.apiGet(url.contains("://") ? url : "https://\(url)")
        return formatAPIResult(result)
    }

    // MARK: - Crawl

    private static func browseCrawl(args: [String], browser: WebBrowser) -> CommandResult {
        guard let url = args.first else { return textResult("Usage: browse crawl <url> [-n 5]\n") }
        let maxPages = Int(flagValue(args, flag: "-n") ?? "5") ?? 5

        let results = browser.crawl(startURL: url.contains("://") ? url : "https://\(url)", maxPages: maxPages)
        var lines: [String] = ["Crawled \(results.count) pages:"]
        for (i, r) in results.enumerated() {
            let title = r.title.isEmpty ? r.url : r.title
            lines.append("  [\(i + 1)] \(title)")
            lines.append("      \(r.url) [\(r.status)] \(r.latencyMs)ms \(r.links.count) links")
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Table Extraction

    private static func browseTable(args: [String], browser: WebBrowser) -> CommandResult {
        guard let url = args.first else { return textResult("Usage: browse table <url>\n") }
        _ = browser.navigate(url)
        let tableData = browser.extractTableData()
        if tableData.isEmpty { return textResult("No tables found.\n") }
        var lines: [String] = ["Table (\(tableData.count) rows):"]
        for row in tableData.prefix(30) {
            lines.append("  " + row.joined(separator: " | "))
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - JS Eval

    private static func browseJS(args: [String], browser: WebBrowser) -> CommandResult {
        guard args.count >= 2 else { return textResult("Usage: browse js <url> <script>\n") }
        let url = args[0]
        let script = args.dropFirst().joined(separator: " ")
        _ = browser.navigate(url)
        let result = browser.evalJS(script)
        return textResult(result + "\n")
    }

    // MARK: - HEAD request

    private static func browseHead(args: [String], browser: WebBrowser) -> CommandResult {
        browseHeaders(args: args, browser: browser)
    }

    // MARK: - Download

    private static func browseDownload(args: [String], browser: WebBrowser) -> CommandResult {
        guard args.count >= 2 else { return textResult("Usage: browse download <url> <output-path>\n") }
        let url = args[0]
        let path = args[1]
        let response = browser.client.download(url.contains("://") ? url : "https://\(url)", to: path)
        if response.isSuccess {
            return textResult("Downloaded \(response.contentLength) bytes → \(path)\n")
        }
        return CommandResult(status: 1, io: ShellIO(stderr: Data("Download failed: HTTP \(response.statusCode)\n".utf8)))
    }

    // MARK: - Help

    private static func browseHelp() -> CommandResult {
        textResult("""
        Web Browser — Native HTTP client + HTML parser + JS engine

        Navigation:
          browse go <url>                    Navigate and show page summary
          browse text <url>                  Extract clean text from page
          browse links <url>                 List all links on page
          browse headers <url>              Show HTTP response headers

        Extraction:
          browse select <url> <selector>    CSS selector query
          browse table <url>                Extract table data
          browse forms <url>                List forms and inputs

        Interaction:
          browse submit <url> [key=val..]   Submit form with data
          browse js <url> <script>          Execute JavaScript on page
          browse api <url> [--post k=v..]   JSON API request

        Utilities:
          browse fetch <url>                Raw HTTP response body
          browse crawl <url> [-n 5]         Crawl site (same-domain)
          browse download <url> <path>      Download file
          browse head <url>                 HEAD request only

        """)
    }

    // MARK: - Helpers

    private static func formatAPIResult(_ result: APIResult) -> CommandResult {
        var lines: [String] = ["\u{001B}[2m\(result.url) [\(result.status)] \(result.latencyMs)ms\u{001B}[0m"]
        if let json = result.json {
            if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
               let text = String(data: data, encoding: .utf8) {
                lines.append(text)
            }
        } else {
            lines.append(String(result.body.prefix(1000)))
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    private static func flagValue(_ args: [String], flag: String) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }
}
