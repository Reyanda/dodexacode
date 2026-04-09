import Foundation

// MARK: - MESH-X: Multi-domain, Multi-index Epidemiological Search Hierarchy - Extended
// A multidimensional framework for systematic and comprehensive epidemiological search.
// Extends PI/ECOTS into a hyper-faceted graph structure.

public enum EpiDomain: String, Codable, CaseIterable, Sendable {
    case population      // P: Age, Gender, Ethnicity, Risk groups
    case exposure        // I/E: Intervention, Exposure, Toxins, Pathogens
    case comparison      // C: Control group, Baseline, Alternative exposure
    case outcome         // O: Mortality, Morbidity, Quality of Life, Bio-markers
    case temporal        // T: Seasonality, Latency, Duration, Trend
    case setting         // S: Geography, Healthcare level, Environment (Urban/Rural)
    case policy          // Non-pharmaceutical interventions, Mandates, Guidelines
    case socioeconomic   // Education, Income, Employment, Social determinants
}

public struct EpiFacet: Codable, Sendable {
    public let domain: EpiDomain
    public let terms: [String]
    public let expandedTerms: [String]  // Brain-exploded synonyms, MeSH, ICD codes
}

public struct MESHXQuery: Codable, Sendable {
    public let id: String
    public let title: String
    public let facets: [EpiFacet]
    public let createdAt: Date
    
    public var combinedQuery: String {
        facets.map { facet in
            let all = (facet.terms + facet.expandedTerms).unique()
            return "(\(all.joined(separator: " OR ")))"
        }.joined(separator: " AND ")
    }
}

// MARK: - Epi Search Engine

public final class EpiSearchEngine: @unchecked Sendable {
    private let brain: LocalBrain
    private let research: ResearchEngine
    
    public init(brain: LocalBrain, research: ResearchEngine) {
        self.brain = brain
        self.research = research
    }
    
    /// Build a MESH-X framework from a natural language task
    public func buildFramework(task: String, cwd: String, recentHistory: [String]) -> MESHXQuery? {
        let systemPrompt = """
        You are an expert Epidemiologist and Information Specialist. 
        Convert the following research request into a MESH-X multidimensional search framework.
        
        MESH-X Domains:
        - population (P)
        - exposure (E)
        - comparison (C)
        - outcome (O)
        - temporal (T)
        - setting (S)
        - policy
        - socioeconomic
        
        For each relevant domain, provide 2-3 core terms. 
        Then, EXPAND those terms with relevant MeSH terms, synonyms, and variant spellings.
        
        Output format:
        TITLE: <short title>
        DOMAIN: <domain_name>
        TERMS: <term1>, <term2>
        EXPANDED: <mesh_term>, <synonym1>, <synonym2>
        ... (repeat for each domain)
        """
        
        guard let response = brain.askExtended(question: task, cwd: cwd, lastStatus: 0, recentHistory: recentHistory, context: systemPrompt) else {
            return nil
        }
        
        return parseMESHX(response)
    }
    
    private func parseMESHX(_ raw: String) -> MESHXQuery {
        var title = "Epidemiological Study"
        var facets: [EpiFacet] = []
        
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        var currentDomain: EpiDomain?
        var currentTerms: [String] = []
        var currentExpanded: [String] = []
        
        func flushFacet() {
            if let domain = currentDomain {
                facets.append(EpiFacet(domain: domain, terms: currentTerms, expandedTerms: currentExpanded))
            }
            currentDomain = nil
            currentTerms = []
            currentExpanded = []
        }
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("TITLE:") {
                title = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.uppercased().hasPrefix("DOMAIN:") {
                flushFacet()
                let domainStr = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces).lowercased()
                currentDomain = EpiDomain(rawValue: domainStr)
            } else if trimmed.uppercased().hasPrefix("TERMS:") {
                currentTerms = String(trimmed.dropFirst(6)).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if trimmed.uppercased().hasPrefix("EXPANDED:") {
                currentExpanded = String(trimmed.dropFirst(9)).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        flushFacet()
        
        return MESHXQuery(id: UUID().uuidString, title: title, facets: facets, createdAt: Date())
    }
}

// Helper
extension Array where Element == String {
    func unique() -> [String] {
        return Array(Set(self)).sorted()
    }
}
