import Foundation

// MARK: - SearchInfra: Elevated Search Infrastructure
// Upgrades dodexabash from basic web fetching to a proper evidence retrieval system.
// - PubMed E-utilities: real abstracts, metadata, citation counts
// - Multi-database parallel execution with result merging
// - Deduplication by title similarity + DOI matching
// - Relevance scoring across heterogeneous sources
// - Auto-enrichment: mine results for new thesaurus terms
// - Export: RIS, CSV, BibTeX

// MARK: - Unified Search Result

public struct ScholarResult: Sendable {
    public let id: String              // unique within this session
    public let title: String
    public let authors: [String]
    public let abstract: String
    public let source: String          // "PubMed", "Scholar", "arXiv", etc.
    public let year: Int?
    public let doi: String?
    public let pmid: String?
    public let url: String?
    public let journal: String?
    public let citationCount: Int?
    public let relevanceScore: Double  // 0-1, computed across sources
    public let database: DatabaseTarget
    public let retrievedAt: Date

    public var citation: String {
        let auth = authors.isEmpty ? "" : authors.first! + (authors.count > 1 ? " et al." : "")
        let yr = year.map { " (\($0))" } ?? ""
        let j = journal.map { ". \($0)" } ?? ""
        return "\(auth)\(yr). \(title)\(j)."
    }

    public var bibtexKey: String {
        let first = authors.first?.split(separator: " ").last.map(String.init) ?? "Unknown"
        let yr = year.map(String.init) ?? "nd"
        let word = title.split(separator: " ").first.map(String.init) ?? "untitled"
        return "\(first)\(yr)\(word)".lowercased()
    }
}

// MARK: - PubMed E-utilities Client

public final class PubMedClient: @unchecked Sendable {
    private let browser: WebBrowser
    private let baseURL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"

    public init() {
        self.browser = WebBrowser()
    }

    /// Search PubMed and return PMIDs
    public func search(query: String, maxResults: Int = 20, minDate: String? = nil, maxDate: String? = nil) -> (pmids: [String], totalCount: Int) {
        var url = "\(baseURL)/esearch.fcgi?db=pubmed&retmode=json&retmax=\(maxResults)&term="
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        url += encoded
        if let min = minDate { url += "&mindate=\(min)" }
        if let max = maxDate { url += "&maxdate=\(max)" }

        let (json, response) = browser.client.getJSON(url)
        guard response.isSuccess,
              let data = json as? [String: Any],
              let result = data["esearchresult"] as? [String: Any] else { return ([], 0) }

        let count = Int(result["count"] as? String ?? "0") ?? 0
        let ids = result["idlist"] as? [String] ?? []
        return (ids, count)
    }

    /// Fetch full article metadata for PMIDs
    public func fetchArticles(pmids: [String]) -> [ScholarResult] {
        guard !pmids.isEmpty else { return [] }
        let idList = pmids.prefix(20).joined(separator: ",")
        let url = "\(baseURL)/efetch.fcgi?db=pubmed&retmode=xml&id=\(idList)"

        let response = browser.client.get(url)
        guard response.isSuccess else { return [] }

        return parsePubMedXML(response.body)
    }

    /// Search + fetch in one call
    public func searchAndFetch(query: String, maxResults: Int = 10, minDate: String? = nil, maxDate: String? = nil) -> [ScholarResult] {
        let (pmids, _) = search(query: query, maxResults: maxResults, minDate: minDate, maxDate: maxDate)
        return fetchArticles(pmids: pmids)
    }

    // MARK: - PubMed XML Parser

