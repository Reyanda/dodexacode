import Foundation

// MARK: - PRISM: Programmable Research & Information Synthesis Matrix
// Universal multidimensional search framework that generalizes PICO/PECOTS.
// 8 facets: Population, Realm, Intervention, Standard, Measure + Time, Geography, Design
// Each facet is exploded through the Thesaurus before Boolean strategy construction.

// MARK: - Facets

public enum PRISMFacetType: String, Codable, Sendable, CaseIterable {
    case population     // P — who/what is studied
    case realm          // R — domain/discipline
    case intervention   // I — what is applied/tested
    case standard       // S — compared to what
    case measure        // M — what is measured
    case time           // T — temporal scope (modifier)
    case geography      // G — setting/context (modifier)
    case design         // D — methodology/study type (modifier)

    public var label: String {
        switch self {
        case .population: return "Population / Phenomenon"
        case .realm: return "Realm / Domain"
        case .intervention: return "Intervention / Input"
        case .standard: return "Standard / Comparator"
        case .measure: return "Measure / Outcome"
        case .time: return "Time / Temporal"
        case .geography: return "Geography / Setting"
        case .design: return "Design / Methodology"
        }
    }

    public var code: String { String(rawValue.prefix(1)).uppercased() }
    public var isCore: Bool { [.population, .intervention, .measure].contains(self) }
}

public struct PRISMFacet: Codable, Sendable {
    public let type: PRISMFacetType
    public var terms: [String]              // user-provided terms
    public var exploded: [String]           // after thesaurus explosion
    public var meshTerms: [String]          // controlled vocabulary terms
    public var fieldTags: [String: String]  // database-specific: "pubmed": "[MeSH]", "embase": "/exp"

    public init(type: PRISMFacetType, terms: [String] = []) {
        self.type = type
        self.terms = terms
        self.exploded = []
        self.meshTerms = []
        self.fieldTags = [:]
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// Build Boolean OR block for this facet
    public func booleanBlock(target: DatabaseTarget = .pubmed) -> String {
        let allTerms = (exploded.isEmpty ? terms : exploded) + meshTerms
        guard !allTerms.isEmpty else { return "" }

        let formatted = allTerms.map { term -> String in
            if term.contains("*") { return term }  // truncation — no quotes
            if term.contains(" ") { return "\"\(term)\"" }
            return term
        }

        if formatted.count == 1 { return formatted[0] }
        return "(" + formatted.joined(separator: " OR ") + ")"
    }
}

// MARK: - PRISM Query

public struct PRISMQuery: Sendable {
    public let question: String
    public var facets: [PRISMFacetType: PRISMFacet]
    public let createdAt: Date
    public var realm: SearchDomain?         // detected domain for routing

    public init(question: String) {
        self.question = question
        self.facets = [:]
        self.createdAt = Date()
        self.realm = nil
        for type in PRISMFacetType.allCases {
            facets[type] = PRISMFacet(type: type)
        }
    }

    public func facet(_ type: PRISMFacetType) -> PRISMFacet {
        facets[type] ?? PRISMFacet(type: type)
    }

    public var activeFacets: [PRISMFacet] {
        PRISMFacetType.allCases.compactMap { type in
            let f = facets[type]
            return (f?.isEmpty == false) ? f : nil
        }
    }

    /// Build full Boolean strategy: AND between non-empty facets
    public func booleanStrategy(target: DatabaseTarget = .pubmed) -> String {
        let blocks = activeFacets.map { facet in
            let block = facet.booleanBlock(target: target)
            return block.isEmpty ? nil : block
        }.compactMap { $0 }

        if blocks.isEmpty { return question }
        return blocks.joined(separator: "\n  AND\n")
    }

