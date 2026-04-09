import Foundation

// MARK: - Query Translator: PRISM → Database-Specific Search Strings
// Translates universal PRISM queries into the exact syntax of each target.
// Handles controlled vocabulary, field tags, subheadings, proximity, truncation.
// Covers 15 databases: PubMed, Embase, Cochrane, CINAHL, PsycINFO, WoS, Scopus,
// bioRxiv, medRxiv, ClinicalTrials.gov, arXiv, GitHub, Scholar, DuckDuckGo, ERIC.

public final class QueryTranslator: @unchecked Sendable {

    public init() {}

    public func translate(query: PRISMQuery, target: DatabaseTarget) -> PRISMStrategy {
        let blocks = query.activeFacets.map { facet in
            translateFacet(facet, target: target)
        }.filter { !$0.isEmpty }

        let booleanQuery = blocks.joined(separator: "\n  AND\n")
        let url = buildURL(query: booleanQuery, rawQuery: query.question, target: target)

        return PRISMStrategy(
            target: target,
            booleanQuery: booleanQuery.isEmpty ? simplifyForWeb(query.question) : booleanQuery,
            searchURL: url,
            facetBlocks: blocks,
            lineCount: blocks.count
        )
    }

    // MARK: - Facet Translation (dispatch by target)

    private func translateFacet(_ facet: PRISMFacet, target: DatabaseTarget) -> String {
        let terms = facet.exploded.isEmpty ? facet.terms : facet.exploded
        guard !terms.isEmpty else { return "" }

        switch target {
        case .pubmed:       return translatePubMed(terms: terms, meshTerms: facet.meshTerms, type: facet.type)
        case .embase:       return translateEmbase(terms: terms, type: facet.type)
        case .cochrane:     return translateCochrane(terms: terms, meshTerms: facet.meshTerms, type: facet.type)
        case .cinahl:       return translateCINAHL(terms: terms, type: facet.type)
        case .psycinfo:     return translatePsycINFO(terms: terms, type: facet.type)
        case .webOfScience: return translateWoS(terms: terms)
        case .scopus:       return translateScopus(terms: terms)
        case .eric:         return translateERIC(terms: terms, type: facet.type)
        default:            return translatePlainText(terms: terms)
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - PubMed / MEDLINE (NLM) — MeSH + [tiab] + [pt]
    // ═══════════════════════════════════════════════════════════════

    private func translatePubMed(terms: [String], meshTerms: [String], type: PRISMFacetType) -> String {
        var parts: [String] = []

        // MeSH terms with explosion (automatic in PubMed)
        for mesh in meshTerms {
            parts.append("\"\(mesh)\"[MeSH]")
        }

        // Free-text terms in title/abstract
        for term in terms {
            if term.contains("*") {
                parts.append("\(term)[tiab]")
            } else if term.contains(" ") {
                parts.append("\"\(term)\"[tiab]")
            } else if term.count <= 4 && term == term.uppercased() {
                // Short abbreviation — search as text word for broader matching
                parts.append("\(term)[tw]")
            } else {
                parts.append("\(term)[tiab]")
            }
        }

        // Publication type filter for design facet
        if type == .design {
            appendPubMedDesignFilters(terms: terms, to: &parts)
        }

        guard !parts.isEmpty else { return "" }
        return "(" + Array(Set(parts)).sorted().joined(separator: " OR ") + ")"
    }

    private func appendPubMedDesignFilters(terms: [String], to parts: inout [String]) {
        for term in terms {
            let lower = term.lowercased()
            if lower.contains("rct") || lower.contains("randomi") {
                parts.append("\"Randomized Controlled Trial\"[pt]")
                parts.append("\"Randomized Controlled Trials as Topic\"[MeSH]")
            }
            if lower.contains("cohort") {
                parts.append("\"Cohort Studies\"[MeSH]")
                parts.append("\"Longitudinal Studies\"[MeSH]")
            }
            if lower.contains("case-control") || lower.contains("case control") {
                parts.append("\"Case-Control Studies\"[MeSH]")
            }
            if lower.contains("systematic review") {
                parts.append("\"Systematic Review\"[pt]")
                parts.append("\"Systematic Reviews as Topic\"[MeSH]")
            }
            if lower.contains("meta-analy") || lower.contains("meta analy") {
                parts.append("\"Meta-Analysis\"[pt]")
                parts.append("\"Meta-Analysis as Topic\"[MeSH]")
            }
            if lower.contains("cross-section") || lower.contains("cross section") {
                parts.append("\"Cross-Sectional Studies\"[MeSH]")
            }
            if lower.contains("observational") {
                parts.append("\"Observational Study\"[pt]")
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Embase (Elsevier) — Emtree /exp + :ti,ab + NEAR/n
    // ═══════════════════════════════════════════════════════════════

    private func translateEmbase(terms: [String], type: PRISMFacetType) -> String {
        var parts: [String] = []

        for term in terms {
            if term.contains("*") {
                parts.append("\(term):ti,ab")
            } else if term.contains(" ") {
                // Emtree explosion: use /exp for multi-word controlled terms
                parts.append("'\(term)'/exp")
                parts.append("'\(term)':ti,ab")
            } else if term.count <= 4 && term == term.uppercased() {
                parts.append("\(term):ti,ab")
            } else {
                parts.append("'\(term)'/exp")
                parts.append("\(term):ti,ab")
            }
        }

        // Design filter
        if type == .design {
            for term in terms {
                let lower = term.lowercased()
                if lower.contains("rct") || lower.contains("randomi") {
                    parts.append("'randomized controlled trial'/exp")
                }
                if lower.contains("cohort") {
                    parts.append("'cohort analysis'/exp")
                }
                if lower.contains("meta-analy") {
                    parts.append("'meta analysis'/exp")
                }
            }
        }

        return parts.isEmpty ? "" : "(" + parts.joined(separator: " OR ") + ")"
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Cochrane Library — MeSH [mh] + :ti,ab,kw + NEAR/n
    // ═══════════════════════════════════════════════════════════════

    private func translateCochrane(terms: [String], meshTerms: [String], type: PRISMFacetType) -> String {
        var parts: [String] = []

        // MeSH terms (Cochrane uses [mh] syntax)
        for mesh in meshTerms {
            parts.append("[mh \"\(mesh)\"]")
        }

        for term in terms {
            if term.contains("*") {
                parts.append("\(term):ti,ab,kw")
            } else if term.contains(" ") {
                parts.append("\"\(term)\":ti,ab,kw")
            } else {
                parts.append("\(term):ti,ab,kw")
            }
        }

        return parts.isEmpty ? "" : "(" + parts.joined(separator: " OR ") + ")"
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - CINAHL (EBSCO) — (MH "term+") + TI + AB
    // ═══════════════════════════════════════════════════════════════

    private func translateCINAHL(terms: [String], type: PRISMFacetType) -> String {
        var parts: [String] = []

        for term in terms {
            if term.contains("*") {
                parts.append("TI \(term) OR AB \(term)")
            } else if term.contains(" ") {
                // CINAHL Subject Heading with explosion (+)
                parts.append("(MH \"\(term)+\")")
                parts.append("TI \"\(term)\" OR AB \"\(term)\"")
            } else if term.count <= 4 && term == term.uppercased() {
                parts.append("TX \(term)")
            } else {
                parts.append("(MH \"\(term)+\")")
                parts.append("TI \(term) OR AB \(term)")
            }
        }

        // CINAHL-specific design filters
        if type == .design {
            for term in terms {
                let lower = term.lowercased()
                if lower.contains("rct") || lower.contains("randomi") {
                    parts.append("PT \"Randomized Controlled Trial\"")
                }
                if lower.contains("systematic review") {
                    parts.append("PT \"Systematic Review\"")
                }
            }
        }

        return parts.isEmpty ? "" : "(" + parts.joined(separator: " OR ") + ")"
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - PsycINFO (APA/EBSCO) — DE "term" + TI + AB
    // ═══════════════════════════════════════════════════════════════

    private func translatePsycINFO(terms: [String], type: PRISMFacetType) -> String {
        var parts: [String] = []

        for term in terms {
            if term.contains("*") {
                parts.append("TI \(term) OR AB \(term)")
            } else if term.contains(" ") {
                parts.append("DE \"\(term)\"")                  // PsycINFO descriptor
                parts.append("TI \"\(term)\" OR AB \"\(term)\"")
            } else {
                parts.append("DE \"\(term)\"")
                parts.append("TI \(term) OR AB \(term)")
            }
        }

        // PsycINFO methodology field
        if type == .design {
            for term in terms {
                let lower = term.lowercased()
                if lower.contains("rct") || lower.contains("randomi") { parts.append("MD \"Empirical Study\"") }
                if lower.contains("meta-analy") { parts.append("MD \"Meta Analysis\"") }
                if lower.contains("systematic review") { parts.append("MD \"Literature Review\"") }
            }
        }

        return parts.isEmpty ? "" : "(" + parts.joined(separator: " OR ") + ")"
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Web of Science (Clarivate) — TS= + NEAR/n + SAME
    // ═══════════════════════════════════════════════════════════════

    private func translateWoS(terms: [String]) -> String {
        let parts = terms.map { term -> String in
            if term.contains("*") { return "TS=\(term)" }
            if term.contains(" ") { return "TS=\"\(term)\"" }
            return "TS=\(term)"
        }
        return parts.isEmpty ? "" : "(" + parts.joined(separator: " OR ") + ")"
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Scopus (Elsevier) — TITLE-ABS-KEY() + W/n + PRE/n
    // ═══════════════════════════════════════════════════════════════

    private func translateScopus(terms: [String]) -> String {
        let parts = terms.map { term -> String in
            if term.contains("*") { return "TITLE-ABS-KEY(\(term))" }
            if term.contains(" ") { return "TITLE-ABS-KEY(\"\(term)\")" }
            return "TITLE-ABS-KEY(\(term))"
        }
        return parts.isEmpty ? "" : "(" + parts.joined(separator: " OR ") + ")"
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - ERIC (Education) — DE "descriptor" + TI + AB
    // ═══════════════════════════════════════════════════════════════

    private func translateERIC(terms: [String], type: PRISMFacetType) -> String {
        var parts: [String] = []
        for term in terms {
            if term.contains(" ") {
                parts.append("DE \"\(term)\"")
                parts.append("TI \"\(term)\" OR AB \"\(term)\"")
            } else {
                parts.append("TI \(term) OR AB \(term)")
            }
        }
        return parts.isEmpty ? "" : "(" + parts.joined(separator: " OR ") + ")"
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Plain Text (for non-Boolean: bioRxiv, arXiv, GitHub, etc.)
    // ═══════════════════════════════════════════════════════════════

    private func translatePlainText(terms: [String]) -> String {
        let cleaned = terms.map { $0.replacingOccurrences(of: "*", with: "") }
        if cleaned.count == 1 { return cleaned[0] }
        return "(" + cleaned.joined(separator: " OR ") + ")"
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Validated Search Filters (Cochrane-grade)
    // ═══════════════════════════════════════════════════════════════

    /// Cochrane Highly Sensitive Search Strategy for RCTs (PubMed version)
    public static let cochraneSensitiveRCT_PubMed = """
    ("Randomized Controlled Trial"[pt] OR "Controlled Clinical Trial"[pt] OR randomized[tiab] OR placebo[tiab] OR "drug therapy"[sh] OR randomly[tiab] OR trial[tiab] OR groups[tiab])
    NOT ("Animals"[MeSH] NOT ("Humans"[MeSH] AND "Animals"[MeSH]))
    """

    /// BMJ Clinical Queries Sensitive filter for therapy
    public static let bmqSensitiveTherapy_PubMed = """
    (clinical[tiab] AND trial[tiab]) OR "clinical trials as topic"[MeSH] OR "clinical trial"[pt] OR random*[tiab] OR "random allocation"[MeSH] OR "therapeutic use"[sh]
    """

    /// Systematic Review filter (PubMed)
    public static let systematicReviewFilter_PubMed = """
    ("Systematic Review"[pt] OR "Meta-Analysis"[pt] OR "systematic review"[tiab] OR "meta-analysis"[tiab] OR "systematic literature review"[tiab] OR PRISMA[tiab] OR "evidence synthesis"[tiab])
    """

    /// Observational studies filter (PubMed)
    public static let observationalFilter_PubMed = """
    ("Cohort Studies"[MeSH] OR "Case-Control Studies"[MeSH] OR "Cross-Sectional Studies"[MeSH] OR "Observational Study"[pt] OR cohort[tiab] OR "case-control"[tiab] OR "cross-sectional"[tiab] OR longitudinal[tiab] OR retrospective[tiab] OR prospective[tiab])
    """

    // ═══════════════════════════════════════════════════════════════
    // MARK: - URL Construction
    // ═══════════════════════════════════════════════════════════════

    private func buildURL(query: String, rawQuery: String, target: DatabaseTarget) -> String? {
        switch target {
        case .pubmed:
            let flat = flattenBoolean(query)
            let encoded = flat.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? flat
            return "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&retmode=json&retmax=20&term=\(encoded)"

        case .scholar:
            let flat = simplifyForWeb(query)
            let encoded = flat.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? flat
            return "https://scholar.google.com/scholar?q=\(encoded)"

        case .bioRxiv, .medRxiv:
            let server = target == .bioRxiv ? "biorxiv" : "medrxiv"
            return "https://api.biorxiv.org/details/\(server)/2024-01-01/2026-12-31/0/10"

        case .arxiv:
            let flat = simplifyForWeb(query)
            let encoded = flat.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? flat
            return "http://export.arxiv.org/api/query?search_query=all:\(encoded)&max_results=10&sortBy=relevance"

        case .clinicalTrials:
            let flat = simplifyForWeb(query)
            let encoded = flat.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? flat
            return "https://clinicaltrials.gov/api/v2/studies?query.term=\(encoded)&pageSize=10&format=json"

        case .github:
            let flat = simplifyForWeb(query)
            let encoded = flat.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? flat
            return "https://api.github.com/search/repositories?q=\(encoded)&sort=stars&per_page=5"

        case .duckduckgo:
            let flat = simplifyForWeb(query)
            let encoded = flat.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? flat
            return "https://html.duckduckgo.com/html/?q=\(encoded)"

        // Databases requiring institutional access — generate query string only (no URL)
        case .embase, .cochrane, .cinahl, .psycinfo, .webOfScience, .scopus, .eric:
            return nil
        }
    }

    // MARK: - Helpers

    private func flattenBoolean(_ query: String) -> String {
        query.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  AND  ", with: " AND ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private func simplifyForWeb(_ query: String) -> String {
        var s = query
        s = s.replacingOccurrences(of: "\\[\\w+\\]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\(MH [^)]+\\)", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "DE ", with: "")
        s = s.replacingOccurrences(of: "TI ", with: "")
        s = s.replacingOccurrences(of: "AB ", with: "")
        s = s.replacingOccurrences(of: "TX ", with: "")
        s = s.replacingOccurrences(of: "TS=", with: "")
        s = s.replacingOccurrences(of: "TITLE-ABS-KEY(", with: "").replacingOccurrences(of: ")", with: "")
        s = s.replacingOccurrences(of: ":ti,ab,kw", with: "").replacingOccurrences(of: ":ti,ab", with: "")
        s = s.replacingOccurrences(of: "/exp", with: "")
        s = s.replacingOccurrences(of: "[pt]", with: "").replacingOccurrences(of: "[tw]", with: "")
        s = s.replacingOccurrences(of: "*", with: "")
        s = s.replacingOccurrences(of: " OR ", with: " ").replacingOccurrences(of: " AND ", with: " ")
        s = s.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        s = s.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\"", with: "")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
