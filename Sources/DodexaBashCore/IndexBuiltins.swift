import Foundation

// MARK: - Index Builtins: Codebase indexing commands

extension Builtins {
    static func indexBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let sub = args.first ?? "run"
        let subArgs = Array(args.dropFirst())
        let indexer = runtime.codebaseIndexer
        let cwd = runtime.context.currentDirectory

        switch sub {
        case "run", "build":
            let incremental = !subArgs.contains("--full")
            let snapshot = indexer.index(at: cwd, incremental: incremental)
            let mode = incremental ? "incremental" : "full"
            return textResult(
                "Indexed (\(mode)): \(snapshot.totalFiles) files, \(snapshot.totalSymbols) symbols, \(snapshot.totalLines) lines\n"
            )

        case "status":
            let snap = indexer.current
            if snap.files.isEmpty {
                return textResult("No index. Run 'index run' to build.\n")
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            var lines: [String] = [
                "Codebase Index:",
                "  Files: \(snap.totalFiles)",
                "  Symbols: \(snap.totalSymbols)",
                "  Lines: \(snap.totalLines)",
                "  Indexed at: \(formatter.string(from: snap.indexedAt))"
            ]

            // Language breakdown
            var langCounts: [String: Int] = [:]
            for file in snap.files {
                langCounts[file.language, default: 0] += 1
            }
            let topLangs = langCounts.sorted { $0.value > $1.value }.prefix(8)
            lines.append("  Languages: " + topLangs.map { "\($0.key)(\($0.value))" }.joined(separator: ", "))

            // Symbol breakdown
            var kindCounts: [String: Int] = [:]
            for file in snap.files {
                for symbol in file.symbols {
                    kindCounts[symbol.kind.rawValue, default: 0] += 1
                }
            }
            let topKinds = kindCounts.sorted { $0.value > $1.value }
            lines.append("  Symbols: " + topKinds.map { "\($0.key)(\($0.value))" }.joined(separator: ", "))

            return textResult(lines.joined(separator: "\n") + "\n")

        case "search", "find":
            let query = subArgs.filter { !$0.hasPrefix("-") }.joined(separator: " ")
            guard !query.isEmpty else {
                return textResult("Usage: index search <query>\n")
            }

            // Auto-index if needed
            if indexer.current.files.isEmpty {
                _ = indexer.index(at: cwd, incremental: true)
            }

            let limit = subArgs.compactMap { arg -> Int? in
                if arg.hasPrefix("-n") { return Int(arg.dropFirst(2)) }
                return nil
            }.first ?? 20

            let results = indexer.searchSymbols(query: query, limit: limit)
            if results.isEmpty {
                return textResult("No symbols matching '\(query)'.\n")
            }

            var lines: [String] = ["Found \(results.count) symbols:"]
            for symbol in results {
                let kind = symbol.kind.rawValue
                let loc = "\(symbol.file):\(symbol.line)"
                let sig = symbol.signature ?? symbol.name
                let scope = symbol.scope.map { " (\($0))" } ?? ""
                lines.append("  \u{001B}[33m\(kind)\u{001B}[0m \u{001B}[1m\(sig)\u{001B}[0m\(scope)")
                lines.append("    \u{001B}[2m\(loc)\u{001B}[0m")
            }
            return textResult(lines.joined(separator: "\n") + "\n")

        case "files":
            let snap = indexer.current
            if snap.files.isEmpty {
                return textResult("No index. Run 'index run' to build.\n")
            }
            let language = subArgs.first
            let files: [IndexedFile]
            if let lang = language {
                files = indexer.filesByLanguage(lang)
            } else {
                files = Array(snap.files.prefix(30))
            }
            if files.isEmpty {
                return textResult("No files\(language.map { " for language '\($0)'" } ?? "").\n")
            }
            var lines: [String] = []
            for file in files {
                lines.append("  \(file.path) [\(file.language), \(file.lines) lines, \(file.symbols.count) symbols]")
            }
            return textResult(lines.joined(separator: "\n") + "\n")

        case "imports":
            let module = subArgs.first ?? ""
            guard !module.isEmpty else {
                return textResult("Usage: index imports <module>\n")
            }
            if indexer.current.files.isEmpty {
                _ = indexer.index(at: cwd, incremental: true)
            }
            let files = indexer.filesImporting(module)
            if files.isEmpty {
                return textResult("No files import '\(module)'.\n")
            }
            var lines = ["Files importing '\(module)':"]
            for file in files { lines.append("  \(file)") }
            return textResult(lines.joined(separator: "\n") + "\n")

        case "context":
            // Show what the brain sees
            if indexer.current.files.isEmpty {
                _ = indexer.index(at: cwd, incremental: true)
            }
            let context = indexer.contextForBrain(limit: 3000)
            return textResult("Brain context from index:\n\(context)\n")

        default:
            return textResult("Usage: index [run|status|search|files|imports|context] [--full]\n")
        }
    }
}