    /// Human-readable summary of facet decomposition
    public var summary: String {
        var lines: [String] = ["PRISM Decomposition:"]
        for type in PRISMFacetType.allCases {
            let f = facets[type] ?? PRISMFacet(type: type)
            if !f.isEmpty {
                let terms = f.terms.joined(separator: ", ")
                let explCount = f.exploded.count
                let explLabel = explCount > 0 ? " → \(explCount) exploded terms" : ""
                lines.append("  \(type.code) [\(type.label)]: \(terms)\(explLabel)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Database Targets

public enum DatabaseTarget: String, Codable, Sendable, CaseIterable {
    case pubmed
    case embase
    case cochrane
    case cinahl
    case psycinfo
    case webOfScience
    case scopus
    case bioRxiv
    case medRxiv
    case clinicalTrials
    case arxiv
    case github
    case duckduckgo
    case scholar
    case eric

    public var label: String {
        switch self {
        case .pubmed: return "PubMed/MEDLINE"
        case .embase: return "Embase"
        case .cochrane: return "Cochrane Library"
        case .cinahl: return "CINAHL"
        case .psycinfo: return "PsycINFO"
        case .webOfScience: return "Web of Science"
        case .scopus: return "Scopus"
        case .bioRxiv: return "bioRxiv"
        case .medRxiv: return "medRxiv"
        case .clinicalTrials: return "ClinicalTrials.gov"
        case .arxiv: return "arXiv"
        case .github: return "GitHub"
        case .duckduckgo: return "DuckDuckGo"
        case .scholar: return "Google Scholar"
        case .eric: return "ERIC"
        }
    }

    public var vocabulary: String {
        switch self {
        case .pubmed, .cochrane: return "MeSH"
        case .embase: return "Emtree"
        case .cinahl: return "CINAHL Headings"
        case .psycinfo: return "PsycINFO Thesaurus"
        case .eric: return "ERIC Descriptors"
        default: return "Free text"
        }
    }

    public var supportsBoolean: Bool {
        switch self {
        case .pubmed, .embase, .cochrane, .cinahl, .psycinfo, .webOfScience, .scopus, .eric: return true
        default: return false
        }
    }

    public var supportsControlledVocabulary: Bool {
        switch self {
        case .pubmed, .embase, .cochrane, .cinahl, .psycinfo, .eric: return true
        default: return false
        }
    }

    public var supportsProximity: Bool {
        switch self {
        case .embase, .cochrane, .webOfScience, .scopus: return true
        default: return false
        }
    }

    public var supportsSubheadings: Bool {
        switch self {
        case .pubmed, .embase, .cochrane, .cinahl: return true
        default: return false
        }
    }
}

// MARK: - PRISM Engine

public final class PRISMEngine: @unchecked Sendable {
    public let thesaurus: Thesaurus
    private let browser: WebBrowser

    public init(thesaurusDir: URL) {
        self.thesaurus = Thesaurus(directory: thesaurusDir)
        self.browser = WebBrowser()
    }

    // MARK: - Decompose Question into Facets

    /// Use brain to decompose a question into PRISM facets
    public func decompose(question: String, brain: LocalBrain?) -> PRISMQuery {
        var query = PRISMQuery(question: question)

        // Try AI decomposition first
        if let brain, brain.config.enabled, brain.isAvailable() {
            if let aiDecomposition = brainDecompose(question: question, brain: brain) {
                query = aiDecomposition
            }
        }

        // If brain unavailable or empty result, use heuristic decomposition
        if query.activeFacets.isEmpty {
            query = heuristicDecompose(question: question)
        }

        // Detect realm/domain
        let re = ResearchEngine()
        query.realm = re.detectDomain(question)

        return query
    }

    // MARK: - Explode All Facets

    /// Run thesaurus explosion on all facets
    public func explode(_ query: inout PRISMQuery) {
        for type in PRISMFacetType.allCases {
            guard var facet = query.facets[type], !facet.isEmpty else { continue }
            var allExploded: [String] = []
            for term in facet.terms {
                allExploded.append(contentsOf: thesaurus.explode(term, depth: 1))
            }
            facet.exploded = Array(Set(allExploded)).sorted()
            query.facets[type] = facet
        }
    }

    // MARK: - Build Strategy for Target

    public func strategy(_ query: PRISMQuery, target: DatabaseTarget) -> PRISMStrategy {
        let translator = QueryTranslator()
        return translator.translate(query: query, target: target)
    }

    public func allStrategies(_ query: PRISMQuery) -> [DatabaseTarget: PRISMStrategy] {
        let translator = QueryTranslator()
        var strategies: [DatabaseTarget: PRISMStrategy] = [:]
        let targets = relevantTargets(for: query.realm ?? .general)
        for target in targets {
            strategies[target] = translator.translate(query: query, target: target)
        }
        return strategies
    }

    // MARK: - Execute Search

    public func search(_ query: PRISMQuery, targets: [DatabaseTarget]? = nil) -> [PRISMSearchResult] {
        let effectiveTargets = targets ?? relevantTargets(for: query.realm ?? .general)
        var results: [PRISMSearchResult] = []

        for target in effectiveTargets {
            let strategy = self.strategy(query, target: target)
            let targetResults = executeStrategy(strategy, target: target)
            results.append(contentsOf: targetResults)
        }

        return results.sorted { $0.relevance > $1.relevance }
    }

    // MARK: - Target Selection

    public func relevantTargets(for domain: SearchDomain) -> [DatabaseTarget] {
        switch domain {
        case .biotech:
            return [.pubmed, .embase, .cochrane, .cinahl, .scholar, .bioRxiv, .medRxiv, .clinicalTrials, .scopus]
        case .academic:
            return [.scholar, .pubmed, .scopus, .webOfScience, .arxiv, .duckduckgo]
        case .software:
            return [.github, .duckduckgo, .scholar, .arxiv, .scopus]
        case .general:
            return [.duckduckgo, .scholar, .github, .pubmed, .scopus]
        }
    }

    // MARK: - AI Decomposition

    private func brainDecompose(question: String, brain: LocalBrain) -> PRISMQuery? {
        let prompt = """
        Decompose this research question into PRISM facets. Output EXACTLY this format:
        P: <population/phenomenon terms, comma-separated>
        R: <realm/domain>
        I: <intervention/input terms, comma-separated>
        S: <standard/comparator terms, comma-separated>
        M: <measure/outcome terms, comma-separated>
        T: <time scope, or empty>
        G: <geography/setting, or empty>
        D: <study design, or empty>

        Question: \(question)
        """

        guard let result = brain.askExtended(question: prompt, cwd: ".", lastStatus: 0,
                                              recentHistory: [], context: nil, maxTokens: 512) else { return nil }

        var query = PRISMQuery(question: question)

        for line in result.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count > 2 else { continue }
            let code = String(trimmed.prefix(1)).uppercased()
            guard trimmed.dropFirst().first == ":" else { continue }
            let value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value.lowercased() != "empty", value != "-" else { continue }

            let terms = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !terms.isEmpty else { continue }

            let type: PRISMFacetType? = {
                switch code {
                case "P": return .population
                case "R": return .realm
                case "I": return .intervention
                case "S": return .standard
                case "M": return .measure
                case "T": return .time
                case "G": return .geography
                case "D": return .design
                default: return nil
                }
            }()

            if let type {
                query.facets[type] = PRISMFacet(type: type, terms: terms)
            }
        }

        return query.activeFacets.isEmpty ? nil : query
    }

    // MARK: - Heuristic Decomposition (fallback)

    private func heuristicDecompose(question: String) -> PRISMQuery {
        var query = PRISMQuery(question: question)
        let words = question.lowercased().split(separator: " ").map(String.init)

        // Simple heuristic: split question into key phrases
        // Look for patterns like "effect of X on Y in Z"
        let lower = question.lowercased()

        // Intervention indicators
        let interventionPhrases = ["effect of", "impact of", "role of", "efficacy of", "effectiveness of", "use of"]
        for phrase in interventionPhrases {
            if let range = lower.range(of: phrase) {
                let after = String(lower[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let term = after.components(separatedBy: " on ").first ??
                           after.components(separatedBy: " in ").first ?? after
                let cleaned = String(term.prefix(50)).trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty {
                    query.facets[.intervention] = PRISMFacet(type: .intervention, terms: [cleaned])
                }
            }
        }

        // Outcome indicators
        let outcomePhrases = [" on ", " reduces ", " prevents ", " improves ", " affects "]
        for phrase in outcomePhrases {
            if let range = lower.range(of: phrase) {
                let after = String(lower[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let term = after.components(separatedBy: " in ").first ??
                           after.components(separatedBy: " among ").first ?? after
                let cleaned = String(term.prefix(50)).trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty {
                    query.facets[.measure] = PRISMFacet(type: .measure, terms: [cleaned])
                }
            }
        }

        // Population indicators
        let populationPhrases = [" in ", " among ", " for ", " patients with "]
        for phrase in populationPhrases {
            if let range = lower.range(of: phrase, options: .backwards) {
                let after = String(lower[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let cleaned = String(after.prefix(50)).trimmingCharacters(in: .init(charactersIn: "?.!"))
                if !cleaned.isEmpty && cleaned.split(separator: " ").count <= 6 {
                    query.facets[.population] = PRISMFacet(type: .population, terms: [cleaned])
                }
            }
        }

        // If nothing was extracted, use the full question as a single search term
        if query.activeFacets.isEmpty {
            query.facets[.population] = PRISMFacet(type: .population, terms: [question])
        }

        return query
    }

    // MARK: - Execute Strategy Against Target

    private func executeStrategy(_ strategy: PRISMStrategy, target: DatabaseTarget) -> [PRISMSearchResult] {
        guard let url = strategy.searchURL else {
            return []
        }

        let response = browser.client.get(url)
        guard response.isSuccess else { return [] }

        // Parse results based on target
        switch target {
        case .pubmed:
            return parsePubMedResults(response.body, strategy: strategy)
        case .scholar:
            return parseScholarResults(response.body, strategy: strategy)
        default:
            // Generic text extraction
            let parser = HTMLParser()
            let doc = parser.parse(response.body)
            return [PRISMSearchResult(
                title: doc.title,
                source: target.label,
                content: String(doc.text.prefix(500)),
                url: url,
                relevance: 0.5,
                database: target
            )]
        }
    }

    private func parsePubMedResults(_ body: String, strategy: PRISMStrategy) -> [PRISMSearchResult] {
        // Parse PubMed eSearch JSON results
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["esearchresult"] as? [String: Any],
              let count = result["count"] as? String else { return [] }

        return [PRISMSearchResult(
            title: "PubMed: \(count) results",
            source: "PubMed",
            content: "Found \(count) articles matching PRISM strategy",
            url: strategy.searchURL,
            relevance: 0.9,
            database: .pubmed
        )]
    }

    private func parseScholarResults(_ body: String, strategy: PRISMStrategy) -> [PRISMSearchResult] {
        let parser = HTMLParser()
        let elements = parser.query(body, selector: ".gs_ri")
        return elements.prefix(5).map { el in
            PRISMSearchResult(
                title: el.children.first { $0.tag == "h3" }?.textContent ?? "Scholar result",
                source: "Google Scholar",
                content: String(el.textContent.prefix(300)),
                url: nil,
                relevance: 0.8,
                database: .scholar
            )
        }
    }
}

// MARK: - Search Result

public struct PRISMSearchResult: Sendable {
    public let title: String
    public let source: String
    public let content: String
    public let url: String?
    public let relevance: Double
    public let database: DatabaseTarget
}

// MARK: - Strategy (generated for a specific database)

public struct PRISMStrategy: Codable, Sendable {
    public let target: DatabaseTarget
    public let booleanQuery: String     // full Boolean string
    public let searchURL: String?       // ready-to-execute URL
    public let facetBlocks: [String]    // individual facet blocks
    public let lineCount: Int           // number of search lines
}
