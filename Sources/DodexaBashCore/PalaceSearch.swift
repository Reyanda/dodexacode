import Foundation

// MARK: - Palace Search: TF-IDF Vector Search Engine
// Pure Swift implementation — zero dependencies.
// Indexes drawer content for semantic-ish retrieval using term frequency.

// MARK: - Search Result

public struct PalaceSearchResult: Sendable {
    public let drawerId: String
    public let wing: String
    public let room: String
    public let summary: String
    public let score: Double
    public let content: String
}

// MARK: - TF-IDF Search Engine

public final class PalaceSearchEngine: @unchecked Sendable {
    // Document frequency: how many documents contain each term
    private var df: [String: Int] = [:]
    // Per-document term frequency vectors
    private var docVectors: [String: [String: Double]] = [:]  // docId -> {term: tf-idf}
    // Document metadata
    private var docMeta: [String: (wing: String, room: String, summary: String, content: String)] = [:]
    private var totalDocs: Int = 0

    public init() {}

    // MARK: - Indexing

    public func indexDrawer(_ drawer: PalaceDrawer) {
        let docId = drawer.id
        let text = drawer.content + " " + drawer.summary + " " + drawer.tags.joined(separator: " ")
        let terms = tokenize(text)
        let tf = termFrequency(terms)

        // Update document frequency
        for term in Set(terms) {
            df[term, default: 0] += 1
        }
        totalDocs += 1

        docVectors[docId] = tf
        docMeta[docId] = (drawer.wing, drawer.room, drawer.summary, String(drawer.content.prefix(200)))
    }

    public func indexAll(_ drawers: [PalaceDrawer]) {
        // Reset
        df = [:]
        docVectors = [:]
        docMeta = [:]
        totalDocs = 0

        for drawer in drawers {
            indexDrawer(drawer)
        }
        // Recompute TF-IDF with full DF table
        recomputeTFIDF()
    }

    public func removeDocument(id: String) {
        docVectors.removeValue(forKey: id)
        docMeta.removeValue(forKey: id)
    }

    // MARK: - Search

    public func search(query: String, limit: Int = 10, wing: String? = nil, room: String? = nil) -> [PalaceSearchResult] {
        let queryTerms = tokenize(query)
        guard !queryTerms.isEmpty else { return [] }

        let queryVector = termFrequency(queryTerms)

        var scored: [(id: String, score: Double)] = []

        for (docId, docVector) in docVectors {
            // Filter by wing/room if specified
            if let meta = docMeta[docId] {
                if let w = wing, meta.wing.lowercased() != w.lowercased() { continue }
                if let r = room, meta.room.lowercased() != r.lowercased() { continue }
            }

            let score = cosineSimilarity(a: queryVector, b: docVector)
            if score > 0.01 {
                scored.append((docId, score))
            }
        }

        // Sort by score descending
        scored.sort { $0.score > $1.score }

        return scored.prefix(limit).compactMap { item -> PalaceSearchResult? in
            guard let meta = docMeta[item.id] else { return nil }
            return PalaceSearchResult(
                drawerId: item.id,
                wing: meta.wing,
                room: meta.room,
                summary: meta.summary,
                score: item.score,
                content: meta.content
            )
        }
    }

    // MARK: - TF-IDF Math

    private func termFrequency(_ terms: [String]) -> [String: Double] {
        var freq: [String: Int] = [:]
        for term in terms {
            freq[term, default: 0] += 1
        }
        let maxFreq = Double(freq.values.max() ?? 1)
        return freq.mapValues { 0.5 + 0.5 * (Double($0) / maxFreq) }
    }

    private func recomputeTFIDF() {
        let n = Double(max(1, totalDocs))
        for (docId, tf) in docVectors {
            var tfidf: [String: Double] = [:]
            for (term, freq) in tf {
                let idf = log(n / Double(df[term, default: 1] + 1)) + 1.0
                tfidf[term] = freq * idf
            }
            docVectors[docId] = tfidf
        }
    }

    private func cosineSimilarity(a: [String: Double], b: [String: Double]) -> Double {
        var dotProduct = 0.0
        var normA = 0.0
        var normB = 0.0

        let allTerms = Set(a.keys).union(b.keys)
        for term in allTerms {
            let va = a[term] ?? 0.0
            let vb = b[term] ?? 0.0
            dotProduct += va * vb
            normA += va * va
            normB += vb * vb
        }

        let denominator = sqrt(normA) * sqrt(normB)
        return denominator > 0 ? dotProduct / denominator : 0.0
    }

    // MARK: - Tokenization

    private func tokenize(_ text: String) -> [String] {
        let lowered = text.lowercased()

        // Split on non-alphanumeric characters
        let words = lowered.split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }
            .map(String.init)
            .filter { $0.count >= 2 }

        // Remove stop words
        return words.filter { !stopWords.contains($0) }
    }

    private let stopWords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did", "will", "would", "could",
        "should", "may", "might", "shall", "can", "need", "must",
        "to", "of", "in", "for", "on", "with", "at", "by", "from", "as",
        "or", "and", "but", "if", "not", "no", "so", "up", "out",
        "it", "its", "this", "that", "these", "those", "he", "she", "they",
        "we", "you", "me", "him", "her", "us", "them", "my", "your", "his",
        "our", "their", "what", "which", "who", "when", "where", "how", "all",
        "each", "every", "both", "few", "more", "most", "other", "some", "such",
        "than", "too", "very", "just", "because", "about", "into", "through",
        "during", "before", "after", "above", "below", "between", "same",
        "let", "var", "func", "return", "import", "public", "private", "static"
    ]

    // MARK: - Stats

    public var indexedDocuments: Int { docVectors.count }
    public var vocabularySize: Int { df.count }
}
