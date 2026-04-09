import Foundation

// MARK: - ResearchEngine: Multi-Domain Search Orchestrator
// Searches across 6+ sources during Roche Phase 1: palace memory,
// codebase index, web (DuckDuckGo, Scholar, Wikipedia, arXiv, GitHub,
// StackOverflow), and MCP tools (bioRxiv, ChEMBL, clinical trials).
// Synthesizes results into structured context for brain.

// MARK: - Types

public enum SearchDomain: String, Sendable {
    case biotech        // drugs, proteins, genes, clinical
    case software       // code, build, implement, API
    case academic       // papers, research, study, theory
    case general        // everything else
}

public struct SearchQuery: Sendable {
    public let source: String   // "duckduckgo", "scholar", "wikipedia", "arxiv", "github", "stackoverflow", "mcp"
    public let query: String
    public let url: String?     // pre-built URL for web sources
}

public struct SearchResult: Sendable {
    public let source: String
    public let title: String
    public let content: String
    public let url: String?
    public let score: Double    // relevance 0-1
    public let latencyMs: Int
}

public struct ResearchContext: Sendable {
    public var palaceResults: [SearchResult]
    public var codebaseContext: String
    public var webResults: [SearchResult]
    public var mcpResults: [SearchResult]
    public var domain: SearchDomain
    public var queries: [String]
    public var totalLatencyMs: Int

    public var allResults: [SearchResult] {
        (palaceResults + webResults + mcpResults).sorted { $0.score > $1.score }
    }

    public func formatted(maxChars: Int = 6000) -> String {
        var sections: [String] = []
        var remaining = maxChars

        // Palace (prior knowledge) — highest priority
        if !palaceResults.isEmpty {
            var palaceSection = "## Prior Knowledge (Memory Palace)\n"
            for r in palaceResults.prefix(3) {
                let entry = "- **[\(r.source)]** \(r.title)\n  \(String(r.content.prefix(200)))\n"
                if palaceSection.count + entry.count < remaining / 4 {
                    palaceSection += entry
                }
            }
            sections.append(palaceSection)
            remaining -= palaceSection.count
        }

        // Codebase — if software domain
        if !codebaseContext.isEmpty && remaining > 500 {
            let capped = String(codebaseContext.prefix(min(1500, remaining / 3)))
            sections.append("## Codebase Analysis\n\(capped)")
            remaining -= capped.count + 25
        }

        // Web results
        if !webResults.isEmpty && remaining > 300 {
            var webSection = "## Web Research\n"
            for r in webResults.prefix(5) {
                let entry = "### \(r.title)\n*Source: \(r.source)\(r.url.map { " — \($0)" } ?? "")*\n\(String(r.content.prefix(300)))\n\n"
                if webSection.count + entry.count < remaining / 2 {
                    webSection += entry
                }
            }
            sections.append(webSection)
            remaining -= webSection.count
        }

        // MCP results
        if !mcpResults.isEmpty && remaining > 200 {
            var mcpSection = "## Specialized Database Results\n"
            for r in mcpResults.prefix(3) {
                let entry = "- **[\(r.source)]** \(r.title): \(String(r.content.prefix(200)))\n"
                if mcpSection.count + entry.count < remaining {
                    mcpSection += entry
                }
            }
            sections.append(mcpSection)
        }

        return sections.joined(separator: "\n\n")
    }
}

// MARK: - Research Engine

public final class ResearchEngine: @unchecked Sendable {
    private let browser: WebBrowser
    private let timeoutPerSource: Double = 10.0

    public init() {
        self.browser = WebBrowser()
    }

    // MARK: - Main Entry Point

    func research(task: String, runtime: BuiltinRuntime) -> ResearchContext {
        let start = DispatchTime.now()
        let domain = detectDomain(task)
        let queries = generateQueries(task: task, domain: domain)

        // 1. Palace search (instant — local)
        let palaceResults = searchPalace(task: task, runtime: runtime)

        // 2. Codebase index (instant — local)
        let codebaseCtx = searchCodebase(task: task, runtime: runtime, domain: domain)

        // 3. Web search (parallel across engines)
        let webResults = searchWeb(queries: queries, domain: domain)

        // 4. MCP tools (if bio domain)
        let mcpResults = searchMCP(task: task, domain: domain, runtime: runtime)

        let totalMs = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)

