import Foundation

// MARK: - PRISM Builtins: Shell commands for the search framework

extension Builtins {
    static func prismBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let thesaurusDir = prismDirectory(runtime: runtime).appendingPathComponent("thesaurus")
        let engine = PRISMEngine(thesaurusDir: thesaurusDir)
        let sub = args.first ?? "help"

        // If first arg doesn't match a subcommand, treat as a question
        let knownSubs: Set<String> = ["facets", "explode", "strategy", "search", "thesaurus", "history", "help"]
        if !knownSubs.contains(sub) {
            let question = args.joined(separator: " ")
            return prismDecompose(question: question, engine: engine, runtime: runtime)
        }

        let subArgs = Array(args.dropFirst())

        switch sub {
        case "explode":
            return prismExplode(args: subArgs, engine: engine)
        case "strategy":
            return prismStrategy(args: subArgs, engine: engine, runtime: runtime)
        case "search":
            return prismSearch(args: subArgs, engine: engine, runtime: runtime)
        case "thesaurus":
            return prismThesaurus(args: subArgs, engine: engine, runtime: runtime)
        case "help":
            return prismHelp()
        default:
            return prismHelp()
        }
    }

    // MARK: - Decompose Question

    private static func prismDecompose(question: String, engine: PRISMEngine, runtime: BuiltinRuntime) -> CommandResult {
        var query = engine.decompose(question: question, brain: runtime.brain)
        engine.explode(&query)

        var lines: [String] = []
        lines.append("\u{001B}[1mPRISM Analysis\u{001B}[0m")
        lines.append("Question: \(question)")
        lines.append("Domain: \(query.realm?.rawValue ?? "general")")
        lines.append("")

        // Show facets
        for type in PRISMFacetType.allCases {
            let facet = query.facet(type)
            guard !facet.isEmpty else { continue }
            let icon = type.isCore ? "\u{001B}[32m\u{25CF}\u{001B}[0m" : "\u{001B}[2m\u{25CB}\u{001B}[0m"
            lines.append("\(icon) \u{001B}[1m\(type.code)\u{001B}[0m [\(type.label)]")
            lines.append("    Terms: \(facet.terms.joined(separator: ", "))")
            if !facet.exploded.isEmpty {
                lines.append("    Exploded (\(facet.exploded.count)): \(facet.exploded.prefix(8).joined(separator: ", "))\(facet.exploded.count > 8 ? "..." : "")")
            }
        }

        // Show Boolean strategy for most relevant target
        lines.append("")
        let target: DatabaseTarget = query.realm == .biotech ? .pubmed : .duckduckgo
        let strategy = engine.strategy(query, target: target)
        lines.append("\u{001B}[1mBoolean Strategy (\(target.label)):\u{001B}[0m")
        lines.append(strategy.booleanQuery)

        if let url = strategy.searchURL {
            lines.append("")
            lines.append("\u{001B}[2mSearch URL: \(String(url.prefix(120)))\u{001B}[0m")
        }

        lines.append("")
        lines.append("Next: 'prism strategy --all' for all databases, 'prism search' to execute")

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Explode Term

    private static func prismExplode(args: [String], engine: PRISMEngine) -> CommandResult {
        guard !args.isEmpty else { return textResult("Usage: prism explode <term>\n") }
        let term = args.joined(separator: " ")
        let node = engine.thesaurus.lookup(term)

        if let node {
            var lines: [String] = ["\u{001B}[1m\(node.preferred)\u{001B}[0m"]
            if let mesh = node.meshId { lines.append("  MeSH: \(mesh)") }
            lines.append("  Domain: \(node.domain)")
            if !node.synonyms.isEmpty { lines.append("  Synonyms: \(node.synonyms.joined(separator: ", "))") }
            if !node.narrower.isEmpty { lines.append("  Narrower: \(node.narrower.joined(separator: ", "))") }
            if !node.broader.isEmpty { lines.append("  Broader: \(node.broader.joined(separator: ", "))") }
            if !node.related.isEmpty { lines.append("  Related: \(node.related.joined(separator: ", "))") }
            if !node.abbreviations.isEmpty { lines.append("  Abbreviations: \(node.abbreviations.joined(separator: ", "))") }
            if !node.truncations.isEmpty { lines.append("  Truncations: \(node.truncations.joined(separator: ", "))") }
            lines.append("")
            let exploded = engine.thesaurus.explode(term)
            lines.append("  Boolean: \(engine.thesaurus.explodeToBoolean(term))")
            lines.append("  Total terms: \(exploded.count)")
            return textResult(lines.joined(separator: "\n") + "\n")
        }

        // Try MeSH API
        lines: do {
            var lines: [String] = ["'\(term)' not in local thesaurus."]
            lines.append("Checking MeSH API...")
            if let meshNode = engine.thesaurus.fetchMeSH(term) {
                lines.append("Found in MeSH: \(meshNode.preferred)")
                lines.append("  Synonyms: \(meshNode.synonyms.joined(separator: ", "))")
                lines.append("  Added to local thesaurus.")
            } else {
                lines.append("Not found in MeSH either.")
                lines.append("Add manually: prism thesaurus add \"\(term)\" synonym1 synonym2")
            }
            return textResult(lines.joined(separator: "\n") + "\n")
        }
    }

    // MARK: - Strategy

    private static func prismStrategy(args: [String], engine: PRISMEngine, runtime: BuiltinRuntime) -> CommandResult {
        // Need a prior decomposition — use the last question or require one
        let question = args.filter { !$0.hasPrefix("--") }.joined(separator: " ")
        guard !question.isEmpty else {
            return textResult("Usage: prism strategy <question> [--pubmed|--all]\n")
        }

        var query = engine.decompose(question: question, brain: runtime.brain)
        engine.explode(&query)

        let showAll = args.contains("--all")
        let targets: [DatabaseTarget]
        if showAll {
            targets = engine.relevantTargets(for: query.realm ?? .general)
        } else if args.contains("--pubmed") {
            targets = [.pubmed]
        } else if args.contains("--scholar") {
            targets = [.scholar]
        } else {
            targets = engine.relevantTargets(for: query.realm ?? .general)
        }

        var lines: [String] = ["\u{001B}[1mPRISM Search Strategies\u{001B}[0m"]
        lines.append("Question: \(question)")
        lines.append("")

        for target in targets {
            let strategy = engine.strategy(query, target: target)
            lines.append("\u{001B}[1m\u{2500}\u{2500} \(target.label) (\(strategy.lineCount) lines)\u{001B}[0m")
            lines.append(strategy.booleanQuery)
            if let url = strategy.searchURL {
                lines.append("\u{001B}[2mURL: \(String(url.prefix(100)))\u{001B}[0m")
            }
            lines.append("")
        }

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Search

    private static func prismSearch(args: [String], engine: PRISMEngine, runtime: BuiltinRuntime) -> CommandResult {
        let question = args.filter { !$0.hasPrefix("--") }.joined(separator: " ")
        guard !question.isEmpty else {
            return textResult("Usage: prism search <question> [--pubmed|--all]\n")
        }

        var query = engine.decompose(question: question, brain: runtime.brain)
        engine.explode(&query)

        let targets: [DatabaseTarget]?
        if args.contains("--pubmed") { targets = [.pubmed] }
        else if args.contains("--scholar") { targets = [.scholar] }
        else { targets = nil }

        let results = engine.search(query, targets: targets)

        var lines: [String] = ["PRISM Search Results (\(results.count)):"]
        for r in results.prefix(15) {
            lines.append("  [\(r.source)] \(r.title)")
            if !r.content.isEmpty { lines.append("    \(String(r.content.prefix(120)))") }
            if let url = r.url { lines.append("    \u{001B}[2m\(url)\u{001B}[0m") }
        }

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Thesaurus

    private static func prismThesaurus(args: [String], engine: PRISMEngine, runtime: BuiltinRuntime) -> CommandResult {
        let sub = args.first ?? "stats"
        let tArgs = Array(args.dropFirst())

        switch sub {
        case "stats":
            let stats = engine.thesaurus.stats()
            var lines: [String] = ["Thesaurus:"]
            lines.append("  Concepts: \(stats.concepts)")
            lines.append("  Aliases: \(stats.aliases)")
            lines.append("  Domains:")
            for (domain, count) in stats.domains.sorted(by: { $0.value > $1.value }) {
                lines.append("    \(domain): \(count)")
            }
            return textResult(lines.joined(separator: "\n") + "\n")

        case "lookup":
            guard !tArgs.isEmpty else { return textResult("Usage: prism thesaurus lookup <term>\n") }
            return prismExplode(args: tArgs, engine: engine)

        case "add":
            guard tArgs.count >= 2 else {
                return textResult("Usage: prism thesaurus add <preferred-term> <synonym1> [synonym2...]\n")
            }
            let preferred = tArgs[0]
            let synonyms = Array(tArgs.dropFirst())
            let node = ConceptNode(
                id: String(format: "U%04x", Int.random(in: 0...0xFFFF)),
                preferred: preferred, synonyms: synonyms, narrower: [], broader: [],
                related: [], abbreviations: [], spellingVariants: [],
                truncations: [], domain: "user", meshId: nil, source: "user"
            )
            engine.thesaurus.addConcept(node)
            return textResult("Added '\(preferred)' with \(synonyms.count) synonyms.\n")

        case "mesh":
            guard !tArgs.isEmpty else { return textResult("Usage: prism thesaurus mesh <term>\n") }
            let term = tArgs.joined(separator: " ")
            if let node = engine.thesaurus.fetchMeSH(term) {
                return textResult("Imported from MeSH: \(node.preferred) (\(node.synonyms.count) synonyms)\n")
            }
            return textResult("Not found in MeSH API.\n")

        default:
            return textResult("Usage: prism thesaurus [stats|lookup|add|mesh]\n")
        }
    }

    // MARK: - Help

    private static func prismHelp() -> CommandResult {
        textResult("""
        PRISM — Programmable Research & Information Synthesis Matrix

        Multidimensional search framework with 8 universal facets:
          P  Population / Phenomenon     (who/what is studied)
          R  Realm / Domain              (field of knowledge)
          I  Intervention / Input        (what is tested)
          S  Standard / Comparator       (compared to what)
          M  Measure / Outcome           (what is measured)
          T  Time                        (temporal scope)
          G  Geography / Setting         (where)
          D  Design / Methodology        (how)

        Commands:
          prism <question>                Decompose + explode + show strategy
          prism explode <term>            Show synonym tree from thesaurus
          prism strategy <q> [--all]      Show Boolean for all databases
          prism search <q> [--pubmed]     Execute across databases

        Thesaurus:
          prism thesaurus stats           Vocabulary size + domains
          prism thesaurus lookup <term>   Find concept node
          prism thesaurus add <t> <syns>  Add custom synonyms
          prism thesaurus mesh <term>     Import from NLM MeSH API

        Databases: PubMed, Scholar, arXiv, bioRxiv, ClinicalTrials.gov,
                   GitHub, DuckDuckGo, Cochrane, Embase, Web of Science

        """)
    }

    // MARK: - Helpers

    private static func prismDirectory(runtime: BuiltinRuntime) -> URL {
        let home: String
        if let override = runtime.context.environment["DODEXABASH_HOME"], !override.isEmpty {
            home = override
        } else {
            home = runtime.context.currentDirectory + "/.dodexabash"
        }
        return URL(fileURLWithPath: home).appendingPathComponent("prism", isDirectory: true)
    }
}
