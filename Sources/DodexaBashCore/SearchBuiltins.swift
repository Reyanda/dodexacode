import Foundation

// MARK: - Search Builtins: Elevated search commands

extension Builtins {
    static func searchBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let sub = args.first ?? "help"

        // If first arg isn't a subcommand, treat as search query
        let knownSubs: Set<String> = ["pubmed", "scholar", "arxiv", "github", "all", "export", "enrich", "help"]
        if !knownSubs.contains(sub) {
            let query = args.joined(separator: " ")
            return searchAll(query: query, runtime: runtime)
        }

        let subArgs = Array(args.dropFirst())

        switch sub {
        case "pubmed":
            return searchPubMed(args: subArgs, runtime: runtime)
        case "scholar":
            return searchScholar(args: subArgs, runtime: runtime)
        case "arxiv":
            return searchArXiv(args: subArgs, runtime: runtime)
        case "github":
            return searchGitHub(args: subArgs, runtime: runtime)
        case "all":
            let query = subArgs.filter { !$0.hasPrefix("--") }.joined(separator: " ")
            return searchAll(query: query, runtime: runtime)
        case "export":
            return searchExport(args: subArgs, runtime: runtime)
        case "enrich":
            return searchEnrich(args: subArgs, runtime: runtime)
        default:
            return searchHelp()
        }
    }

    // MARK: - Search All (parallel multi-database)

    private static func searchAll(query: String, runtime: BuiltinRuntime) -> CommandResult {
        guard !query.isEmpty else { return textResult("Usage: search <query>\n") }

        let executor = MultiSearchExecutor()
        let targets: [DatabaseTarget] = [.pubmed, .scholar, .arxiv, .github, .duckduckgo]
        let result = executor.search(query: query, targets: targets)

        // Store results for export
        lastSearchResults = result.results

        var lines: [String] = []
        lines.append("\u{001B}[1mSearch: \(query)\u{001B}[0m")
        lines.append("\u{001B}[2m\(result.summary)\u{001B}[0m")
        lines.append("")

        for (i, r) in result.results.prefix(15).enumerated() {
            let score = String(format: "%.0f%%", r.relevanceScore * 100)
            let src = r.source.padding(toLength: 12, withPad: " ", startingAt: 0)
            lines.append("\u{001B}[33m[\(i+1)]\u{001B}[0m \u{001B}[2m\(src)\u{001B}[0m \u{001B}[1m\(r.title)\u{001B}[0m")

            if !r.authors.isEmpty {
                let authStr = r.authors.count > 3
                    ? "\(r.authors[0]) et al."
                    : r.authors.joined(separator: ", ")
                lines.append("     \(authStr)\(r.year.map { " (\($0))" } ?? "")\(r.journal.map { " — \($0)" } ?? "")")
            }

            if !r.abstract.isEmpty {
                lines.append("     \u{001B}[2m\(String(r.abstract.prefix(150)))\u{001B}[0m")
            }

            if let url = r.url {
                lines.append("     \u{001B}[36m\(url)\u{001B}[0m")
            }

            lines.append("     Relevance: \(score)\(r.doi.map { " | DOI: \($0)" } ?? "")\(r.pmid.map { " | PMID: \($0)" } ?? "")")
            lines.append("")
        }

        lines.append("\u{001B}[2mExport: 'search export ris', 'search export csv', 'search export bibtex'\u{001B}[0m")
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - PubMed (with real abstracts)

    private static func searchPubMed(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let query = args.filter { !$0.hasPrefix("--") }.joined(separator: " ")
        guard !query.isEmpty else { return textResult("Usage: search pubmed <query>\n") }

        let client = PubMedClient()
        let results = client.searchAndFetch(query: query, maxResults: 10)
        lastSearchResults = results

        if results.isEmpty { return textResult("No PubMed results for '\(query)'.\n") }

        var lines: [String] = ["\u{001B}[1mPubMed Results (\(results.count)):\u{001B}[0m", ""]

        for (i, r) in results.enumerated() {
            lines.append("\u{001B}[33m[\(i+1)]\u{001B}[0m \u{001B}[1m\(r.title)\u{001B}[0m")
            let authStr = r.authors.count > 3 ? "\(r.authors[0]) et al." : r.authors.joined(separator: ", ")
            lines.append("    \(authStr)\(r.year.map { " (\($0))" } ?? "") — \(r.journal ?? "")")
            if !r.abstract.isEmpty {
                lines.append("    \u{001B}[2m\(String(r.abstract.prefix(200)))\u{001B}[0m")
            }
            lines.append("    PMID: \(r.pmid ?? "?")\(r.doi.map { " | DOI: \($0)" } ?? "")")
            lines.append("    \u{001B}[36m\(r.url ?? "")\u{001B}[0m")
            lines.append("")
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Scholar

    private static func searchScholar(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let query = args.joined(separator: " ")
        guard !query.isEmpty else { return textResult("Usage: search scholar <query>\n") }
        let executor = MultiSearchExecutor()
        let result = executor.search(query: query, targets: [.scholar])
        lastSearchResults = result.results
        return formatResults("Google Scholar", result.results)
    }

    // MARK: - arXiv

    private static func searchArXiv(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let query = args.joined(separator: " ")
        guard !query.isEmpty else { return textResult("Usage: search arxiv <query>\n") }
        let executor = MultiSearchExecutor()
        let result = executor.search(query: query, targets: [.arxiv])
        lastSearchResults = result.results
        return formatResults("arXiv", result.results)
    }

    // MARK: - GitHub

    private static func searchGitHub(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let query = args.joined(separator: " ")
        guard !query.isEmpty else { return textResult("Usage: search github <query>\n") }
        let executor = MultiSearchExecutor()
        let result = executor.search(query: query, targets: [.github])
        lastSearchResults = result.results
        return formatResults("GitHub", result.results)
    }

    // MARK: - Export

    nonisolated(unsafe) private static var lastSearchResults: [ScholarResult] = []

    private static func searchExport(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard !lastSearchResults.isEmpty else {
            return textResult("No search results to export. Run a search first.\n")
        }

        let format = args.first ?? "ris"
        let output: String
        let filename: String

        switch format.lowercased() {
        case "ris":
            output = SearchExport.toRIS(lastSearchResults)
            filename = "search_results.ris"
        case "bibtex", "bib":
            output = SearchExport.toBibTeX(lastSearchResults)
            filename = "search_results.bib"
        case "csv":
            output = SearchExport.toCSV(lastSearchResults)
            filename = "search_results.csv"
        default:
            return textResult("Formats: ris, bibtex, csv\n")
        }

        // Write to file
        let cwd = runtime.context.currentDirectory
        let path = cwd + "/" + filename
        try? Data(output.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)

        return textResult("Exported \(lastSearchResults.count) results → \(filename) (\(format.uppercased()))\n\(output.prefix(500))\n")
    }

    // MARK: - Auto-Enrich Thesaurus

    private static func searchEnrich(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard !lastSearchResults.isEmpty else {
            return textResult("No search results to enrich from. Run a search first.\n")
        }

        let candidates = ThesaurusEnricher.extractCandidates(from: lastSearchResults)
        if candidates.isEmpty { return textResult("No candidate terms found.\n") }

        var lines: [String] = ["Candidate terms for thesaurus enrichment (\(candidates.count)):"]
        for c in candidates.prefix(20) {
            lines.append("  [\(c.frequency)x] \(c.term) (\(c.source))")
        }
        lines.append("")
        lines.append("Add with: prism thesaurus add \"<term>\" <synonyms...>")
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Format

    private static func formatResults(_ source: String, _ results: [ScholarResult]) -> CommandResult {
        if results.isEmpty { return textResult("No results.\n") }
        var lines: [String] = ["\u{001B}[1m\(source) Results (\(results.count)):\u{001B}[0m", ""]
        for (i, r) in results.prefix(10).enumerated() {
            lines.append("\u{001B}[33m[\(i+1)]\u{001B}[0m \u{001B}[1m\(r.title)\u{001B}[0m")
            if !r.abstract.isEmpty { lines.append("    \u{001B}[2m\(String(r.abstract.prefix(150)))\u{001B}[0m") }
            if let url = r.url { lines.append("    \u{001B}[36m\(url)\u{001B}[0m") }
            lines.append("")
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Help

    private static func searchHelp() -> CommandResult {
        textResult("""
        Elevated Search — Multi-database evidence retrieval

        Commands:
          search <query>              Search all databases in parallel
          search pubmed <query>       PubMed with real abstracts + metadata
          search scholar <query>      Google Scholar
          search arxiv <query>        arXiv preprints
          search github <query>       GitHub repositories
          search all <query>          Explicit all-database search

        Export:
          search export ris           Export to RIS (Zotero/Mendeley/EndNote)
          search export bibtex        Export to BibTeX (LaTeX)
          search export csv           Export to CSV (Excel/Sheets)

        Enrichment:
          search enrich               Extract candidate thesaurus terms from results

        Features:
          - Parallel multi-database execution
          - Automatic deduplication (DOI + title similarity)
          - Relevance ranking across heterogeneous sources
          - PubMed: real abstracts, authors, DOIs, PMIDs
          - Export to reference managers

        """)
    }
}