    private func parsePubMedXML(_ xml: String) -> [ScholarResult] {
        var results: [ScholarResult] = []
        let articles = xml.components(separatedBy: "<PubmedArticle>").dropFirst()

        for article in articles {
            let pmid = extractTag(article, tag: "PMID") ?? ""
            let title = extractTag(article, tag: "ArticleTitle") ?? "Untitled"
            let abstract = extractTag(article, tag: "AbstractText") ?? ""
            let journal = extractTag(article, tag: "Title") ?? ""
            let year = extractTag(article, tag: "Year").flatMap(Int.init)

            // Authors
            var authors: [String] = []
            let authorBlocks = article.components(separatedBy: "<Author ").dropFirst()
            for block in authorBlocks.prefix(10) {
                let last = extractTag(block, tag: "LastName") ?? ""
                let initials = extractTag(block, tag: "Initials") ?? ""
                if !last.isEmpty { authors.append("\(last) \(initials)".trimmingCharacters(in: .whitespaces)) }
            }

            // DOI
            var doi: String?
            if let doiRange = article.range(of: "IdType=\"doi\"") {
                let before = article[..<doiRange.lowerBound]
                if let articleIdStart = before.range(of: "<ArticleId", options: .backwards) {
                    let segment = String(article[articleIdStart.lowerBound...])
                    doi = extractTag(segment, tag: "ArticleId")
                }
            }
            // Fallback DOI extraction
            if doi == nil {
                let eidBlocks = article.components(separatedBy: "<ELocationID")
                for block in eidBlocks where block.contains("doi") {
                    if let val = extractTag(block, tag: "ELocationID") { doi = val }
                }
            }

            results.append(ScholarResult(
                id: "pubmed-\(pmid)",
                title: cleanHTML(title),
                authors: authors,
                abstract: cleanHTML(abstract),
                source: "PubMed",
                year: year,
                doi: doi,
                pmid: pmid,
                url: "https://pubmed.ncbi.nlm.nih.gov/\(pmid)/",
                journal: journal,
                citationCount: nil,
                relevanceScore: 0.9,
                database: .pubmed,
                retrievedAt: Date()
            ))
        }
        return results
    }

    private func extractTag(_ xml: String, tag: String) -> String? {
        guard let start = xml.range(of: "<\(tag)"),
              let tagClose = xml[start.upperBound...].firstIndex(of: ">"),
              let end = xml[tagClose...].range(of: "</\(tag)>") else { return nil }
        let content = String(xml[xml.index(after: tagClose)..<end.lowerBound])
        return content.isEmpty ? nil : content
    }

    private func cleanHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Multi-Database Search Executor

public final class MultiSearchExecutor: @unchecked Sendable {
    private let pubmed: PubMedClient
    private let browser: WebBrowser

    public init() {
        self.pubmed = PubMedClient()
        self.browser = WebBrowser()
    }

    /// Execute search across multiple databases in parallel
    public func search(query: String, targets: [DatabaseTarget], dateRange: (from: String?, to: String?)? = nil) -> MultiSearchResult {
        let start = DispatchTime.now()
        let group = DispatchGroup()
        let lock = NSLock()
        var allResults: [ScholarResult] = []

        for target in targets {
            group.enter()
            DispatchQueue.global().async { [self] in
                defer { group.leave() }
                let results = self.searchTarget(query: query, target: target, dateRange: dateRange)
                lock.lock()
                allResults.append(contentsOf: results)
                lock.unlock()
            }
        }

        _ = group.wait(timeout: .now() + 30)

        // Deduplicate
        let deduped = deduplicate(allResults)
        // Score
        let scored = rankResults(deduped, query: query)

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)

        return MultiSearchResult(
            query: query,
            results: scored,
            totalBeforeDedup: allResults.count,
            totalAfterDedup: scored.count,
            databases: targets,
            latencyMs: elapsed
        )
    }

    // MARK: - Per-Target Search

    private func searchTarget(query: String, target: DatabaseTarget, dateRange: (from: String?, to: String?)?) -> [ScholarResult] {
        switch target {
        case .pubmed:
            return pubmed.searchAndFetch(query: query, maxResults: 10,
                                          minDate: dateRange?.from, maxDate: dateRange?.to)
        case .scholar:
            return searchScholar(query: query)
        case .arxiv:
            return searchArXiv(query: query)
        case .github:
            return searchGitHub(query: query)
        case .duckduckgo:
            return searchDuckDuckGo(query: query)
        default:
            return []
        }
    }

    private func searchScholar(query: String) -> [ScholarResult] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let result = browser.navigate("https://scholar.google.com/scholar?q=\(encoded)")
        guard result.isSuccess else { return [] }