        return ResearchContext(
            palaceResults: palaceResults,
            codebaseContext: codebaseCtx,
            webResults: webResults,
            mcpResults: mcpResults,
            domain: domain,
            queries: queries.map(\.query),
            totalLatencyMs: totalMs
        )
    }

    // MARK: - Domain Detection

    public func detectDomain(_ task: String) -> SearchDomain {
        let lower = task.lowercased()

        let bioKeywords = ["protein", "gene", "drug", "clinical", "trial", "molecule", "enzyme",
                          "receptor", "antibody", "pharma", "biotech", "crispr", "genome",
                          "mutation", "disease", "therapy", "dose", "patient", "fda",
                          "compound", "assay", "cell", "tissue", "dna", "rna", "mrna"]

        let softwareKeywords = ["code", "build", "implement", "refactor", "debug", "api",
                               "function", "class", "module", "deploy", "test", "swift",
                               "python", "javascript", "rust", "database", "server",
                               "framework", "library", "package", "git", "docker"]

        let academicKeywords = ["research", "paper", "study", "theory", "hypothesis",
                               "methodology", "analysis", "review", "literature",
                               "journal", "publication", "citation", "peer"]

        let bioScore = bioKeywords.filter { lower.contains($0) }.count
        let softScore = softwareKeywords.filter { lower.contains($0) }.count
        let acadScore = academicKeywords.filter { lower.contains($0) }.count

        if bioScore >= 2 || (bioScore >= 1 && acadScore >= 1) { return .biotech }
        if softScore >= 2 { return .software }
        if acadScore >= 2 { return .academic }
        return .general
    }

    // MARK: - Query Generation

    public func generateQueries(task: String, domain: SearchDomain) -> [SearchQuery] {
        let encoded = task.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? task
        var queries: [SearchQuery] = []

        // Always: DuckDuckGo (no API key, reliable)
        queries.append(SearchQuery(
            source: "duckduckgo",
            query: task,
            url: "https://html.duckduckgo.com/html/?q=\(encoded)"
        ))

        // Always: Wikipedia
        queries.append(SearchQuery(
            source: "wikipedia",
            query: task,
            url: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=\(encoded)&format=json&srlimit=3"
        ))

        switch domain {
        case .biotech:
            queries.append(SearchQuery(source: "scholar", query: task,
                url: "https://scholar.google.com/scholar?q=\(encoded)&as_ylo=2024"))
            queries.append(SearchQuery(source: "arxiv", query: task,
                url: "http://export.arxiv.org/api/query?search_query=all:\(encoded)&max_results=3&sortBy=submittedDate&sortOrder=descending"))

        case .software:
            queries.append(SearchQuery(source: "github", query: task,
                url: "https://api.github.com/search/repositories?q=\(encoded)&sort=stars&per_page=5"))
            queries.append(SearchQuery(source: "stackoverflow", query: task,
                url: "https://api.stackexchange.com/2.3/search/advanced?order=desc&sort=relevance&q=\(encoded)&site=stackoverflow&pagesize=3"))

        case .academic:
            queries.append(SearchQuery(source: "scholar", query: task,
                url: "https://scholar.google.com/scholar?q=\(encoded)"))
            queries.append(SearchQuery(source: "arxiv", query: task,
                url: "http://export.arxiv.org/api/query?search_query=all:\(encoded)&max_results=5&sortBy=relevance"))

        case .general:
            queries.append(SearchQuery(source: "github", query: task,
                url: "https://api.github.com/search/repositories?q=\(encoded)&sort=stars&per_page=3"))
        }

        return queries
    }

    // MARK: - Source 1: Palace Memory

    private func searchPalace(task: String, runtime: BuiltinRuntime) -> [SearchResult] {
        let palaceDir = palaceDirectory(runtime: runtime)
        let store = PalaceStore(directory: palaceDir)
        guard store.isInitialized else { return [] }

        let engine = PalaceSearchEngine()
        engine.indexAll(store.allDrawers)
        let results = engine.search(query: task, limit: 5)

        return results.map { r in
            SearchResult(source: "palace/\(r.wing)/\(r.room)", title: r.summary,
                        content: r.content, url: nil, score: r.score, latencyMs: 0)
        }
    }

    // MARK: - Source 2: Codebase Index

    private func searchCodebase(task: String, runtime: BuiltinRuntime, domain: SearchDomain) -> String {
        // Always include basic context
        var context = runtime.codebaseIndexer.contextForBrain(limit: 1500)

        // For software tasks, also search for relevant symbols
        if domain == .software {
            let keywords = task.lowercased().split(separator: " ")
                .filter { $0.count > 3 }
                .prefix(3)
                .map(String.init)
            for keyword in keywords {
                let symbols = runtime.codebaseIndexer.searchSymbols(query: keyword, limit: 5)
                if !symbols.isEmpty {
                    context += "\nSymbols matching '\(keyword)':\n"
                    for sym in symbols {
                        context += "  \(sym.kind.rawValue) \(sym.name) at \(sym.file):\(sym.line)\n"
                    }
                }
            }
        }

        return context
    }

    // MARK: - Source 3: Web Search

    private func searchWeb(queries: [SearchQuery], domain: SearchDomain) -> [SearchResult] {
        var results: [SearchResult] = []
        let group = DispatchGroup()
        let lock = NSLock()

        for query in queries {
            guard let url = query.url else { continue }
            group.enter()

            DispatchQueue.global().async { [self] in
                defer { group.leave() }
                let start = DispatchTime.now()

                switch query.source {
                case "duckduckgo":
                    let extracted = self.searchDuckDuckGo(url: url, query: query.query)
                    let ms = self.elapsed(start)
                    lock.lock()
                    results.append(contentsOf: extracted.map { r in
                        SearchResult(source: "DuckDuckGo", title: r.title, content: r.content,
                                    url: r.url, score: 0.6, latencyMs: ms)
                    })
                    lock.unlock()

                case "wikipedia":
                    let extracted = self.searchWikipedia(url: url)
                    let ms = self.elapsed(start)
                    lock.lock()
                    results.append(contentsOf: extracted.map { r in
                        SearchResult(source: "Wikipedia", title: r.title, content: r.content,
                                    url: r.url, score: 0.7, latencyMs: ms)
                    })
                    lock.unlock()

                case "scholar":
                    let extracted = self.searchScholar(url: url)
                    let ms = self.elapsed(start)
                    lock.lock()
                    results.append(contentsOf: extracted.map { r in
                        SearchResult(source: "Google Scholar", title: r.title, content: r.content,
                                    url: r.url, score: 0.8, latencyMs: ms)
                    })
                    lock.unlock()

                case "arxiv":
                    let extracted = self.searchArXiv(url: url)
                    let ms = self.elapsed(start)
                    lock.lock()
                    results.append(contentsOf: extracted.map { r in
                        SearchResult(source: "arXiv", title: r.title, content: r.content,
                                    url: r.url, score: 0.75, latencyMs: ms)
                    })
                    lock.unlock()

                case "github":
                    let extracted = self.searchGitHub(url: url)
                    let ms = self.elapsed(start)
                    lock.lock()
                    results.append(contentsOf: extracted.map { r in
                        SearchResult(source: "GitHub", title: r.title, content: r.content,
                                    url: r.url, score: 0.65, latencyMs: ms)
                    })
                    lock.unlock()

                case "stackoverflow":
                    let extracted = self.searchStackOverflow(url: url)
                    let ms = self.elapsed(start)
                    lock.lock()
                    results.append(contentsOf: extracted.map { r in
                        SearchResult(source: "StackOverflow", title: r.title, content: r.content,
                                    url: r.url, score: 0.6, latencyMs: ms)
                    })
                    lock.unlock()

                default:
                    break
                }
            }
        }

        _ = group.wait(timeout: .now() + 20)
        return results.sorted { $0.score > $1.score }
    }

    // MARK: - Web Source Parsers

    private struct WebResult { let title: String; let content: String; let url: String? }

    private func searchDuckDuckGo(url: String, query: String) -> [WebResult] {
        let response = browser.client.get(url)
        guard response.isSuccess else { return [] }

        let parser = HTMLParser()
        let elements = parser.query(response.body, selector: ".result")
        if elements.isEmpty {
            // Fallback: extract text directly
            let doc = parser.parse(response.body)
            let text = String(doc.text.prefix(600))
            return text.isEmpty ? [] : [WebResult(title: "DuckDuckGo: \(query)", content: text, url: nil)]
        }

        return elements.prefix(5).map { el in
            let title = el.children.first { $0.tag == "a" }?.textContent ?? el.textContent.prefix(80).description
            let snippet = el.textContent
            let href = el.children.first { $0.tag == "a" }?.href
            return WebResult(title: title, content: String(snippet.prefix(300)), url: href)
        }
    }

    private func searchWikipedia(url: String) -> [WebResult] {
        let (json, response) = browser.client.getJSON(url)
        guard response.isSuccess, let data = json as? [String: Any],
              let query = data["query"] as? [String: Any],
              let results = query["search"] as? [[String: Any]] else { return [] }

        return results.prefix(3).compactMap { item -> WebResult? in
            guard let title = item["title"] as? String,
                  let snippet = item["snippet"] as? String else { return nil }
            let cleaned = snippet.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            return WebResult(title: title, content: cleaned,
                           url: "https://en.wikipedia.org/wiki/\(title.replacingOccurrences(of: " ", with: "_"))")
        }
    }

    private func searchScholar(url: String) -> [WebResult] {
        let response = browser.client.get(url)
        guard response.isSuccess else { return [] }

        let parser = HTMLParser()
        let elements = parser.query(response.body, selector: ".gs_ri")
        return elements.prefix(5).map { el in
            let title = el.children.first { $0.tag == "h3" }?.textContent ?? "Scholar result"
            let snippet = el.children.first { $0.className?.contains("gs_rs") == true }?.textContent ?? el.textContent
            return WebResult(title: String(title.prefix(120)), content: String(snippet.prefix(300)), url: nil)
        }
    }

    private func searchArXiv(url: String) -> [WebResult] {
        let response = browser.client.get(url)
        guard response.isSuccess else { return [] }

        // Parse Atom XML (simple regex extraction)
        var results: [WebResult] = []
        let entries = response.body.components(separatedBy: "<entry>").dropFirst()
        for entry in entries.prefix(5) {
            let title = extractXMLTag(entry, tag: "title")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let summary = extractXMLTag(entry, tag: "summary")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let link = extractXMLAttribute(entry, tag: "id") ?? ""
            if !title.isEmpty {
                results.append(WebResult(title: title, content: String(summary.prefix(300)), url: link))
            }
        }
        return results
    }

    private func searchGitHub(url: String) -> [WebResult] {
        let (json, response) = browser.client.getJSON(url)
        guard response.isSuccess, let data = json as? [String: Any],
              let items = data["items"] as? [[String: Any]] else { return [] }

        return items.prefix(5).compactMap { item -> WebResult? in
            guard let name = item["full_name"] as? String else { return nil }
            let desc = item["description"] as? String ?? ""
            let stars = item["stargazers_count"] as? Int ?? 0
            let url = item["html_url"] as? String
            return WebResult(title: "\(name) (\u{2605}\(stars))", content: desc, url: url)
        }
    }

    private func searchStackOverflow(url: String) -> [WebResult] {
        let (json, response) = browser.client.getJSON(url)
        guard response.isSuccess, let data = json as? [String: Any],
              let items = data["items"] as? [[String: Any]] else { return [] }

        return items.prefix(3).compactMap { item -> WebResult? in
            guard let title = item["title"] as? String else { return nil }
            let answered = item["is_answered"] as? Bool ?? false
            let score = item["score"] as? Int ?? 0
            let link = item["link"] as? String
            let decoded = title.replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")
            return WebResult(title: "\(decoded) [score:\(score)\(answered ? ", answered" : "")]",
                           content: "", url: link)
        }
    }

    // MARK: - Source 4: MCP Tools

    private func searchMCP(task: String, domain: SearchDomain, runtime: BuiltinRuntime) -> [SearchResult] {
        guard domain == .biotech else { return [] }
        let mcp = runtime.mcpClient
        var results: [SearchResult] = []

        // Extract key terms for bio search
        let terms = task.lowercased().split(separator: " " as Character)
            .map(String.init)
            .filter { $0.count > 3 }
            .prefix(3)
            .joined(separator: " ")

        // Try bioRxiv preprints
        if let r = mcp.callTool(qualifiedName: "search_preprints", arguments: ["query": terms, "limit": 3]) {
            if !r.isError && !r.content.isEmpty {
                results.append(SearchResult(source: "bioRxiv", title: "Preprint search: \(terms)",
                                           content: String(r.content.prefix(500)), url: nil, score: 0.8, latencyMs: 0))
            }
        }

        // Try ChEMBL compound search
        if let r = mcp.callTool(qualifiedName: "compound_search", arguments: ["name": terms, "limit": 3]) {
            if !r.isError && !r.content.isEmpty {
                results.append(SearchResult(source: "ChEMBL", title: "Compound search: \(terms)",
                                           content: String(r.content.prefix(500)), url: nil, score: 0.75, latencyMs: 0))
            }
        }

        // Try clinical trials
        if let r = mcp.callTool(qualifiedName: "search_trials", arguments: ["condition": terms, "page_size": 3]) {
            if !r.isError && !r.content.isEmpty {
                results.append(SearchResult(source: "ClinicalTrials", title: "Trial search: \(terms)",
                                           content: String(r.content.prefix(500)), url: nil, score: 0.7, latencyMs: 0))
            }
        }

        return results
    }

    // MARK: - XML Helpers

    private func extractXMLTag(_ xml: String, tag: String) -> String? {
        guard let startRange = xml.range(of: "<\(tag)"),
              let tagClose = xml[startRange.upperBound...].firstIndex(of: ">"),
              let endRange = xml[tagClose...].range(of: "</\(tag)>") else { return nil }
        return String(xml[xml.index(after: tagClose)..<endRange.lowerBound])
    }

    private func extractXMLAttribute(_ xml: String, tag: String) -> String? {
        guard let startRange = xml.range(of: "<\(tag)>"),
              let endRange = xml[startRange.upperBound...].range(of: "</\(tag)>") else { return nil }
        return String(xml[startRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private func elapsed(_ start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    private func palaceDirectory(runtime: BuiltinRuntime) -> URL {
        let home: String
        if let override = runtime.context.environment["DODEXABASH_HOME"], !override.isEmpty {
            home = override
        } else {
            home = runtime.context.currentDirectory + "/.dodexabash"
        }
        return URL(fileURLWithPath: home).appendingPathComponent("palace", isDirectory: true)
    }
}