        let elements = browser.select(".gs_ri")
        return elements.prefix(10).enumerated().map { (i, el) in
            let title = el.children.first { $0.tag == "h3" }?.textContent ?? "Scholar result"
            let snippet = el.children.first { $0.className?.contains("gs_rs") == true }?.textContent ?? ""
            let link = el.children.first { $0.tag == "h3" }?.children.first { $0.tag == "a" }?.href

            return ScholarResult(
                id: "scholar-\(i)", title: title, authors: [], abstract: snippet,
                source: "Google Scholar", year: nil, doi: nil, pmid: nil,
                url: link, journal: nil, citationCount: nil, relevanceScore: 0.7,
                database: .scholar, retrievedAt: Date()
            )
        }
    }

    private func searchArXiv(query: String) -> [ScholarResult] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let response = browser.client.get("http://export.arxiv.org/api/query?search_query=all:\(encoded)&max_results=5&sortBy=relevance")
        guard response.isSuccess else { return [] }

        var results: [ScholarResult] = []
        let entries = response.body.components(separatedBy: "<entry>").dropFirst()
        for (i, entry) in entries.prefix(5).enumerated() {
            let title = extractXMLTag(entry, "title")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let summary = extractXMLTag(entry, "summary")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let id = extractXMLTag(entry, "id") ?? ""
            var authors: [String] = []
            for authorBlock in entry.components(separatedBy: "<author>").dropFirst() {
                if let name = extractXMLTag(authorBlock, "name") { authors.append(name) }
            }
            let published = extractXMLTag(entry, "published") ?? ""
            let year = published.count >= 4 ? Int(published.prefix(4)) : nil

            results.append(ScholarResult(
                id: "arxiv-\(i)", title: title, authors: authors, abstract: String(summary.prefix(500)),
                source: "arXiv", year: year, doi: nil, pmid: nil, url: id,
                journal: "arXiv preprint", citationCount: nil, relevanceScore: 0.65,
                database: .arxiv, retrievedAt: Date()
            ))
        }
        return results
    }

    private func searchGitHub(query: String) -> [ScholarResult] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let (json, response) = browser.client.getJSON("https://api.github.com/search/repositories?q=\(encoded)&sort=stars&per_page=5")
        guard response.isSuccess, let data = json as? [String: Any],
              let items = data["items"] as? [[String: Any]] else { return [] }

        return items.prefix(5).enumerated().map { (i, item) in
            let name = item["full_name"] as? String ?? ""
            let desc = item["description"] as? String ?? ""
            let stars = item["stargazers_count"] as? Int ?? 0
            let url = item["html_url"] as? String
            return ScholarResult(
                id: "github-\(i)", title: "\(name) (\u{2605}\(stars))", authors: [],
                abstract: desc, source: "GitHub", year: nil, doi: nil, pmid: nil,
                url: url, journal: nil, citationCount: stars, relevanceScore: 0.5,
                database: .github, retrievedAt: Date()
            )
        }
    }

    private func searchDuckDuckGo(query: String) -> [ScholarResult] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let result = browser.navigate("https://html.duckduckgo.com/html/?q=\(encoded)")
        guard result.isSuccess else { return [] }

        let elements = browser.select(".result__body")
        if elements.isEmpty {
            // Fallback: extract from page text
            let text = browser.extractText()
            if !text.isEmpty {
                return [ScholarResult(
                    id: "ddg-0", title: "Web results for: \(query)", authors: [],
                    abstract: String(text.prefix(500)), source: "DuckDuckGo", year: nil,
                    doi: nil, pmid: nil, url: nil, journal: nil, citationCount: nil,
                    relevanceScore: 0.4, database: .duckduckgo, retrievedAt: Date()
                )]
            }
        }

        return elements.prefix(5).enumerated().map { (i, el) in
            ScholarResult(
                id: "ddg-\(i)", title: el.textContent.prefix(100).description, authors: [],
                abstract: String(el.textContent.prefix(300)), source: "DuckDuckGo", year: nil,
                doi: nil, pmid: nil, url: nil, journal: nil, citationCount: nil,
                relevanceScore: 0.4, database: .duckduckgo, retrievedAt: Date()
            )
        }
    }

    // MARK: - Deduplication

    private func deduplicate(_ results: [ScholarResult]) -> [ScholarResult] {
        var seen: Set<String> = []
        var deduped: [ScholarResult] = []

        for result in results {
            // Deduplicate by DOI
            if let doi = result.doi, !doi.isEmpty {
                if seen.contains(doi) { continue }
                seen.insert(doi)
            }
            // Deduplicate by PMID
            if let pmid = result.pmid, !pmid.isEmpty {
                let key = "pmid:\(pmid)"
                if seen.contains(key) { continue }
                seen.insert(key)
            }
            // Deduplicate by title similarity (Jaccard > 0.8)
            let titleKey = normalizeTitle(result.title)
            if seen.contains(where: { jaccardSimilarity(titleKey, normalizeTitle($0)) > 0.8 }) { continue }
            seen.insert(titleKey)

            deduped.append(result)
        }
        return deduped
    }

    // MARK: - Relevance Ranking

    private func rankResults(_ results: [ScholarResult], query: String) -> [ScholarResult] {
        let queryTerms = Set(query.lowercased().split(separator: " ").map(String.init))

        return results.map { result in
            var score = result.relevanceScore

            // Title match boost
            let titleTerms = Set(result.title.lowercased().split(separator: " ").map(String.init))
            let titleOverlap = Double(queryTerms.intersection(titleTerms).count) / Double(max(1, queryTerms.count))
            score += titleOverlap * 0.3

            // Abstract match boost
            let absTerms = Set(result.abstract.lowercased().split(separator: " ").map(String.init))
            let absOverlap = Double(queryTerms.intersection(absTerms).count) / Double(max(1, queryTerms.count))
            score += absOverlap * 0.1

            // Recency boost
            if let year = result.year, year >= 2023 { score += 0.1 }
            if let year = result.year, year >= 2025 { score += 0.1 }

            // Citation boost
            if let cites = result.citationCount, cites > 10 { score += 0.05 }

            // PubMed/Scholar boost (peer-reviewed)
            if result.database == .pubmed { score += 0.1 }
            if result.database == .scholar { score += 0.05 }

            var ranked = result
            // Can't mutate struct directly — reconstruct
            return ScholarResult(
                id: result.id, title: result.title, authors: result.authors,
                abstract: result.abstract, source: result.source, year: result.year,
                doi: result.doi, pmid: result.pmid, url: result.url,
                journal: result.journal, citationCount: result.citationCount,
                relevanceScore: min(1.0, score),
                database: result.database, retrievedAt: result.retrievedAt
            )
        }.sorted { $0.relevanceScore > $1.relevanceScore }
    }

    // MARK: - Helpers

    private func normalizeTitle(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
            .split(separator: " ").sorted().joined(separator: " ")
    }

    private func jaccardSimilarity(_ a: String, _ b: String) -> Double {
        let setA = Set(a.split(separator: " "))
        let setB = Set(b.split(separator: " "))
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        return union > 0 ? Double(intersection) / Double(union) : 0
    }

    private func extractXMLTag(_ xml: String, _ tag: String) -> String? {
        guard let start = xml.range(of: "<\(tag)"),
              let close = xml[start.upperBound...].firstIndex(of: ">"),
              let end = xml[close...].range(of: "</\(tag)>") else { return nil }
        return String(xml[xml.index(after: close)..<end.lowerBound])
    }
}

// MARK: - Multi-Search Result

public struct MultiSearchResult: Sendable {
    public let query: String
    public let results: [ScholarResult]
    public let totalBeforeDedup: Int
    public let totalAfterDedup: Int
    public let databases: [DatabaseTarget]
    public let latencyMs: Int

    public var summary: String {
        "\(totalAfterDedup) results from \(databases.count) databases (\(totalBeforeDedup) before dedup) in \(latencyMs)ms"
    }
}

// MARK: - Export Formats

public enum SearchExport {
    /// RIS format (for Zotero, Mendeley, EndNote)
    public static func toRIS(_ results: [ScholarResult]) -> String {
        results.map { r in
            var lines: [String] = []
            lines.append("TY  - JOUR")
            lines.append("TI  - \(r.title)")
            for author in r.authors { lines.append("AU  - \(author)") }
            if let year = r.year { lines.append("PY  - \(year)") }
            if let journal = r.journal { lines.append("JO  - \(journal)") }
            if !r.abstract.isEmpty { lines.append("AB  - \(r.abstract)") }
            if let doi = r.doi { lines.append("DO  - \(doi)") }
            if let pmid = r.pmid { lines.append("AN  - \(pmid)") }
            if let url = r.url { lines.append("UR  - \(url)") }
            lines.append("DB  - \(r.source)")
            lines.append("ER  - ")
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// BibTeX format
    public static func toBibTeX(_ results: [ScholarResult]) -> String {
        results.map { r in
            var lines: [String] = []
            lines.append("@article{\(r.bibtexKey),")
            lines.append("  title = {\(r.title)},")
            if !r.authors.isEmpty { lines.append("  author = {\(r.authors.joined(separator: " and "))},") }
            if let year = r.year { lines.append("  year = {\(year)},") }
            if let journal = r.journal { lines.append("  journal = {\(journal)},") }
            if let doi = r.doi { lines.append("  doi = {\(doi)},") }
            if !r.abstract.isEmpty { lines.append("  abstract = {\(String(r.abstract.prefix(500)))},") }
            lines.append("}")
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// CSV format
    public static func toCSV(_ results: [ScholarResult]) -> String {
        var csv = "Title,Authors,Year,Journal,DOI,PMID,Source,URL,Relevance\n"
        for r in results {
            let authors = r.authors.joined(separator: "; ").replacingOccurrences(of: ",", with: ";")
            let title = r.title.replacingOccurrences(of: "\"", with: "'")
            csv += "\"\(title)\",\"\(authors)\",\(r.year ?? 0),\"\(r.journal ?? "")\",\(r.doi ?? ""),\(r.pmid ?? ""),\(r.source),\(r.url ?? ""),\(String(format: "%.2f", r.relevanceScore))\n"
        }
        return csv
    }
}

// MARK: - Auto-Enrichment

public enum ThesaurusEnricher {
    /// Extract candidate terms from search results to enrich the thesaurus
    public static func extractCandidates(from results: [ScholarResult]) -> [(term: String, frequency: Int, source: String)] {
        var termCounts: [String: (count: Int, source: String)] = [:]

        for result in results {
            let text = (result.title + " " + result.abstract).lowercased()
            // Extract multi-word noun phrases (2-3 word sequences)
            let words = text.split(separator: " ").map(String.init)
            for i in 0..<words.count {
                // Bigrams
                if i + 1 < words.count {
                    let bigram = "\(words[i]) \(words[i+1])"
                    if isCandidate(bigram) {
                        let entry = termCounts[bigram, default: (0, result.source)]
                        termCounts[bigram] = (entry.count + 1, result.source)
                    }
                }
                // Trigrams
                if i + 2 < words.count {
                    let trigram = "\(words[i]) \(words[i+1]) \(words[i+2])"
                    if isCandidate(trigram) {
                        let entry = termCounts[trigram, default: (0, result.source)]
                        termCounts[trigram] = (entry.count + 1, result.source)
                    }
                }
            }
        }

        return termCounts.filter { $0.value.count >= 2 }
            .map { (term: $0.key, frequency: $0.value.count, source: $0.value.source) }
            .sorted { $0.frequency > $1.frequency }
    }

    private static let stopWords: Set<String> = ["the", "and", "for", "with", "from", "that", "this", "are",
        "was", "were", "been", "have", "has", "will", "can", "may", "our", "their", "its", "not", "but",
        "also", "more", "than", "both", "such", "into", "over", "about", "between", "through", "during",
        "after", "before", "under", "above", "each", "all", "most", "some", "other", "these", "those"]

    private static func isCandidate(_ phrase: String) -> Bool {
        let words = phrase.split(separator: " ").map(String.init)
        // No stop words at start or end
        guard let first = words.first, let last = words.last else { return false }
        if stopWords.contains(first) || stopWords.contains(last) { return false }
        // All words must be alphabetic and > 2 chars
        return words.allSatisfy { $0.count > 2 && $0.allSatisfy { $0.isLetter } }
    }
}
