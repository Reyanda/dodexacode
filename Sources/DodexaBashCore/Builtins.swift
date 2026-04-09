import Foundation

public struct ShellIO {
    public var stdin: Data?
    public var stdout: Data
    public var stderr: Data

    public init(stdin: Data? = nil, stdout: Data = Data(), stderr: Data = Data()) {
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct CommandResult {
    public let status: Int32
    public let io: ShellIO

    public init(status: Int32, io: ShellIO) {
        self.status = status
        self.io = io
    }
}

struct BuiltinRuntime {
    let context: ShellContext
    let sessionStore: SessionStore
    let workspaceBriefer: WorkspaceBriefer
    let workflowLibrary: WorkflowLibrary
    let runtimeStore: FutureRuntimeStore
    let brain: LocalBrain
    let researchEngine: ResearchEngine
    let designEngine: DesignEngine
    let skillStore: SkillStore
    let mcpClient: McpClient
    let blockStore: BlockStore
    let jobTable: JobTable
    let codebaseIndexer: CodebaseIndexer
    let pipelineExecutor: PipelineExecutor
    let themeStore: ThemeStore
}

private struct MarkdownIngestResult: Encodable {
    let document: MarkdownDocument
    let artifact: ArtifactEnvelope
}

private enum MarkdownLoadResult {
    case success(MarkdownDocument)
    case failure(CommandResult)
}

struct DoctorCheck: Encodable {
    let name: String
    let ok: Bool
    let detail: String
}

struct DoctorReport: Encodable {
    let product: String
    let version: String
    let cwd: String
    let stateRoot: String
    let securityMode: String
    let securitySummary: String
    let workflows: Int
    let localSkills: Int
    let traces: Int
    let blocks: Int
    let artifacts: Int
    let proofs: Int
    let repairs: Int
    let mcpConfiguredServers: Int
    let mcpConnectedServers: Int
    let mcpDiscoveredTools: Int
    let checks: [DoctorCheck]
    let recommendations: [String]
}

struct CapabilityCategory: Encodable {
    let name: String
    let commands: [String]
}

struct SecurityModeDescriptor: Encodable {
    let name: String
    let summary: String
}

struct ReviewerWalkthrough: Encodable {
    let name: String
    let goal: String
    let commands: [String]
    let expectedSignals: [String]
}

struct CapabilityCatalog: Encodable {
    let product: String
    let version: String
    let publicRepository: String
    let compatibilityName: String
    let builtinCount: Int
    let commandCategories: [CapabilityCategory]
    let futureShellPrimitives: [String]
    let workflowCards: [String]
    let securityModes: [SecurityModeDescriptor]
    let mcpServerTransport: String
    let mcpBuiltInToolCount: Int
    let externalMcpConfiguredServers: Int
    let externalMcpConnectedServers: Int
    let externalMcpDiscoveredTools: Int
    let reviewerWalkthroughs: [ReviewerWalkthrough]
}

enum Builtins {
    static func run(
        command: String,
        args: [String],
        runtime: BuiltinRuntime,
        input: Data?
    ) -> CommandResult? {
        switch command {
        case "cd":
            return cd(args: args, context: runtime.context)
        case "pwd":
            return textResult(FileManager.default.currentDirectoryPath + "\n")
        case "echo":
            return echo(args: args)
        case "env":
            return env(context: runtime.context)
        case "set":
            return env(context: runtime.context)
        case "export":
            return export(args: args, context: runtime.context)
        case "unset":
            return unset(args: args, context: runtime.context)
        case "brief":
            return brief(args: args, runtime: runtime)
        case "history":
            return history(args: args, runtime: runtime)
        case "predict":
            return predict(args: args, runtime: runtime)
        case "workflow":
            return workflow(args: args, runtime: runtime)
        case "md":
            return markdown(args: args, runtime: runtime)
        case "calc":
            return calc(args: args)
        case "grep", "rg":
            return grepBuiltin(args: args, runtime: runtime)
        case "glob":
            return globBuiltin(args: args, runtime: runtime)
        case "fetch":
            return fetchBuiltin(args: args, runtime: runtime)
        case "edit":
            return editBuiltin(args: args, runtime: runtime)
        case "theme":
            return themeBuiltin(args: args, runtime: runtime)
        case "tip", "tips":
            return textResult("\u{1F4A1} " + Tips.random() + "\n")
        case "skill":
            return skillBuiltin(args: args, runtime: runtime)
        case "alias":
            return aliasBuiltin(args: args, context: runtime.context)
        case "unalias":
            return unaliasBuiltin(args: args, context: runtime.context)
        case "function":
            return functionBuiltin(args: args, context: runtime.context)
        case "source", ".":
            return sourceBuiltin(args: args, runtime: runtime)
        case "help":
            return help()
        case "doctor":
            return doctorBuiltin(args: args, runtime: runtime)
        case "catalog":
            return catalogBuiltin(args: args, runtime: runtime)
        case "exit":
            return exitBuiltin(args: args, context: runtime.context)
        case "artifact":
            return artifact(args: args, runtime: runtime)
        case "intent":
            return intent(args: args, runtime: runtime)
        case "lease":
            return lease(args: args, runtime: runtime)
        case "simulate":
            return simulateBuiltin(args: args, runtime: runtime)
        case "prove":
            return prove(args: args, runtime: runtime)
        case "entity":
            return entity(args: args, runtime: runtime)
        case "attention":
            return attention(args: args, runtime: runtime)
        case "policy":
            return policy(args: args, runtime: runtime)
        case "world":
            return world(args: args, runtime: runtime)
        case "uncertainty":
            return uncertainty(args: args, runtime: runtime)
        case "repair":
            return repair(args: args, runtime: runtime)
        case "delegate":
            return delegateBuiltin(args: args, runtime: runtime)
        case "replay":
            return replay(args: args, runtime: runtime)
        case "diff":
            return diffBuiltin(args: args, runtime: runtime)
        case "clear", "cls":
            return clearScreen(runtime: runtime)
        case "open", "cat", "show":
            return openFile(args: args, runtime: runtime)
        case "create", "new":
            // Only handle if first arg looks like a filename (has extension)
            if let first = args.first(where: { !$0.hasPrefix("-") }),
               first.contains("."), !(first as NSString).pathExtension.isEmpty {
                return createFile(args: args, runtime: runtime)
            }
            return nil  // Fall through to brain for NL like "create a web page"
        case "tree":
            return tree(args: args, runtime: runtime)
        // Single-word aliases for natural feel
        case "brain":
            return brainBuiltin(args: args, runtime: runtime)
        case "ask":
            return askBuiltin(args: args, runtime: runtime)
        case "hi", "hey", "hello", "sup", "yo":
            return greet(runtime: runtime)
        case "who":
            // "who" alone or "who are you" / "who is this" = greet
            if args.isEmpty { return greet(runtime: runtime) }
            let phrase = args.joined(separator: " ").lowercased()
            if phrase.contains("are you") || phrase.contains("is this") || phrase.contains("is dodexabash") {
                return greet(runtime: runtime)
            }
            return nil
        case "next":
            return predict(args: args, runtime: runtime)
        case "cards":
            return workflow(args: ["list"] + args, runtime: runtime)
        case "status":
            return statusOverview(args: args, runtime: runtime)
        case "proofs":
            return prove(args: ["list"] + args, runtime: runtime)
        case "repairs":
            return repair(args: ["list"] + args, runtime: runtime)
        case "leases":
            return lease(args: ["list"] + args, runtime: runtime)
        case "entities":
            return entity(args: ["list"] + args, runtime: runtime)
        case "graph":
            return world(args: ["show"] + args, runtime: runtime)
        case "artifacts":
            return artifact(args: ["list"] + args, runtime: runtime)
        case "mcp":
            return mcpBuiltin(args: args, runtime: runtime)
        case "blocks":
            return blocksBuiltin(args: args, runtime: runtime)
        case "tools":
            return mcpBuiltin(args: ["tools"] + args, runtime: runtime)
        case "jobs":
            return jobsBuiltin(args: args, runtime: runtime)
        case "fg":
            return fgBuiltin(args: args, runtime: runtime)
        case "bg":
            return bgBuiltin(args: args, runtime: runtime)
        case "git":
            return gitBuiltin(args: args, runtime: runtime)
        case "index":
            return indexBuiltin(args: args, runtime: runtime)
        case "sec", "security":
            return secBuiltin(args: args, runtime: runtime)
        case "epi", "epidemiology":
            return epiBuiltin(args: args, runtime: runtime)
        case "lead", "orchestrate":
            let intent = args.joined(separator: " ")
            if intent.isEmpty { return textError("lead <intent>\n", status: 1) }
            let orchestrator = MultiAgentOrchestrator(brain: runtime.brain, context: runtime.context, researchEngine: runtime.researchEngine, designEngine: runtime.designEngine)
            let result = orchestrator.delegate(intent: intent, cwd: runtime.context.currentDirectory, runtime: runtime)
            return textResult(result + "\n")

        case "design":
            return designBuiltin(args: args, runtime: runtime)
        case "analyze":
            return analyzeBuiltin(args: args, runtime: runtime)
        case "roche":
            return rocheBuiltin(args: args, runtime: runtime)
        case "palace", "memory", "mem":
            return palaceBuiltin(args: args, runtime: runtime)
        case "pipeline", "pipe":
            return pipelineBuiltin(args: args, runtime: runtime)
        case "browse", "web", "http":
            return browseBuiltin(args: args, runtime: runtime)
        case "prism":
            return prismBuiltin(args: args, runtime: runtime)
        case "search":
            return searchBuiltin(args: args, runtime: runtime)
        default:
            return nil
        }
    }

    static func isStateful(_ command: String) -> Bool {
        ["cd", "export", "unset", "exit", "alias", "unalias", "function", "source", ".", "fg", "bg"].contains(command)
    }

    /// Returns true if the command name is a recognized builtin (for pipeline streaming decisions)
    static func isKnown(_ command: String) -> Bool {
        knownBuiltins.contains(command)
    }

    private static let knownBuiltins: Set<String> = [
        "cd", "pwd", "echo", "env", "set", "export", "unset",
        "brief", "history", "predict", "workflow", "md", "skill",
        "alias", "unalias", "function", "source", ".", "help", "doctor", "catalog", "exit",
        "artifact", "intent", "lease", "simulate", "prove",
        "entity", "attention", "policy", "world", "uncertainty",
        "repair", "delegate", "replay", "diff", "clear", "cls",
        "open", "cat", "show", "create", "new", "tree",
        "brain", "ask", "hi", "hey", "hello", "sup", "yo", "who",
        "next", "cards", "status", "proofs", "repairs", "leases", "entities",
        "mcp", "blocks", "tools", "jobs", "fg", "bg", "git", "index", "sec", "security", "roche",
        "palace", "memory", "mem", "pipeline", "pipe", "browse", "web", "http", "prism", "search"
    ]

    private static func cd(args: [String], context: ShellContext) -> CommandResult {
        let destination: String
        if args.isEmpty {
            destination = context.environment["HOME"] ?? context.currentDirectory
        } else if args[0] == "-" {
            destination = context.environment["OLDPWD"] ?? context.currentDirectory
        } else {
            destination = args[0]
        }

        let old = context.currentDirectory
        do {
            try FileManager.default.changeCurrentDirectoryPathCompat(destination)
            context.environment["OLDPWD"] = old
            context.environment["PWD"] = context.currentDirectory
            if args.first == "-" {
                return textResult(context.currentDirectory + "\n")
            }
            return CommandResult(status: 0, io: ShellIO())
        } catch {
            return textError("cd: \(error.localizedDescription)\n", status: 1)
        }
    }

    private static func echo(args: [String]) -> CommandResult {
        var index = 0
        var trailingNewline = true

        if args.first == "-n" {
            trailingNewline = false
            index = 1
        }

        let body = args.dropFirst(index).joined(separator: " ")
        return textResult(body + (trailingNewline ? "\n" : ""))
    }

    private static func env(context: ShellContext) -> CommandResult {
        let body = context.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        return textResult(body.isEmpty ? "" : body + "\n")
    }

    private static func export(args: [String], context: ShellContext) -> CommandResult {
        guard !args.isEmpty else {
            return env(context: context)
        }

        for item in args {
            if let split = item.firstIndex(of: "=") {
                let name = String(item[..<split])
                let value = String(item[item.index(after: split)...])
                guard isValidIdentifier(name) else {
                    return textError("export: invalid identifier '\(item)'\n", status: 1)
                }
                context.environment[name] = value
            } else {
                guard isValidIdentifier(item) else {
                    return textError("export: invalid identifier '\(item)'\n", status: 1)
                }
                context.environment[item] = context.environment[item] ?? ""
            }
        }

        return CommandResult(status: 0, io: ShellIO())
    }

    private static func unset(args: [String], context: ShellContext) -> CommandResult {
        for name in args {
            context.environment.removeValue(forKey: name)
        }
        return CommandResult(status: 0, io: ShellIO())
    }

    private static func brief(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jsonMode = args.contains("--json")
        let filteredArgs = args.filter { $0 != "--json" }
        let targetPath = filteredArgs.first ?? runtime.context.currentDirectory
        let brief = runtime.workspaceBriefer.generate(atPath: targetPath)

        if jsonMode {
            return jsonResult(brief)
        }

        return textResult(brief.compactText + "\n")
    }

    private static func history(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jsonMode = args.contains("--json")
        let filteredArgs = args.filter { $0 != "--json" }
        let limit = Int(filteredArgs.first ?? "") ?? 15
        let traces = runtime.sessionStore.recent(limit: max(1, limit))

        if jsonMode {
            return jsonResult(traces)
        }

        guard !traces.isEmpty else {
            return textResult("No command history yet.\n")
        }

        let formatter = ISO8601DateFormatter()
        let body = traces.enumerated().map { offset, trace in
            let timestamp = formatter.string(from: trace.timestamp)
            return "[\(offset + 1)] \(timestamp) status=\(trace.status) duration=\(trace.durationMs)ms cwd=\(trace.cwd)\n  \(trace.source)"
        }.joined(separator: "\n")
        return textResult(body + "\n")
    }

    private static func predict(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jsonMode = args.contains("--json")
        let filteredArgs = args.filter { $0 != "--json" }
        let seed = filteredArgs.isEmpty ? nil : filteredArgs.joined(separator: " ")
        let predictions = runtime.sessionStore.predictions(seedCommand: seed, limit: 4)

        if jsonMode {
            return jsonResult(predictions)
        }

        guard !predictions.isEmpty else {
            return textResult("No predictions yet. Build some local history first.\n")
        }

        let body = predictions.enumerated().map { offset, prediction in
            let confidence = String(format: "%.2f", prediction.confidence)
            return "[\(offset + 1)] \(prediction.command)\n  confidence=\(confidence) reason=\(prediction.rationale)"
        }.joined(separator: "\n")
        return textResult(body + "\n")
    }

    private static func workflow(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jsonMode = args.contains("--json")
        let filteredArgs = args.filter { $0 != "--json" }

        if filteredArgs.isEmpty || filteredArgs[0] == "list" {
            let cards = runtime.workflowLibrary.listCards()
            if jsonMode {
                return jsonResult(cards)
            }
            let body = cards.map { "[\($0.slug)] \($0.name)\n  \($0.summary)" }.joined(separator: "\n")
            return textResult(body + "\n")
        }

        if filteredArgs[0] == "show", filteredArgs.count >= 2 {
            guard let card = runtime.workflowLibrary.card(slug: filteredArgs[1]) else {
                return textError("workflow: unknown card '\(filteredArgs[1])'\n", status: 1)
            }
            if jsonMode {
                return jsonResult(card)
            }
            let body = """
            [\(card.slug)] \(card.name)
            Domain: \(card.domain)
            Summary: \(card.summary)
            When: \(card.whenToUse)
            Inputs: \(card.keyInputs.joined(separator: ", "))
            Workflow:
            \(card.workflow.map { "  - \($0)" }.joined(separator: "\n"))
            Outputs: \(card.outputs.joined(separator: ", "))
            Red flags:
            \(card.redFlags.map { "  - \($0)" }.joined(separator: "\n"))

            """
            return textResult(body)
        }

        if filteredArgs[0] == "match", filteredArgs.count >= 2 {
            let query = filteredArgs.dropFirst().joined(separator: " ")
            let matches = runtime.workflowLibrary.match(query: query, limit: 4)
            if jsonMode {
                return jsonResult(matches)
            }
            guard !matches.isEmpty else {
                return textResult("No workflow matches for: \(query)\n")
            }
            let body = matches.map { match in
                let score = String(format: "%.2f", match.score)
                return "[\(match.card.slug)] \(match.card.name)\n  score=\(score) why=\(match.reason)"
            }.joined(separator: "\n")
            return textResult(body + "\n")
        }

        return textError("workflow: expected list, show <slug>, or match <query>\n", status: 1)
    }

    private static func markdown(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jsonMode = args.contains("--json")
        let filtered = args.filter { $0 != "--json" }
        let sub = filtered.first ?? "show"

        switch sub {
        case "show":
            guard filtered.count >= 2 else { return textError("md: show <path>\n", status: 1) }
            switch loadMarkdownDocument(from: filtered[1], runtime: runtime) {
            case .failure(let error):
                return error
            case .success(let document):
                if jsonMode { return jsonResult(document) }
                var lines = [
                    "Markdown: \(document.path ?? filtered[1])",
                    "title: \(document.title)",
                    "sections: \(document.sections.count) bullets=\(document.bulletCount) code_blocks=\(document.codeBlockCount) words=\(document.wordCount)"
                ]
                if !document.preamble.isEmpty {
                    lines.append("preamble: \(document.preamble.prefix(120))")
                }
                lines.append("headings:")
                for section in document.sections.prefix(20) {
                    lines.append("  [h\(section.level)] \(section.path.joined(separator: " / "))")
                }
                if document.sections.count > 20 {
                    lines.append("  ... and \(document.sections.count - 20) more sections")
                }
                return textResult(lines.joined(separator: "\n") + "\n")
            }

        case "headings":
            guard filtered.count >= 2 else { return textError("md: headings <path>\n", status: 1) }
            switch loadMarkdownDocument(from: filtered[1], runtime: runtime) {
            case .failure(let error):
                return error
            case .success(let document):
                if jsonMode { return jsonResult(document.sections) }
                let body = document.sections.map { section in
                    "[h\(section.level)] \(section.path.joined(separator: " / ")) line=\(section.lineStart)"
                }.joined(separator: "\n")
                return textResult(body.isEmpty ? "" : body + "\n")
            }

        case "section":
            guard filtered.count >= 3 else { return textError("md: section <path> <heading>\n", status: 1) }
            switch loadMarkdownDocument(from: filtered[1], runtime: runtime) {
            case .failure(let error):
                return error
            case .success(let document):
                let query = filtered.dropFirst(2).joined(separator: " ")
                guard let section = MarkdownNative.findSection(in: document, matching: query) else {
                    return textError("md: section not found '\(query)'\n", status: 1)
                }
                if jsonMode { return jsonResult(section) }
                let body = section.body.isEmpty ? "(empty section body)" : section.body
                return textResult("""
                [h\(section.level)] \(section.path.joined(separator: " / "))
                lines: \(section.lineStart)-\(section.lineEnd)
                bullets: \(section.bullets.count)  code_blocks: \(section.codeBlocks.count)

                \(body)

                """)
            }

        case "ingest":
            guard filtered.count >= 2 else { return textError("md: ingest <path> [label]\n", status: 1) }
            let resolvedPath = MarkdownNative.resolve(path: filtered[1], cwd: runtime.context.currentDirectory)
            guard let source = try? String(contentsOfFile: resolvedPath, encoding: .utf8) else {
                return textError("md: could not read \(resolvedPath)\n", status: 1)
            }
            let document = MarkdownNative.parse(source, path: resolvedPath)
            let label = filtered.count >= 3 ? filtered[2] : URL(fileURLWithPath: resolvedPath).lastPathComponent
            let artifact = runtime.runtimeStore.createArtifact(
                kind: .markdown,
                label: label,
                content: source,
                sourceFile: resolvedPath,
                tags: ["markdown", "document"] + document.sections.prefix(4).map(\.slug)
            )
            if jsonMode {
                return jsonResult(MarkdownIngestResult(document: document, artifact: artifact))
            }
            return textResult("Ingested markdown [\(artifact.id)] \(label) sections=\(document.sections.count)\n")

        default:
            // If the first arg looks like a file path, default to "show"
            if sub.contains(".") || sub.contains("/") {
                let showArgs = ["show"] + filtered
                return markdown(args: (jsonMode ? showArgs + ["--json"] : showArgs), runtime: runtime)
            }
            return textError("md: expected show <path>, headings <path>, section <path> <heading>, or ingest <path> [label]\n", status: 1)
        }
    }

    // MARK: - Future Runtime Builtins

    private static func artifact(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jsonMode = args.contains("--json")
        let filtered = args.filter { $0 != "--json" }
        let store = runtime.runtimeStore
        let sub = filtered.first ?? "list"

        switch sub {
        case "list":
            let items = store.artifacts
            if jsonMode { return jsonResult(items) }
            guard !items.isEmpty else { return textResult("No artifacts.\n") }
            let body = items.suffix(20).map { a in
                "[\(a.id)] \(a.kind.rawValue) \(a.label) hash=\(a.contentHash.prefix(12))"
            }.joined(separator: "\n")
            return textResult(body + "\n")

        case "show":
            guard filtered.count >= 2 else { return textError("artifact: show requires <id>\n", status: 1) }
            guard let a = store.artifact(id: filtered[1]) else {
                return textError("artifact: not found '\(filtered[1])'\n", status: 1)
            }
            if jsonMode { return jsonResult(a) }
            return textResult("""
            [\(a.id)] \(a.kind.rawValue) \(a.label)
            hash: \(a.contentHash)
            provenance: \(a.provenance.method) via \(a.provenance.sourceCommand ?? "manual")
            tags: \(a.tags.joined(separator: ", "))
            content:
            \(a.content.prefix(500))

            """)

        case "create":
            guard filtered.count >= 4 else {
                return textError("artifact: create <label> <kind> <content...>\n", status: 1)
            }
            let label = filtered[1]
            let kindStr = filtered[2]
            let content = filtered.dropFirst(3).joined(separator: " ")
            let kind = ArtifactKind(rawValue: kindStr) ?? .text
            let a = store.createArtifact(kind: kind, label: label, content: content)
            if jsonMode { return jsonResult(a) }
            return textResult("Created artifact [\(a.id)] \(a.kind.rawValue) \(a.label)\n")

        default:
            return textError("artifact: expected list, show <id>, or create <label> <kind> <content>\n", status: 1)
        }
    }

    private static func intent(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jsonMode = args.contains("--json")
        let filtered = args.filter { $0 != "--json" }
        let store = runtime.runtimeStore
        let sub = filtered.first ?? "show"

        switch sub {
        case "set":
            guard filtered.count >= 2 else { return textError("intent: set <statement>\n", status: 1) }
            let statement = filtered.dropFirst().joined(separator: " ")
            let i = store.setIntent(statement: statement)
            if jsonMode { return jsonResult(i) }
            return textResult("Intent active [\(i.id)]: \(i.statement)\n")

        case "show":
            guard let i = store.activeIntent else {
                if jsonMode { return jsonResult(["active": false] as [String: Bool]) }
                return textResult("No active intent.\n")
            }
            if jsonMode { return jsonResult(i) }
            return textResult("[\(i.id)] \(i.status.rawValue): \(i.statement)\n  risk=\(i.riskLevel.rawValue) mutations=\(i.mutations.joined(separator: ","))\n")

        case "clear":
            store.clearIntent()
            return textResult("Intent cleared.\n")

        case "satisfy":
            store.satisfyIntent()
            return textResult("Intent marked satisfied.\n")

        case "fail":
            store.failIntent()
            return textResult("Intent marked failed.\n")

        default:
            return textError("intent: expected set <text>, show, clear, satisfy, or fail\n", status: 1)
        }
    }

    private static func lease(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jsonMode = args.contains("--json")
        let filtered = args.filter { $0 != "--json" }
        let store = runtime.runtimeStore
        let sub = filtered.first ?? "list"

        switch sub {
        case "grant":
            guard filtered.count >= 3 else {
                return textError("lease: grant <capability> <resource> [ttl_seconds]\n", status: 1)
            }
            let ttl = filtered.count >= 4 ? (Int(filtered[3]) ?? 300) : 300
            let l = store.grantLease(capability: filtered[1], resource: filtered[2], ttlSeconds: ttl)
            if jsonMode { return jsonResult(l) }
            return textResult("Granted lease [\(l.id)] \(l.capability) on \(l.resource) ttl=\(ttl)s\n")

        case "list":
            let active = store.activeLeases()
            if jsonMode { return jsonResult(active) }
            guard !active.isEmpty else { return textResult("No active leases.\n") }
            let fmt = ISO8601DateFormatter()
            let body = active.map { l in
                "[\(l.id)] \(l.capability) on \(l.resource) grantee=\(l.grantee) expires=\(fmt.string(from: l.expiresAt))"
            }.joined(separator: "\n")
            return textResult(body + "\n")

        case "revoke":
            guard filtered.count >= 2 else { return textError("lease: revoke <id>\n", status: 1) }
            if store.revokeLease(id: filtered[1]) {
                return textResult("Revoked lease \(filtered[1]).\n")
            }
            return textError("lease: not found '\(filtered[1])'\n", status: 1)

        case "check":
            guard filtered.count >= 3 else { return textError("lease: check <capability> <resource>\n", status: 1) }
            if let l = store.checkLease(capability: filtered[1], resource: filtered[2]) {
                if jsonMode { return jsonResult(l) }
                return textResult("Active lease [\(l.id)] \(l.capability) on \(l.resource)\n")
            }
            return textResult("No active lease for \(filtered[1]) on \(filtered[2]).\n")

        case "gc":
            let count = store.revokeExpiredLeases()
            return textResult("Revoked \(count) expired lease(s).\n")

        default:
            return textError("lease: expected grant, list, revoke <id>, check <cap> <resource>, or gc\n", status: 1)
        }
    }

    private static func simulateBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jsonMode = args.contains("--json")
        let filtered = args.filter { $0 != "--json" }
        guard !filtered.isEmpty else {
            return textError("simulate: requires a command to analyze\n", status: 1)
        }

        let command = filtered.joined(separator: " ")
        let report = runtime.runtimeStore.simulate(command: command)

        if jsonMode { return jsonResult(report) }

        var lines: [String] = []
        lines.append("Simulation: \(report.command)")
        lines.append("  predicted status: \(report.predictedStatus)")
        lines.append("  risk: \(report.riskAssessment.rawValue)")
        lines.append("  confidence: \(String(format: "%.2f", report.confidence))")
        if !report.predictedStdout.isEmpty {
            lines.append("  predicted stdout: \(report.predictedStdout)")
        }
        for effect in report.predictedEffects {
            lines.append("  effect: [\(effect.kind)] \(effect.target) — \(effect.description) (reversible=\(effect.reversible))")
        }
        if let rollback = report.rollbackPath {
            lines.append("  rollback: \(rollback)")
        }
        if !report.alternatives.isEmpty {
            lines.append("  alternatives: \(report.alternatives.joined(separator: "; "))")
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    private static func prove(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jsonMode = args.contains("--json")
        let filtered = args.filter { $0 != "--json" }
        let store = runtime.runtimeStore
        let sub = filtered.first ?? "last"

        switch sub {
        case "last":
            guard let p = store.lastProof() else {
                return textResult("No proofs recorded yet.\n")
            }
            if jsonMode { return jsonResult(p) }
            var lines = ["Proof [\(p.id)]", "  claim: \(p.claim)", "  confidence: \(String(format: "%.2f", p.confidence))"]
            for e in p.evidence {
                lines.append("  [\(e.kind)] \(e.source): \(e.value.prefix(80))")
            }
            if let token = p.replayToken {
                lines.append("  replay: \(token.prefix(40))...")
            }
            return textResult(lines.joined(separator: "\n") + "\n")

        case "list":
            let limit = filtered.count >= 2 ? (Int(filtered[1]) ?? 10) : 10
            let items = Array(store.proofs.suffix(limit))
            if jsonMode { return jsonResult(items) }
            guard !items.isEmpty else { return textResult("No proofs.\n") }
            let body = items.map { p in
                "[\(p.id)] \(p.claim.prefix(60)) confidence=\(String(format: "%.2f", p.confidence))"
            }.joined(separator: "\n")
            return textResult(body + "\n")

        default:
            return textError("prove: expected last or list [limit]\n", status: 1)
        }
    }

    private static func entity(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jsonMode = args.contains("--json")
        let filtered = args.filter { $0 != "--json" }
        let store = runtime.runtimeStore
        let sub = filtered.first ?? "list"

        switch sub {
        case "list":
            let items = store.entities
            if jsonMode { return jsonResult(items) }
            guard !items.isEmpty else { return textResult("No entities.\n") }
            let body = items.suffix(20).map { e in
                "[\(e.id)] \(e.kind) \(e.label) views=\(e.views.count)"
            }.joined(separator: "\n")
            return textResult(body + "\n")

        case "show":
            guard filtered.count >= 2 else { return textError("entity: show <id|label>\n", status: 1) }
            let query = filtered[1]
            let e = store.entity(id: query) ?? store.resolveEntity(label: query)
            guard let e else { return textError("entity: not found '\(query)'\n", status: 1) }
            if jsonMode { return jsonResult(e) }
            var lines = ["[\(e.id)] \(e.kind) \(e.label)"]
            for v in e.views {
                lines.append("  [\(v.modality)] \(v.value.prefix(80))")
            }
            return textResult(lines.joined(separator: "\n") + "\n")

        case "create":
            guard filtered.count >= 3 else { return textError("entity: create <label> <kind>\n", status: 1) }
            let views: [EntityView] = filtered.count >= 4
                ? [EntityView(modality: "text", value: filtered.dropFirst(3).joined(separator: " "))]
                : []
            let e = store.createEntity(label: filtered[1], kind: filtered[2], views: views)
            if jsonMode { return jsonResult(e) }
            return textResult("Created entity [\(e.id)] \(e.kind) \(e.label)\n")

        default:
            return textError("entity: expected list, show <id>, or create <label> <kind>\n", status: 1)
        }
    }

    private static func attention(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jsonMode = args.contains("--json")
        let filtered = args.filter { $0 != "--json" }
        let store = runtime.runtimeStore
        let sub = filtered.first ?? "list"

        switch sub {
        case "list":
            let items = store.pendingAttention()
            if jsonMode { return jsonResult(items) }
            guard !items.isEmpty else { return textResult("No pending attention events.\n") }
            let body = items.map { a in
                "[\(a.id)] \(a.priority.rawValue) \(a.source): \(a.summary)"
            }.joined(separator: "\n")
            return textResult(body + "\n")

        case "ack":
            guard filtered.count >= 2 else { return textError("attention: ack <id>\n", status: 1) }
            if store.acknowledgeAttention(id: filtered[1]) {
                return textResult("Acknowledged \(filtered[1]).\n")
            }
            return textError("attention: not found '\(filtered[1])'\n", status: 1)

        case "push":
            guard filtered.count >= 3 else { return textError("attention: push <priority> <summary>\n", status: 1) }
            let priority = AttentionPriority(rawValue: filtered[1]) ?? .normal
            let summary = filtered.dropFirst(2).joined(separator: " ")
            let a = store.pushAttention(priority: priority, source: "user", summary: summary)
            if jsonMode { return jsonResult(a) }
            return textResult("Pushed attention [\(a.id)] \(a.priority.rawValue)\n")

        case "clear":
            store.clearAttention()
            return textResult("Attention queue cleared.\n")

        default:
            return textError("attention: expected list, ack <id>, push <priority> <summary>, or clear\n", status: 1)
        }
    }

    private static func policy(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jsonMode = args.contains("--json")
        let filtered = args.filter { $0 != "--json" }
        let store = runtime.runtimeStore
        let sub = filtered.first ?? "show"

        switch sub {
        case "show":
            guard let p = store.activePolicy else {
                return textResult("No active policy.\n")
            }
            if jsonMode { return jsonResult(p) }
            var lines = ["Policy [\(p.id)] active since \(ISO8601DateFormatter().string(from: p.activeSince))"]
            for r in p.rules {
                lines.append("  [\(r.enforcement)] \(r.domain): \(r.constraint)")
            }
            return textResult(lines.joined(separator: "\n") + "\n")

        case "set":
            guard filtered.count >= 3 else { return textError("policy: set <domain> <constraint> [enforcement]\n", status: 1) }
            let enforcement = filtered.count >= 4 ? filtered[3] : "soft"
            store.addPolicyRule(domain: filtered[1], constraint: filtered[2], enforcement: enforcement)
            return textResult("Policy rule added: [\(enforcement)] \(filtered[1]): \(filtered[2])\n")

        case "clear":
            store.clearPolicy()
            return textResult("Policy cleared.\n")

        case "check":
            guard filtered.count >= 2 else { return textError("policy: check <action>\n", status: 1) }
            let action = filtered.dropFirst().joined(separator: " ")
            let violations = store.checkPolicy(action: action)
            if violations.isEmpty {
                return textResult("No policy violations for: \(action)\n")
            }
            let body = violations.map { r in "  [\(r.enforcement)] \(r.domain): \(r.constraint)" }.joined(separator: "\n")
            return textResult("Policy violations:\n\(body)\n")

        default:
            return textError("policy: expected show, set <domain> <constraint>, clear, or check <action>\n", status: 1)
        }
    }

    private static func world(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jsonMode = args.contains("--json")
        let filtered = args.filter { $0 != "--json" }
        let store = runtime.runtimeStore
        let sub = filtered.first ?? "show"

        switch sub {
        case "show", "snapshot":
            let path = filtered.count >= 2 ? filtered[1] : runtime.context.currentDirectory
            let nodes = store.buildWorldSnapshot(workspace: path)
            if jsonMode { return jsonResult(nodes) }
            let dirs = nodes.filter { $0.kind == "directory" }.count
            let files = nodes.filter { $0.kind == "file" }.count
            var lines = ["World graph: \(nodes.count) nodes (\(dirs) dirs, \(files) files)"]
            for node in nodes.prefix(30) {
                let edgeStr = node.edges.isEmpty ? "" : " -> \(node.edges.map(\.targetId).joined(separator: ", "))"
                lines.append("  [\(node.kind)] \(node.label)\(edgeStr)")
            }
            if nodes.count > 30 {
                lines.append("  ... and \(nodes.count - 30) more nodes")
            }
            return textResult(lines.joined(separator: "\n") + "\n")

        default:
            return textError("world: expected show [path]\n", status: 1)
        }
    }

    private static func uncertainty(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jsonMode = args.contains("--json")
        let filtered = args.filter { $0 != "--json" }
        let store = runtime.runtimeStore
        let sub = filtered.first ?? "show"

        switch sub {
        case "show":
            let surface = store.autoAssessUncertainty()
            if jsonMode { return jsonResult(surface) }
            var lines = ["Uncertainty surface [\(surface.id)] subject=\(surface.subject)"]
            for entry in surface.entries {
                lines.append("  [\(entry.status.rawValue)] \(entry.claim) confidence=\(String(format: "%.2f", entry.confidence))")
                lines.append("    basis: \(entry.basis)")
            }
            return textResult(lines.joined(separator: "\n") + "\n")

        case "assess":
            guard filtered.count >= 2 else { return textError("uncertainty: assess <subject>\n", status: 1) }
            let subject = filtered.dropFirst().joined(separator: " ")
            let surface = store.assessUncertainty(
                subject: subject,
                entries: [UncertaintyEntry(
                    claim: "Manual assessment for: \(subject)",
                    status: .guessed,
                    confidence: 0.5,
                    basis: "user-initiated assessment",
                    lastVerified: nil
                )]
            )
            if jsonMode { return jsonResult(surface) }
            return textResult("Uncertainty assessed [\(surface.id)] for \(subject)\n")

        default:
            return textError("uncertainty: expected show or assess <subject>\n", status: 1)
        }
    }

    private static func repair(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jsonMode = args.contains("--json")
        let filtered = args.filter { $0 != "--json" }
        let store = runtime.runtimeStore
        let sub = filtered.first ?? "last"

        switch sub {
        case "last":
            guard let plan = store.lastRepairPlan() else {
                return textResult("No repair plans. Run a failing command first.\n")
            }
            if jsonMode { return jsonResult(plan) }
            var lines = ["Repair plan [\(plan.id)] for '\(plan.failedCommand)' (exit \(plan.exitStatus))"]
            if !plan.errorSummary.isEmpty {
                lines.append("  error: \(plan.errorSummary.prefix(120))")
            }
            lines.append("  root causes:")
            for cause in plan.rootCauses {
                lines.append("    - \(cause)")
            }
            lines.append("  repair options:")
            for opt in plan.repairOptions {
                let cmd = opt.command.map { " -> \($0)" } ?? ""
                lines.append("    [\(opt.risk.rawValue)] \(opt.action)\(cmd)")
            }
            if let retry = plan.safeRetryPlan {
                lines.append("  safe retry: \(retry)")
            }
            return textResult(lines.joined(separator: "\n") + "\n")

        case "list":
            let items = store.repairPlans
            if jsonMode { return jsonResult(items) }
            guard !items.isEmpty else { return textResult("No repair plans.\n") }
            let body = items.suffix(10).map { p in
                "[\(p.id)] exit=\(p.exitStatus) \(p.failedCommand.prefix(50)) causes=\(p.rootCauses.count) options=\(p.repairOptions.count)"
            }.joined(separator: "\n")
            return textResult(body + "\n")

        default:
            return textError("repair: expected last or list\n", status: 1)
        }
    }

    private static func delegateBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jsonMode = args.contains("--json")
        let filtered = args.filter { $0 != "--json" }
        let store = runtime.runtimeStore
        let sub = filtered.first ?? "list"

        switch sub {
        case "spawn":
            guard filtered.count >= 3 else { return textError("delegate: spawn <task> <delegatee>\n", status: 1) }
            let task = filtered[1]
            let delegatee = filtered[2]
            let ownership = filtered.count >= 4 ? filtered[3] : "shared"
            let ticket = store.spawnDelegation(delegatee: delegatee, task: task, ownership: ownership)
            if jsonMode { return jsonResult(ticket) }
            return textResult("Delegated [\(ticket.id)] '\(task)' to \(delegatee) ownership=\(ownership)\n")

        case "list":
            let items = store.delegations
            if jsonMode { return jsonResult(items) }
            guard !items.isEmpty else { return textResult("No delegations.\n") }
            let body = items.map { d in
                "[\(d.id)] \(d.status.rawValue) \(d.task) -> \(d.delegatee) (\(d.ownership))"
            }.joined(separator: "\n")
            return textResult(body + "\n")

        case "status":
            guard filtered.count >= 2 else { return textError("delegate: status <id>\n", status: 1) }
            guard let d = store.delegations.first(where: { $0.id == filtered[1] }) else {
                return textError("delegate: not found '\(filtered[1])'\n", status: 1)
            }
            if jsonMode { return jsonResult(d) }
            return textResult("[\(d.id)] \(d.status.rawValue) \(d.task) -> \(d.delegatee)\n  ownership=\(d.ownership) merge=\(d.mergeRule) leases=\(d.leaseIds.joined(separator: ","))\n")

        case "complete", "fail":
            guard filtered.count >= 2 else { return textError("delegate: \(sub) <id>\n", status: 1) }
            let newStatus: DelegationStatus = sub == "complete" ? .completed : .failed
            if store.updateDelegation(id: filtered[1], status: newStatus) {
                return textResult("Delegation \(filtered[1]) marked \(newStatus.rawValue).\n")
            }
            return textError("delegate: not found '\(filtered[1])'\n", status: 1)

        default:
            return textError("delegate: expected spawn <task> <delegatee>, list, status <id>, complete <id>, or fail <id>\n", status: 1)
        }
    }

    private static func replay(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jsonMode = args.contains("--json")
        let filtered = args.filter { $0 != "--json" }
        let store = runtime.runtimeStore
        let sub = filtered.first ?? "last"

        switch sub {
        case "last":
            guard let packet = store.lastCognitivePacket() else {
                return textResult("No cognitive packets. Use 'replay create' to compress current state.\n")
            }
            if jsonMode { return jsonResult(packet) }
            var lines = ["Cognitive packet [\(packet.id)] format=\(packet.format) compressed_from=\(packet.compressedFrom)"]
            lines.append("  state:")
            for (k, v) in packet.state.sorted(by: { $0.key < $1.key }) {
                lines.append("    \(k): \(v)")
            }
            if !packet.decisions.isEmpty {
                lines.append("  decisions:")
                for d in packet.decisions { lines.append("    - \(d)") }
            }
            if !packet.invariants.isEmpty {
                lines.append("  invariants:")
                for i in packet.invariants { lines.append("    - \(i)") }
            }
            return textResult(lines.joined(separator: "\n") + "\n")

        case "create":
            let format = filtered.count >= 2 ? filtered[1] : "brief"
            let packet = store.compressCognition(format: format)
            if jsonMode { return jsonResult(packet) }
            return textResult("Created cognitive packet [\(packet.id)] format=\(format) compressed_from=\(packet.compressedFrom)\n")

        case "list":
            let items = store.cognitivePackets
            if jsonMode { return jsonResult(items) }
            guard !items.isEmpty else { return textResult("No cognitive packets.\n") }
            let body = items.suffix(10).map { p in
                "[\(p.id)] \(p.format) compressed_from=\(p.compressedFrom) decisions=\(p.decisions.count)"
            }.joined(separator: "\n")
            return textResult(body + "\n")

        default:
            return textError("replay: expected last, create [format], or list\n", status: 1)
        }
    }

    private static func clearScreen(runtime: BuiltinRuntime) -> CommandResult {
        runtime.runtimeStore.clearAttention()
        let clear = "\u{001B}[2J\u{001B}[H"
        return CommandResult(status: 0, io: ShellIO(stdout: Data(clear.utf8)))
    }

    private static func createFile(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard let filename = args.first(where: { !$0.hasPrefix("-") && $0.contains(".") }) else {
            return textError("create: create <filename>\nExamples: create index.html, create app.py, create notes.md\n", status: 1)
        }

        let ext = (filename as NSString).pathExtension.lowercased()
        let path = runtime.context.currentDirectory + "/" + filename

        if FileManager.default.fileExists(atPath: path) {
            return textError("create: \(filename) already exists. Use 'open \(filename)' to view it.\n", status: 1)
        }

        let content: String
        switch ext {
        case "html", "htm":
            content = """
            <!DOCTYPE html>
            <html lang="en">
            <head>
                <meta charset="UTF-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <title>\(filename)</title>
                <style>
                    body { font-family: -apple-system, system-ui, sans-serif; max-width: 800px; margin: 2rem auto; padding: 0 1rem; }
                    h1 { color: #333; }
                </style>
            </head>
            <body>
                <h1>Hello from dodexabash</h1>
                <p>Created with dodexabash shell.</p>
            </body>
            </html>
            """
        case "md":
            content = "# \((filename as NSString).deletingPathExtension)\n\n"
        case "py":
            content = "#!/usr/bin/env python3\n\ndef main():\n    pass\n\nif __name__ == \"__main__\":\n    main()\n"
        case "swift":
            content = "import Foundation\n\n"
        case "js", "ts":
            content = "// \(filename)\n\n"
        case "sh":
            content = "#!/bin/bash\nset -euo pipefail\n\n"
        case "json":
            content = "{}\n"
        case "yaml", "yml":
            content = "# \((filename as NSString).deletingPathExtension)\n"
        case "css":
            content = "/* \(filename) */\nbody {\n  font-family: -apple-system, system-ui, sans-serif;\n}\n"
        case "txt":
            content = ""
        default:
            content = ""
        }

        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return textError("create: could not write \(filename): \(error.localizedDescription)\n", status: 1)
        }

        return textResult("Created \(filename) (\(content.count) bytes)\n")
    }

    private static func openFile(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard let path = args.first(where: { !$0.hasPrefix("-") }) else {
            return textError("open: missing file path\n", status: 1)
        }

        let fm = FileManager.default
        let resolved: String
        if fm.fileExists(atPath: path) {
            resolved = path
        } else {
            let full = runtime.context.currentDirectory + "/" + path
            guard fm.fileExists(atPath: full) else {
                return textError("open: \(path): no such file\n", status: 1)
            }
            resolved = full
        }

        // Check if it's a directory
        var isDir: ObjCBool = false
        fm.fileExists(atPath: resolved, isDirectory: &isDir)
        if isDir.boolValue {
            return textError("open: \(path) is a directory. Use 'cd \(path)' or 'tree \(path)'\n", status: 1)
        }

        // Read content
        guard let data = fm.contents(atPath: resolved),
              let content = String(data: data, encoding: .utf8) else {
            return textError("open: \(path): could not read file (binary?)\n", status: 1)
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let lineCount = lines.count
        let sizeKB = data.count / 1024

        // Header
        var output = "--- \(path) (\(lineCount) lines, \(sizeKB > 0 ? "\(sizeKB)KB" : "\(data.count)B")) ---\n"

        // For large files, show head + tail
        if lineCount > 100 {
            let head = lines.prefix(50).joined(separator: "\n")
            let tail = lines.suffix(20).joined(separator: "\n")
            output += head + "\n\n... (\(lineCount - 70) lines omitted) ...\n\n" + tail + "\n"
        } else {
            output += content
            if !content.hasSuffix("\n") { output += "\n" }
        }

        return textResult(output)
    }

    private static func epiBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard let task = args.first else {
            return textResult("""
            epi: multidimensional epidemiological search framework (MESH-X)

            Usage: epi <research query>
            Example: epi "impact of urban temperature on dengue incidence in SE Asia"

            MESH-X Domains:
              population, exposure, comparison, outcome, temporal, setting, policy, socioeconomic
            """)
        }

        let queryStr = args.joined(separator: " ")
        let engine = EpiSearchEngine(brain: runtime.brain, research: runtime.researchEngine)
        let recentHistory = runtime.sessionStore.recent(limit: 10).map(\.source)

        // 1. Build MESH-X framework
        guard let mesh = engine.buildFramework(task: queryStr, cwd: runtime.context.currentDirectory, recentHistory: recentHistory) else {
            return textError("Failed to build MESH-X framework.\n", status: 1)
        }

        var lines: [String] = ["MESH-X Epidemiological Framework: \(mesh.title)"]
        lines.append(String(repeating: "=", count: 40))
        lines.append("")

        for facet in mesh.facets {
            lines.append("[\(facet.domain.rawValue.uppercased())]")
            lines.append("  Terms: \(facet.terms.joined(separator: ", "))")
            lines.append("  Expanded (MeSH/Synonyms): \(facet.expandedTerms.joined(separator: ", "))")
            lines.append("")
        }

        let combined = mesh.combinedQuery
        lines.append("Synthesized Multi-Index Query:")
        lines.append("  \(combined)")
        lines.append("")

        // 2. Execute search across domains
        lines.append("Executing Research (Roche Phase 1)...")
        let context = runtime.researchEngine.research(task: combined, runtime: runtime)

        lines.append("")
        lines.append("Research Results (\(context.allResults.count)):")
        for (i, r) in context.allResults.prefix(10).enumerated() {
            lines.append("[\(i+1)] \(r.title) (\(r.source))")
            if let url = r.url { lines.append("    \(url)") }
        }

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    private static func designBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let sub = args.first ?? "status"
        let subArgs = Array(args.dropFirst())
        
        switch sub {
        case "init":
            let path = runtime.context.currentDirectory + "/DESIGN.md"
            if FileManager.default.fileExists(atPath: path) {
                return textError("DESIGN.md already exists at \(path)\n", status: 1)
            }
            let template = runtime.designEngine.generateTemplate()
            do {
                try template.write(toFile: path, atomically: true, encoding: .utf8)
                return textResult("Initialized DESIGN.md with Google Stitch paradigm.\n")
            } catch {
                return textError("Failed to create DESIGN.md: \(error)\n", status: 1)
            }
            
        case "status", "show":
            if let design = runtime.designEngine.loadDesign(cwd: runtime.context.currentDirectory) {
                return textResult("Design System Active (DESIGN.md found):\n\n\(design)\n")
            } else {
                return textResult("No DESIGN.md found in current directory. Run 'design init' to create one.\n")
            }
            
        case "help":
            return textResult("""
            design: Design System Orchestrator (Stitch Paradigm)
            
            Subcommands:
              init        Create a standard DESIGN.md visual source of truth
              status      Show current design system rules
              help        Show this help
            
            When DESIGN.md is present, the agent automatically adheres to its
            visual theme, color palette, and rationale.
            """)
            
        default:
            return textError("Unknown design subcommand: \(sub)\n", status: 1)
        }
    }

    private static func analyzeBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard let domainStr = args.first else {
            return textError("""
            analyze: Specialized Codebase Analysis Toolkit

            Usage: analyze <domain> [path]
            
            Domains:
              web     Analyze Web Development codebase (React, Next.js, UI, Routes)
              stat    Analyze Statistical/Data Science codebase (Models, Pipelines)
              sec     Analyze Security/Systems codebase (Auth, Crypto, Unsafe functions)
              arch    General architectural analysis
            
            Example: analyze web ./src

            """, status: 1)
        }

        let domain: AnalyzerDomain
        switch domainStr.lowercased() {
        case "web": domain = .web
        case "stat": domain = .stat
        case "sec": domain = .sec
        case "arch": domain = .arch
        default: return textError("Unknown domain: \(domainStr). Expected: web, stat, sec, arch\n", status: 1)
        }

        let targetPath = args.dropFirst().first ?? runtime.context.currentDirectory
        let analyzer = CodebaseAnalyzer(indexer: runtime.codebaseIndexer)
        let report = analyzer.analyze(domain: domain, cwd: targetPath)

        var lines: [String] = ["Codebase Analysis Report: \(report.domain)"]
        lines.append(String(repeating: "=", count: 40))
        lines.append("Target: \(report.rootPath)")
        
        if !report.primaryLanguages.isEmpty { lines.append("Languages: \(report.primaryLanguages.joined(separator: ", "))") }
        if !report.frameworks.isEmpty { lines.append("Frameworks: \(report.frameworks.joined(separator: ", "))") }
        
        lines.append("")
        lines.append("Key Insights:")
        for insight in report.insights { lines.append("  \u{2022} \(insight)") }
        
        if let risks = report.riskFactors, !risks.isEmpty {
            lines.append("")
            lines.append("Potential Risk Factors:")
            for risk in risks { lines.append("  \u{26A0} \(risk)") }
        }
        
        if !report.entryPoints.isEmpty {
            lines.append("")
            lines.append("Detected Entry Points (\(report.entryPoints.count)):")
            for ep in report.entryPoints.prefix(5) { lines.append("  - \(ep)") }
        }

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    private static func tree(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let filtered = args.filter { !$0.hasPrefix("-") }
        let root = filtered.first ?? runtime.context.currentDirectory
        var maxDepth = 3
        if let lFlag = args.first(where: { $0.hasPrefix("-L") }) {
            let val = String(lFlag.dropFirst(2))
            if let n = Int(val) { maxDepth = n }
        }

        let ignoreNames: Set<String> = [
            ".git", ".build", ".swiftpm", "node_modules", "__pycache__",
            "DerivedData", ".DS_Store", ".Trash", "Library"
        ]

        let fm = FileManager.default
        var lines: [String] = [root.hasSuffix("/") ? root : (URL(fileURLWithPath: root).lastPathComponent)]
        var fileCount = 0
        var dirCount = 0

        func walk(path: String, prefix: String, depth: Int) {
            guard depth < maxDepth else { return }
            guard let entries = try? fm.contentsOfDirectory(atPath: path).sorted() else { return }
            let visible = entries.filter { !$0.hasPrefix(".") && !ignoreNames.contains($0) }

            for (index, name) in visible.enumerated() {
                let isLast = index == visible.count - 1
                let connector = isLast ? "\u{2514}\u{2500}\u{2500} " : "\u{251C}\u{2500}\u{2500} "
                let childPrefix = isLast ? "    " : "\u{2502}   "
                let fullPath = path + "/" + name

                var isDir: ObjCBool = false
                fm.fileExists(atPath: fullPath, isDirectory: &isDir)

                lines.append(prefix + connector + name)

                if isDir.boolValue {
                    dirCount += 1
                    walk(path: fullPath, prefix: prefix + childPrefix, depth: depth + 1)
                } else {
                    fileCount += 1
                }

                if lines.count > 200 {
                    lines.append(prefix + "... (truncated)")
                    return
                }
            }
        }

        walk(path: root, prefix: "", depth: 0)
        lines.append("")
        lines.append("\(dirCount) directories, \(fileCount) files")
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    private static func brainBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let sub = args.first ?? "status"
        let brain = runtime.brain

        switch sub {
        case "status":
            let info = brain.status()
            let lines = info.sorted(by: { $0.key < $1.key }).map { "  \($0.key): \($0.value)" }
            return textResult("brain\n" + lines.joined(separator: "\n") + "\n")

        case "model", "set", "use":
            guard args.count >= 2 else { return textError("brain: model <name>\n", status: 1) }
            brain.setModel(args[1])
            return textResult("Model set to \(args[1])\n")

        case "endpoint":
            guard args.count >= 2 else { return textError("brain: endpoint <url>\n", status: 1) }
            brain.setEndpoint(args[1])
            return textResult("Endpoint set to \(args[1])\n")

        case "on":
            brain.setEnabled(true)
            return textResult("Brain enabled.\n")

        case "off":
            brain.setEnabled(false)
            return textResult("Brain disabled. Using pattern matching only.\n")

        case "ping":
            let ok = brain.isAvailable()
            return textResult(ok ? "Brain is connected.\n" : "Brain is not reachable.\n")

        case "tune":
            let base = args.count >= 2 ? args[1] : nil
            let result = brain.tune(baseModel: base)
            return result.success
                ? textResult(result.message + "\n")
                : textError(result.message + "\n", status: 1)

        case "pull":
            guard args.count >= 2 else { return textError("brain: pull <model>\n", status: 1) }
            let result = brain.pull(model: args[1])
            return result.success
                ? textResult(result.message + "\n")
                : textError(result.message + "\n", status: 1)

        case "models":
            let info = brain.status()
            let models = info["available_models"] ?? "none"
            return textResult("Available models: \(models)\n")

        case "do":
            guard args.count >= 2 else { return textError("brain: do <task description>\n", status: 1) }
            return brainDoTask(args: Array(args.dropFirst()), runtime: runtime)

        case "clear":
            brain.clearConversation()
            return textResult("Conversation memory cleared.\n")

        case "openrouter":
            let key: String
            if args.count >= 2 {
                key = args[1]
            } else if let envKey = runtime.context.environment["OPENROUTER_API_KEY"], !envKey.isEmpty {
                key = envKey
            } else {
                return textError("Usage: brain openrouter <api-key> [model]\n  Or set OPENROUTER_API_KEY env var.\n  Models: anthropic/claude-sonnet-4, google/gemini-2.5-pro, meta-llama/llama-4-maverick\n", status: 1)
            }
            let model = args.count >= 3 ? args[2] : "anthropic/claude-sonnet-4"
            brain.useOpenRouter(apiKey: key, model: model)
            let connected = brain.isAvailable()
            return connected
                ? textResult("Switched to OpenRouter (\(model)). Connected \u{2713}\n")
                : textResult("Switched to OpenRouter (\(model)). Warning: connection check failed — verify API key.\n")

        case "local", "ollama":
            let model = args.count >= 2 ? args[1] : "gemma4"
            brain.useOllama(model: model)
            let connected = brain.isAvailable()
            return connected
                ? textResult("Switched to local Ollama (\(model)). Connected \u{2713}\n")
                : textResult("Switched to local Ollama (\(model)). Warning: Ollama not running.\n")

        case "apikey", "key":
            guard args.count >= 2 else { return textError("brain apikey <key>\n", status: 1) }
            brain.setApiKey(args[1])
            return textResult("API key set.\n")

        case "backend":
            let current = brain.config.backend.rawValue
            let endpoint = brain.config.endpoint
            let model = brain.config.model
            let hasKey = brain.config.apiKey != nil && !brain.config.apiKey!.isEmpty
            return textResult("Backend: \(current)\nEndpoint: \(endpoint)\nModel: \(model)\nAPI key: \(hasKey ? "set" : "not set")\n")

        default:
            return textError("""
            brain: commands
              status              Show brain state
              model|set <name>    Set model
              on / off            Enable/disable
              ping                Check connectivity
              openrouter <key> [model]  Switch to OpenRouter (cloud)
              local [model]       Switch to local Ollama
              apikey <key>        Set API key
              backend             Show current backend info
              models              List available models
              do <task>           Autonomous agent loop
              tune / pull / clear

            """, status: 1)
        }
    }

    private static func askBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard !args.isEmpty else {
            return textError("ask: ask <question...>\n", status: 1)
        }

        let question = args.joined(separator: " ")
        let brain = runtime.brain

        guard brain.config.enabled else {
            return textError("Brain is disabled. Run: brain on\n", status: 1)
        }

        guard brain.isAvailable() else {
            return textError("Brain not reachable at \(brain.config.endpoint). Is Ollama running?\n", status: 1)
        }

        let recentHistory = runtime.sessionStore.commandHistory(limit: 5)
        guard let answer = brain.ask(
            question: question,
            cwd: runtime.context.currentDirectory,
            lastStatus: runtime.context.lastStatus,
            recentHistory: recentHistory
        ), !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return textError("Brain returned empty response. Try a different model: brain set gemma3:4b\n", status: 1)
        }

        return textResult(answer + "\n")
    }

    private static func greet(runtime: BuiltinRuntime) -> CommandResult {
        let cwd = runtime.context.currentDirectory
        let store = runtime.runtimeStore
        let brain = runtime.brain

        var lines: [String] = []
        lines.append("dodexabash -- AI-native shell")
        lines.append("A trustworthy execution substrate for humans and AI systems.")
        lines.append("")
        lines.append("  cwd:   \(cwd)")

        if brain.config.enabled {
            let connected = brain.isAvailable()
            lines.append("  brain: \(brain.config.model) \(connected ? "(connected)" : "(offline)")")
        }

        if let intent = store.activeIntent, intent.status == .active {
            lines.append("  intent: \(intent.statement)")
        }

        let attn = store.pendingAttention().count
        if attn > 0 { lines.append("  attention: \(attn) pending") }

        let leaseCount = store.activeLeases().count
        if leaseCount > 0 { lines.append("  leases: \(leaseCount) active") }

        lines.append("")
        lines.append("Builtins: brief, tree, cards, next, status, help")
        lines.append("Runtime: intent, lease, simulate, prove, repair, attention, world")
        lines.append("Brain:   ask <question>, brain status")

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    private static func statusOverview(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let store = runtime.runtimeStore
        var lines: [String] = []
        lines.append("dodexabash status")
        lines.append("  cwd: \(runtime.context.currentDirectory)")
        lines.append("  last exit: \(runtime.context.lastStatus)")

        if let intent = store.activeIntent {
            lines.append("  intent: [\(intent.status.rawValue)] \(intent.statement)")
        }

        let active = store.activeLeases()
        if !active.isEmpty { lines.append("  leases: \(active.count) active") }

        let attn = store.pendingAttention()
        if !attn.isEmpty { lines.append("  attention: \(attn.count) pending") }

        lines.append("  artifacts: \(store.artifacts.count)")
        lines.append("  proofs: \(store.proofs.count)")
        lines.append("  repairs: \(store.repairPlans.count)")

        if let policy = store.activePolicy {
            lines.append("  policy: \(policy.rules.count) rule(s)")
        }

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    private static func doctorBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jsonMode = args.contains("--json")
        let report = doctorReport(runtime: runtime)
        if jsonMode {
            return jsonResult(report)
        }

        var lines: [String] = []
        lines.append("DodexaCode doctor")
        lines.append("  version: \(report.version)")
        lines.append("  cwd: \(report.cwd)")
        lines.append("  state root: \(report.stateRoot)")
        lines.append("  security mode: \(report.securityMode) — \(report.securitySummary)")
        lines.append("  workflows: \(report.workflows)  skills: \(report.localSkills)  traces: \(report.traces)")
        lines.append("  blocks: \(report.blocks)  artifacts: \(report.artifacts)  proofs: \(report.proofs)  repairs: \(report.repairs)")
        lines.append("  external MCP: \(report.mcpConnectedServers)/\(report.mcpConfiguredServers) servers connected, \(report.mcpDiscoveredTools) tools discovered")
        lines.append("")
        lines.append("Checks:")
        for check in report.checks {
            let marker = check.ok ? "\u{2713}" : "\u{2717}"
            lines.append("  \(marker) \(check.name): \(check.detail)")
        }
        if !report.recommendations.isEmpty {
            lines.append("")
            lines.append("Recommendations:")
            for recommendation in report.recommendations {
                lines.append("  - \(recommendation)")
            }
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    private static func catalogBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jsonMode = args.contains("--json")
        let filtered = args.filter { $0 != "--json" }
        let sub = filtered.first ?? "show"
        let catalog = capabilityCatalog(runtime: runtime)

        if jsonMode {
            return jsonResult(catalog)
        }

        switch sub {
        case "show", "list":
            var lines: [String] = []
            lines.append("DodexaCode capability catalog")
            lines.append("  product: \(catalog.product) \(catalog.version)")
            lines.append("  public repo: \(catalog.publicRepository)")
            lines.append("  compatibility name: \(catalog.compatibilityName)")
            lines.append("  shell builtins: \(catalog.builtinCount)")
            lines.append("  workflow cards: \(catalog.workflowCards.count)")
            lines.append("  MCP server: \(catalog.mcpServerTransport), \(catalog.mcpBuiltInToolCount) built-in tools")
            lines.append("  external MCP: \(catalog.externalMcpConnectedServers)/\(catalog.externalMcpConfiguredServers) servers connected, \(catalog.externalMcpDiscoveredTools) tools discovered")
            lines.append("")
            lines.append("Command domains:")
            for category in catalog.commandCategories {
                lines.append("  \(category.name): \(category.commands.joined(separator: ", "))")
            }
            lines.append("")
            lines.append("Future-shell primitives:")
            lines.append("  " + catalog.futureShellPrimitives.joined(separator: ", "))
            lines.append("")
            lines.append("Security modes:")
            for mode in catalog.securityModes {
                lines.append("  \(mode.name): \(mode.summary)")
            }
            lines.append("")
            lines.append("Run `catalog reviewer` for a guided walkthrough or `catalog --json` for machine-readable output.")
            return textResult(lines.joined(separator: "\n") + "\n")

        case "reviewer", "walkthroughs":
            var lines: [String] = ["DodexaCode reviewer walkthroughs"]
            for walkthrough in catalog.reviewerWalkthroughs {
                lines.append("")
                lines.append("[\(walkthrough.name)] \(walkthrough.goal)")
                for command in walkthrough.commands {
                    lines.append("  $ \(command)")
                }
                lines.append("  signals: \(walkthrough.expectedSignals.joined(separator: "; "))")
            }
            return textResult(lines.joined(separator: "\n") + "\n")

        case "mcp":
            let text = """
            DodexaCode MCP surface
              transport: \(catalog.mcpServerTransport)
              compatibility name: \(catalog.compatibilityName)
              built-in tools: \(catalog.mcpBuiltInToolCount)
              external configured servers: \(catalog.externalMcpConfiguredServers)
              external connected servers: \(catalog.externalMcpConnectedServers)
              external discovered tools: \(catalog.externalMcpDiscoveredTools)

            Start the server with:
              swift run dodexacode --mcp

            """
            return textResult(text)

        case "security":
            var lines: [String] = ["DodexaCode security modes"]
            for mode in catalog.securityModes {
                lines.append("  \(mode.name): \(mode.summary)")
            }
            lines.append("")
            lines.append("Safe baseline:")
            lines.append("  $ policy set security mode:passive hard")
            lines.append("  $ sec intel analyze runtime")
            lines.append("  $ sec detect system")
            return textResult(lines.joined(separator: "\n") + "\n")

        default:
            return textError("catalog [show|reviewer|mcp|security] [--json]\n", status: 1)
        }
    }

    static func doctorReport(runtime: BuiltinRuntime) -> DoctorReport {
        let fileManager = FileManager.default
        let stateRoot = stateRootPath(runtime: runtime)
        let statuses = runtime.mcpClient.serverStatus()
        let configuredServers = statuses.count
        let connectedServers = statuses.filter(\.connected).count
        let discoveredTools = runtime.mcpClient.allTools.count
        let workflows = runtime.workflowLibrary.listCards().count
        let localSkills = runtime.skillStore.list().count
        let traces = runtime.sessionStore.recent(limit: 500).count
        let blocks = runtime.blockStore.count
        let securityMode = currentSecurityAssessmentMode(runtime: runtime)
        let stateExists = fileManager.fileExists(atPath: stateRoot)
        let sessionFile = (stateRoot as NSString).appendingPathComponent("session.json")
        let runtimeFile = (stateRoot as NSString).appendingPathComponent("runtime.json")
        let blocksFile = (stateRoot as NSString).appendingPathComponent("blocks.json")

        let checks: [DoctorCheck] = [
            DoctorCheck(
                name: "state-root",
                ok: stateExists,
                detail: stateExists ? "present at \(stateRoot)" : "missing at \(stateRoot)"
            ),
            DoctorCheck(
                name: "state-writable",
                ok: fileManager.isWritableFile(atPath: stateRoot),
                detail: fileManager.isWritableFile(atPath: stateRoot) ? "directory is writable" : "directory is not writable"
            ),
            DoctorCheck(
                name: "session-memory",
                ok: fileManager.fileExists(atPath: sessionFile),
                detail: fileManager.fileExists(atPath: sessionFile) ? "\(traces) trace(s) persisted" : "session.json not present yet"
            ),
            DoctorCheck(
                name: "runtime-persistence",
                ok: fileManager.fileExists(atPath: runtimeFile),
                detail: fileManager.fileExists(atPath: runtimeFile)
                    ? "\(runtime.runtimeStore.artifacts.count) artifacts, \(runtime.runtimeStore.proofs.count) proofs"
                    : "runtime.json not present yet"
            ),
            DoctorCheck(
                name: "block-history",
                ok: fileManager.fileExists(atPath: blocksFile) || blocks > 0,
                detail: blocks > 0 ? "\(blocks) block(s) available" : "no block history yet"
            ),
            DoctorCheck(
                name: "workflow-library",
                ok: workflows >= 4,
                detail: "\(workflows) built-in workflow card(s)"
            ),
            DoctorCheck(
                name: "local-skill-store",
                ok: localSkills > 0,
                detail: "\(localSkills) local skill(s)"
            ),
            DoctorCheck(
                name: "security-governance",
                ok: true,
                detail: "mode \(securityMode.rawValue): \(securityMode.summary)"
            ),
            DoctorCheck(
                name: "external-mcp",
                ok: configuredServers == 0 || connectedServers > 0,
                detail: "\(connectedServers)/\(configuredServers) configured server(s) connected, \(discoveredTools) tool(s) discovered"
            )
        ]

        var recommendations: [String] = []
        if traces == 0 {
            recommendations.append("Run `brief .` and `status` once to seed local memory and persisted state.")
        }
        if runtime.runtimeStore.activePolicy == nil {
            recommendations.append("Set an explicit baseline policy with `policy set security mode:passive hard`.")
        }
        if configuredServers == 0 {
            recommendations.append("If you need outbound tool access, add an MCP server with `mcp add <name> <command> [args...]`.")
        } else if connectedServers == 0 {
            recommendations.append("Reconnect configured MCP servers with `mcp connect <name>` or restart the shell.")
        }
        if runtime.runtimeStore.activeIntent == nil {
            recommendations.append("Set an intent before multi-step work with `intent set <goal>`.")
        }

        return DoctorReport(
            product: "DodexaCode",
            version: "0.1.0",
            cwd: runtime.context.currentDirectory,
            stateRoot: stateRoot,
            securityMode: securityMode.rawValue,
            securitySummary: securityMode.summary,
            workflows: workflows,
            localSkills: localSkills,
            traces: traces,
            blocks: blocks,
            artifacts: runtime.runtimeStore.artifacts.count,
            proofs: runtime.runtimeStore.proofs.count,
            repairs: runtime.runtimeStore.repairPlans.count,
            mcpConfiguredServers: configuredServers,
            mcpConnectedServers: connectedServers,
            mcpDiscoveredTools: discoveredTools,
            checks: checks,
            recommendations: recommendations
        )
    }

    static func capabilityCatalog(runtime: BuiltinRuntime) -> CapabilityCatalog {
        let statuses = runtime.mcpClient.serverStatus()
        let workflows = runtime.workflowLibrary.listCards().map(\.slug)
        return CapabilityCatalog(
            product: "DodexaCode",
            version: "0.1.0",
            publicRepository: "https://github.com/Reyanda/dodexacode",
            compatibilityName: "dodexabash",
            builtinCount: knownBuiltins.count,
            commandCategories: capabilityCategories(),
            futureShellPrimitives: [
                "artifact", "intent", "lease", "simulate", "prove", "entity", "attention",
                "policy", "world", "uncertainty", "repair", "delegate", "replay", "semantic-diff"
            ],
            workflowCards: workflows,
            securityModes: SecurityAssessmentMode.allCases.map {
                SecurityModeDescriptor(name: $0.rawValue, summary: $0.summary)
            },
            mcpServerTransport: "stdio JSON-RPC",
            mcpBuiltInToolCount: 35,
            externalMcpConfiguredServers: statuses.count,
            externalMcpConnectedServers: statuses.filter(\.connected).count,
            externalMcpDiscoveredTools: runtime.mcpClient.allTools.count,
            reviewerWalkthroughs: reviewerWalkthroughs()
        )
    }

    private static func stateRootPath(runtime: BuiltinRuntime) -> String {
        if let override = runtime.context.environment["DODEXABASH_HOME"], !override.isEmpty {
            return override
        }
        return URL(fileURLWithPath: runtime.context.currentDirectory)
            .appendingPathComponent(".dodexabash", isDirectory: true)
            .path
    }

    private static func capabilityCategories() -> [CapabilityCategory] {
        [
            CapabilityCategory(name: "shell", commands: ["cd", "pwd", "echo", "env", "export", "unset", "alias", "function", "source", "exit"]),
            CapabilityCategory(name: "context", commands: ["brief", "history", "predict", "workflow", "md", "status", "doctor", "catalog"]),
            CapabilityCategory(name: "future-runtime", commands: ["intent", "lease", "simulate", "prove", "attention", "policy", "world", "uncertainty", "repair", "delegate", "replay", "artifact", "entity", "diff semantic"]),
            CapabilityCategory(name: "integration", commands: ["mcp", "tools", "blocks", "jobs", "git", "index", "browse", "search"]),
            CapabilityCategory(name: "security", commands: ["sec", "policy set security mode:passive", "policy set security mode:active", "policy set security mode:lab"])
        ]
    }

    private static func reviewerWalkthroughs() -> [ReviewerWalkthrough] {
        [
            ReviewerWalkthrough(
                name: "quickstart",
                goal: "Show workspace context, runtime readiness, and guided next steps in under a minute.",
                commands: [
                    "brief .",
                    "doctor",
                    "catalog reviewer"
                ],
                expectedSignals: [
                    "compact workspace brief",
                    "state root and persistence checks",
                    "curated walkthrough commands"
                ]
            ),
            ReviewerWalkthrough(
                name: "future-shell",
                goal: "Demonstrate typed execution primitives and safe preview before mutation.",
                commands: [
                    "intent set ship-release",
                    "simulate swift build",
                    "prove last",
                    "replay create"
                ],
                expectedSignals: [
                    "active intent contract",
                    "predicted effects and risk level",
                    "proof envelope",
                    "handoff packet"
                ]
            ),
            ReviewerWalkthrough(
                name: "security-baseline",
                goal: "Show policy-gated defensive security analysis without stealth or attribution masking.",
                commands: [
                    "policy set security mode:passive hard",
                    "sec intel analyze runtime",
                    "sec detect system"
                ],
                expectedSignals: [
                    "passive assessment mode banner",
                    "mirror-defense analysis",
                    "request-path or system detection report"
                ]
            )
        ]
    }

    private static func diffBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jsonMode = args.contains("--json")
        let filtered = args.filter { $0 != "--json" }
        guard filtered.count >= 3 else {
            return textError("diff: semantic <before> <after>\n", status: 1)
        }

        let sub = filtered[0]
        guard sub == "semantic" else {
            return textError("diff: expected 'semantic' subcommand\n", status: 1)
        }

        let before = filtered[1]
        let after = filtered[2]
        let fm = FileManager.default

        // If both are file paths, compare file contents
        if fm.fileExists(atPath: before) && fm.fileExists(atPath: after) {
            let beforeContent = (try? String(contentsOfFile: before, encoding: .utf8)) ?? ""
            let afterContent = (try? String(contentsOfFile: after, encoding: .utf8)) ?? ""
            let beforeLines = Set(beforeContent.split(separator: "\n").map(String.init))
            let afterLines = Set(afterContent.split(separator: "\n").map(String.init))
            let added = afterLines.subtracting(beforeLines)
            let removed = beforeLines.subtracting(afterLines)
            let preserves = added.isEmpty && removed.isEmpty

            let d = runtime.runtimeStore.createSemanticDiff(
                kind: "file",
                summary: "\(added.count) added, \(removed.count) removed",
                before: before,
                after: after,
                preservesBehavior: preserves,
                breakingChanges: removed.isEmpty ? [] : ["Removed \(removed.count) line(s)"]
            )
            if jsonMode { return jsonResult(d) }
            var lines = ["Semantic diff [\(d.id)] \(d.kind)"]
            lines.append("  summary: \(d.summary)")
            lines.append("  preserves behavior: \(d.preservesBehavior ?? false)")
            if !d.breakingChanges.isEmpty {
                lines.append("  breaking: \(d.breakingChanges.joined(separator: "; "))")
            }
            return textResult(lines.joined(separator: "\n") + "\n")
        }

        // Otherwise compare as string values
        let d = runtime.runtimeStore.createSemanticDiff(
            kind: "value",
            summary: before == after ? "identical" : "different",
            before: before,
            after: after,
            preservesBehavior: before == after
        )
        if jsonMode { return jsonResult(d) }
        return textResult("Semantic diff [\(d.id)] \(d.summary)\n")
    }

    // MARK: - Help

    private static func help() -> CommandResult {
        let text = """
        Shell:
          cd [dir]          pwd             echo [-n] [args...]
          env / set         export K=V      unset K
          alias [K=V]      unalias [-a]    function <name> <body>
          source <file>     clear / cls     exit [status]

        Files:
          open / cat <file>                 create <file.ext>
          tree [-L<depth>]                  brief [path]
          md [show|section|ingest] <path>

        AI:
          # <natural language>              generate a command (Tab to accept)
          ask <question>                    ask the brain anything
          brain [status|set|on|off|do|tune|pull|models|clear]
          skill [list|show|run|create|discover|import]

        Info:
          history [n]       predict [seed]    next
          cards             status            doctor
          catalog           help
          tip               theme [list|set]  graph

        Runtime:
          intent [set|show|clear|satisfy|fail]
          lease [grant|list|revoke|check|gc]
          simulate <cmd>    prove [last|list]
          attention [list|ack|push|clear]
          policy [show|set|clear|check]
          world [show]      uncertainty [show|assess]
          repair [last|list] delegate [spawn|list|status]
          replay [last|create|list]
          artifact / entity / diff semantic

        Security:
          sec scan <target>     port scan + fingerprinter
          sec discover <subnet> host discovery (ping sweep)
          sec dns <domain>      DNS recon
          sec arp               ARP table + local interfaces
          sec tls <host>        TLS/SSL certificate audit
          sec stress <host>     TCP connection load test
          sec vuln <target>     vulnerability report

        Shortcuts:
          ll  la  ..  ...  gs  gd  gl

        Keys:
          Tab      accept suggestion
          Up/Down  history
          Ctrl-A/E start/end of line
          Ctrl-L   clear + redraw
          Ctrl-C   interrupt
          Ctrl-D   exit

        """
        return textResult(text)
    }

    // MARK: - Grep (code search)

    private static func grepBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard !args.isEmpty else {
            return textError("grep <pattern> [path] [-n] [-l] [-c] [-i] [-C<n>] [-r]\n", status: 1)
        }

        var flags: [String] = ["-r", "--color=never"]
        var pattern: String?
        var searchPath: String?

        for arg in args {
            if arg.hasPrefix("-") {
                flags.append(arg)
            } else if pattern == nil {
                pattern = arg
            } else if searchPath == nil {
                searchPath = arg
            }
        }

        guard let pat = pattern else {
            return textError("grep: missing pattern\n", status: 1)
        }

        let path = searchPath ?? runtime.context.currentDirectory

        // Add default exclusions for code search
        let excludes = ["--exclude-dir=.git", "--exclude-dir=.build", "--exclude-dir=node_modules",
                        "--exclude-dir=__pycache__", "--exclude-dir=DerivedData", "--exclude-dir=.swiftpm"]

        var cmd = ["/usr/bin/grep"] + flags + excludes + [pat, path]

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = Array(cmd.dropFirst())
        process.standardOutput = stdout
        process.standardError = stderr
        process.currentDirectoryURL = URL(fileURLWithPath: runtime.context.currentDirectory)

        do {
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

            if output.isEmpty && process.terminationStatus == 1 {
                return textResult("No matches found.\n")
            }

            // Limit output to prevent flooding
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > 100 {
                let truncated = lines.prefix(100).joined(separator: "\n")
                return textResult(truncated + "\n... (\(lines.count - 100) more matches)\n")
            }

            return CommandResult(status: process.terminationStatus,
                                 io: ShellIO(stdout: Data(output.utf8), stderr: Data(err.utf8)))
        } catch {
            return textError("grep: \(error.localizedDescription)\n", status: 1)
        }
    }

    // MARK: - Glob (file pattern matching)

    private static func globBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard !args.isEmpty else {
            return textError("glob <pattern> [path]\nExamples: glob '*.swift', glob '**/*.ts' src/\n", status: 1)
        }

        // If the shell already expanded the glob (args has multiple files), just list them
        if args.count > 1 && !args.last!.hasPrefix("-") {
            // Check if these look like expanded filenames (no glob chars)
            let hasGlobChars = args.contains { $0.contains("*") || $0.contains("?") }
            if !hasGlobChars {
                // Shell already expanded — just list the results
                let output = args.sorted().joined(separator: "\n")
                return textResult("\(output)\n\n\(args.count) file(s)\n")
            }
        }

        // Manual glob: use the first arg as pattern, second as path
        let pattern = args[0].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        let searchPath = args.count >= 2 ? args[1] : runtime.context.currentDirectory
        let fm = FileManager.default
        let root = URL(fileURLWithPath: searchPath.hasPrefix("/") ? searchPath : runtime.context.currentDirectory + "/" + searchPath)
        let ignore: Set<String> = [".git", ".build", "node_modules", "__pycache__", "DerivedData", ".swiftpm"]

        let isRecursive = pattern.contains("**")
        let filePattern = pattern.replacingOccurrences(of: "**/", with: "")

        var matches: [String] = []

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: isRecursive ? [] : [.skipsSubdirectoryDescendants]
        ) else {
            return textError("glob: cannot enumerate \(searchPath)\n", status: 1)
        }

        while let fileURL = enumerator.nextObject() as? URL {
            if fileURL.pathComponents.contains(where: { ignore.contains($0) }) {
                enumerator.skipDescendants()
                continue
            }

            let name = fileURL.lastPathComponent
            if fnmatch(filePattern, name, 0) == 0 {
                let relative = fileURL.path.hasPrefix(root.path + "/")
                    ? String(fileURL.path.dropFirst(root.path.count + 1))
                    : fileURL.path
                matches.append(relative)
            }

            if matches.count > 500 { break }
        }

        if matches.isEmpty {
            return textResult("No files matching '\(pattern)'\n")
        }

        let output = matches.sorted().joined(separator: "\n")
        return textResult("\(output)\n\n\(matches.count) file(s)\n")
    }

    // MARK: - Fetch (URL fetcher)

    private static func fetchBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let rawMode = args.contains("--raw")
        let jsonMode = args.contains("--json")
        let filtered = args.filter { !$0.hasPrefix("--") }

        guard let urlStr = filtered.first, let url = URL(string: urlStr) else {
            return textError("fetch <url> [--raw] [--json]\n", status: 1)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("dodexabash/1.0", forHTTPHeaderField: "User-Agent")

        let sem = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultError: String?
        var statusCode = 0

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { resultError = error.localizedDescription }
            if let http = response as? HTTPURLResponse { statusCode = http.statusCode }
            resultData = data
            sem.signal()
        }.resume()

        sem.wait()

        if let err = resultError {
            return textError("fetch: \(err)\n", status: 1)
        }

        guard let data = resultData else {
            return textError("fetch: no data received\n", status: 1)
        }

        if jsonMode {
            if let json = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
                return textResult(String(decoding: pretty, as: UTF8.self) + "\n")
            }
            return textResult(String(decoding: data, as: UTF8.self) + "\n")
        }

        var content = String(decoding: data, as: UTF8.self)

        if !rawMode {
            // Strip HTML tags for readable text
            content = content
                .replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")

            // Collapse whitespace
            let lines = content.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            content = lines.joined(separator: "\n")

            // Truncate
            if content.count > 5000 {
                content = String(content.prefix(5000)) + "\n... (truncated)"
            }
        }

        var header = "HTTP \(statusCode) — \(url.host ?? urlStr)\n"
        header += String(repeating: "\u{2500}", count: 40) + "\n"
        return textResult(header + content + "\n")
    }

    // MARK: - Edit (inline file editing)

    private static func editBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let replaceAll = args.first == "-a"
        let filtered = replaceAll ? Array(args.dropFirst()) : args

        guard filtered.count >= 3 else {
            return textError("edit <file> <old_text> <new_text> [-a for all]\nExample: edit main.swift 'func old' 'func new'\n", status: 1)
        }

        let filename = filtered[0]
        let oldText = filtered[1].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        let newText = filtered[2].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))

        let path: String
        if filename.hasPrefix("/") {
            path = filename
        } else {
            path = runtime.context.currentDirectory + "/" + filename
        }

        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return textError("edit: could not read \(filename)\n", status: 1)
        }

        guard content.contains(oldText) else {
            return textError("edit: '\(oldText)' not found in \(filename)\n", status: 1)
        }

        let newContent: String
        if replaceAll {
            newContent = content.replacingOccurrences(of: oldText, with: newText)
        } else {
            if let range = content.range(of: oldText) {
                newContent = content.replacingCharacters(in: range, with: newText)
            } else {
                return textError("edit: replacement failed\n", status: 1)
            }
        }

        // Show diff
        let occurrences = replaceAll
            ? content.components(separatedBy: oldText).count - 1
            : 1

        do {
            try newContent.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return textError("edit: could not write \(filename): \(error.localizedDescription)\n", status: 1)
        }

        var output = "Edited \(filename)\n"
        output += "  - \(oldText.prefix(50))\n"
        output += "  + \(newText.prefix(50))\n"
        output += "  \(occurrences) replacement(s)\n"
        return textResult(output)
    }

    // MARK: - Calculator (delegates to MathEngine)

    private static func calc(args: [String]) -> CommandResult {
        let expr = args.joined(separator: " ")
        guard !expr.isEmpty else {
            return textResult(MathEngine.help())
        }
        if let result = MathEngine.evaluate(expr) {
            return textResult(result + "\n")
        }
        return textError("calc: could not evaluate '\(expr)'\n", status: 1)
    }

    static func evaluateArithmetic(_ expr: String) -> Double? {
        MathEngine.evaluateExpression(expr)
    }

    // MARK: - Themes

    private static func themeBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let sub = args.first ?? "list"

        switch sub {
        case "list":
            let current = runtime.context.environment["DODEXABASH_THEME"] ?? "ocean"
            var lines = ["Available themes:\n"]
            for theme in Theme.all {
                let marker = theme.name == current ? " \u{25CF}" : "  "
                let preview = "\u{001B}[38;5;\(theme.accent)m\u{2588}\u{2588}\u{001B}[38;5;\(theme.prompt)m\u{2588}\u{2588}\u{001B}[38;5;\(theme.statusOk)m\u{2588}\u{2588}\u{001B}[38;5;\(theme.statusErr)m\u{2588}\u{2588}\u{001B}[38;5;\(theme.intent)m\u{2588}\u{2588}\u{001B}[0m"
                lines.append("\(marker) \(theme.name)  \(preview)")
            }
            lines.append("\nUse: theme set <name>")
            return textResult(lines.joined(separator: "\n") + "\n")

        case "set", "use":
            guard args.count >= 2 else { return textError("theme: set <name>\n", status: 1) }
            let name = args[1]
            guard runtime.themeStore.set(byName: name) else {
                return textError("theme: unknown theme '\(name)'. Run 'theme list' to see options.\n", status: 1)
            }
            return textResult("Theme set to '\(name)'. Run 'clear' to apply.\n")

        case "current":
            return textResult("Current theme: \(runtime.themeStore.current.name)\n")

        default:
            return textError("theme: list, set <name>, current\n", status: 1)
        }
    }

    private static func skillBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jsonMode = args.contains("--json")
        let filtered = args.filter { $0 != "--json" }
        let sub = filtered.first ?? "list"

        switch sub {
        case "list":
            let skills = runtime.skillStore.list()
            if jsonMode { return jsonResult(skills) }
            guard !skills.isEmpty else { return textResult("No skills defined.\n") }
            let body = skills.map { s in
                "[\(s.name)] \(s.description)\n  tags: \(s.tags.joined(separator: ", ")) | \(s.steps.count) steps"
            }.joined(separator: "\n")
            return textResult(body + "\n")

        case "show":
            guard filtered.count >= 2 else { return textError("skill: show <name>\n", status: 1) }
            guard let skill = runtime.skillStore.get(name: filtered[1]) else {
                return textError("skill: '\(filtered[1])' not found\n", status: 1)
            }
            if jsonMode { return jsonResult(skill) }
            var lines = ["[\(skill.name)] \(skill.description)", ""]
            for (i, step) in skill.steps.enumerated() {
                lines.append("  \(i + 1). \(step)")
            }
            lines.append("")
            lines.append("tags: \(skill.tags.joined(separator: ", "))")
            return textResult(lines.joined(separator: "\n") + "\n")

        case "run":
            guard filtered.count >= 2 else { return textError("skill: run <name>\n", status: 1) }
            guard let skill = runtime.skillStore.get(name: filtered[1]) else {
                return textError("skill: '\(filtered[1])' not found\n", status: 1)
            }
            return runSkill(skill, runtime: runtime)

        case "create":
            guard filtered.count >= 3 else {
                return textError("skill: create <name> <description> [step1] [step2] ...\n", status: 1)
            }
            let name = filtered[1]
            let desc = filtered[2]
            let steps = Array(filtered.dropFirst(3))
            let skill = Skill(
                name: name,
                description: desc,
                steps: steps.isEmpty ? ["Define steps for this skill"] : steps,
                tags: [name]
            )
            runtime.skillStore.save(skill)
            return textResult("Created skill '\(name)'\n")

        case "delete":
            guard filtered.count >= 2 else { return textError("skill: delete <name>\n", status: 1) }
            if runtime.skillStore.delete(name: filtered[1]) {
                return textResult("Deleted skill '\(filtered[1])'\n")
            }
            return textError("skill: '\(filtered[1])' not found\n", status: 1)

        case "discover":
            let discovered = runtime.skillStore.discoverSystemSkills()
            guard !discovered.isEmpty else {
                return textResult("No external skills found.\nSearched: ~/.claude/skills, ~/.codex/skills, ~/.inference_os/skills\n")
            }
            var lines = ["Found \(discovered.count) skill(s):\n"]
            for skill in discovered {
                let sourceDir = skill.source.components(separatedBy: "/").suffix(2).joined(separator: "/")
                lines.append("  [\(skill.name)] \(skill.format == .json ? "json" : "md") from \(sourceDir)")
            }
            lines.append("\nUse: skill import <name> to import a discovered skill")
            return textResult(lines.joined(separator: "\n") + "\n")

        case "import":
            guard filtered.count >= 2 else { return textError("skill: import <name>\n", status: 1) }
            let name = filtered[1]
            let discovered = runtime.skillStore.discoverSystemSkills()
            if name == "all" {
                var count = 0
                for d in discovered {
                    _ = runtime.skillStore.importSkill(d)
                    count += 1
                }
                return textResult("Imported \(count) skill(s).\n")
            }
            guard let found = discovered.first(where: { $0.name == name }) else {
                return textError("skill: '\(name)' not found in system. Run 'skill discover' first.\n", status: 1)
            }
            let imported = runtime.skillStore.importSkill(found)
            return textResult("Imported skill '\(imported.name)' (\(imported.steps.count) steps)\n")

        default:
            return textError("skill: list, show, run, create, delete, discover, import [all|<name>]\n", status: 1)
        }
    }

    private static func runSkill(_ skill: Skill, runtime: BuiltinRuntime) -> CommandResult {
        let brain = runtime.brain

        // If brain is available, let it execute the skill steps intelligently
        if brain.config.enabled, brain.isAvailable() {
            let task = """
            Execute the skill '\(skill.name)': \(skill.description)
            Steps to follow:
            \(skill.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
            """

            let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let shell = Shell(context: ShellContext(environment: runtime.context.environment), stateRoot: tmpDir)

            let steps = brain.executeTask(
                task: task,
                cwd: runtime.context.currentDirectory
            ) { command in
                let result = shell.run(source: command)
                return (result.status, result.stdout, result.stderr)
            }

            var output = "Running skill: \(skill.name)\n"
            output += String(repeating: "\u{2500}", count: 40) + "\n"
            for step in steps {
                output += "\n[\(step.step)] \(step.thought)\n"
                if let cmd = step.command {
                    output += "  \u{25B8} \(cmd)\n"
                }
                if let out = step.output, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    for line in out.split(separator: "\n").prefix(3) {
                        output += "    \(line)\n"
                    }
                }
                if step.status == "done" { output += "\nSkill complete.\n" }
            }
            try? FileManager.default.removeItem(at: tmpDir)
            return textResult(output)
        }

        // Brain not available — just list the steps as a checklist
        var output = "Skill: \(skill.name)\n\(skill.description)\n\n"
        for (i, step) in skill.steps.enumerated() {
            output += "  [ ] \(i + 1). \(step)\n"
        }
        output += "\nRun with brain on for autonomous execution.\n"
        return textResult(output)
    }

    // MARK: - Brain Agent

    private static func brainDoTask(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let task = args.joined(separator: " ")
        let brain = runtime.brain

        guard brain.config.enabled, brain.isAvailable() else {
            return textError("Brain not available. Run 'brain on' and ensure Ollama is running.\n", status: 1)
        }

        // Create a shell command executor that the brain can call
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let shell = Shell(context: ShellContext(environment: runtime.context.environment), stateRoot: tmpDir)

        let steps = brain.executeTask(
            task: task,
            cwd: runtime.context.currentDirectory
        ) { command in
            let result = shell.run(source: command)
            return (result.status, result.stdout, result.stderr)
        }

        // Format output
        var output = "Agent: \(task)\n"
        output += String(repeating: "\u{2500}", count: 40) + "\n"

        for step in steps {
            output += "\n[\(step.step)] \(step.thought)\n"
            if let cmd = step.command {
                output += "  \u{25B8} \(cmd)\n"
            }
            if let out = step.output, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let lines = out.split(separator: "\n").prefix(5)
                for line in lines {
                    output += "    \(line)\n"
                }
                if out.split(separator: "\n").count > 5 {
                    output += "    ... (\(out.split(separator: "\n").count - 5) more lines)\n"
                }
            }
            if step.status == "done" {
                output += "\nDone.\n"
            } else if step.status == "error" && step.command == nil {
                output += "  (stopped)\n"
            }
        }

        try? FileManager.default.removeItem(at: tmpDir)
        return textResult(output)
    }

    // MARK: - Aliases & Functions

    private static func aliasBuiltin(args: [String], context: ShellContext) -> CommandResult {
        if args.isEmpty {
            // List all aliases
            guard !context.aliases.isEmpty else { return textResult("No aliases defined.\n") }
            let body = context.aliases.sorted(by: { $0.key < $1.key }).map { "alias \($0.key)='\($0.value)'" }.joined(separator: "\n")
            return textResult(body + "\n")
        }
        for item in args {
            if let eq = item.firstIndex(of: "=") {
                let name = String(item[..<eq])
                let value = String(item[item.index(after: eq)...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                context.aliases[name] = value
            } else {
                if let value = context.aliases[item] {
                    return textResult("alias \(item)='\(value)'\n")
                } else {
                    return textError("alias: \(item) not found\n", status: 1)
                }
            }
        }
        return CommandResult(status: 0, io: ShellIO())
    }

    private static func unaliasBuiltin(args: [String], context: ShellContext) -> CommandResult {
        if args.first == "-a" {
            context.aliases.removeAll()
            return textResult("All aliases removed.\n")
        }
        for name in args {
            context.aliases.removeValue(forKey: name)
        }
        return CommandResult(status: 0, io: ShellIO())
    }

    private static func functionBuiltin(args: [String], context: ShellContext) -> CommandResult {
        // function list — show all functions
        // function name body... — define a function
        if args.isEmpty || args.first == "list" {
            guard !context.functions.isEmpty else { return textResult("No functions defined.\n") }
            let body = context.functions.sorted(by: { $0.key < $1.key }).map { entry in
                "function \(entry.key)() { \(entry.value.body) }"
            }.joined(separator: "\n")
            return textResult(body + "\n")
        }

        guard args.count >= 2 else {
            return textError("function: function <name> <body...>\n", status: 1)
        }

        let name = args[0]
        let body = args.dropFirst().joined(separator: " ")
        context.functions[name] = ShellFunction(name: name, body: body, params: [])
        return textResult("Defined function \(name)\n")
    }

    private static func sourceBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard let path = args.first else {
            return textError("source: source <file>\n", status: 1)
        }

        let resolved: String
        if path.hasPrefix("/") {
            resolved = path
        } else {
            resolved = runtime.context.currentDirectory + "/" + path
        }

        guard let content = try? String(contentsOfFile: resolved, encoding: .utf8) else {
            return textError("source: could not read \(path)\n", status: 1)
        }

        // Execute each line
        var lastOutput = ""
        _ = lastOutput
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Handle alias definitions: alias name='value'
            if trimmed.hasPrefix("alias ") {
                let aliasArgs = [String(trimmed.dropFirst(6))]
                _ = aliasBuiltin(args: aliasArgs, context: runtime.context)
                continue
            }

            // Handle function definitions: function name() { body }
            if trimmed.hasPrefix("function ") {
                let parts = trimmed.dropFirst(9).components(separatedBy: "()")
                if parts.count >= 2 {
                    let name = parts[0].trimmingCharacters(in: .whitespaces)
                    var body = parts.dropFirst().joined(separator: "()").trimmingCharacters(in: .whitespaces)
                    if body.hasPrefix("{") { body = String(body.dropFirst()) }
                    if body.hasSuffix("}") { body = String(body.dropLast()) }
                    body = body.trimmingCharacters(in: .whitespaces)
                    runtime.context.functions[name] = ShellFunction(name: name, body: body, params: [])
                    continue
                }
            }

            // Handle export: export NAME=value
            if trimmed.hasPrefix("export ") {
                _ = export(args: [String(trimmed.dropFirst(7))], context: runtime.context)
                continue
            }

            lastOutput += trimmed + "\n"
        }

        return textResult("Sourced \(path)\n")
    }

    private static func exitBuiltin(args: [String], context: ShellContext) -> CommandResult {
        let status = Int32(args.first ?? "") ?? context.lastStatus
        context.shouldExit = true
        context.requestedExitStatus = status
        return CommandResult(status: status, io: ShellIO())
    }

    static func textResult(_ text: String, status: Int32 = 0) -> CommandResult {
        CommandResult(status: status, io: ShellIO(stdout: Data(text.utf8)))
    }

    static func textError(_ text: String, status: Int32) -> CommandResult {
        CommandResult(status: status, io: ShellIO(stderr: Data(text.utf8)))
    }

    static func jsonResult<T: Encodable>(_ value: T) -> CommandResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) {
            return CommandResult(status: 0, io: ShellIO(stdout: data + Data("\n".utf8)))
        }
        return textError("json: failed to encode output\n", status: 1)
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        guard let first = value.first else {
            return false
        }

        guard first.isLetter || first == "_" else {
            return false
        }

        return value.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func loadMarkdownDocument(from path: String, runtime: BuiltinRuntime) -> MarkdownLoadResult {
        do {
            return .success(try MarkdownNative.load(from: path, cwd: runtime.context.currentDirectory))
        } catch {
            return .failure(textError("md: \(error)\n", status: 1))
        }
    }

    // MARK: - MCP Client Builtins

    private static func mcpBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let sub = args.first ?? "status"
        let subArgs = Array(args.dropFirst())
        let client = runtime.mcpClient
        let json = subArgs.contains("--json")

        switch sub {
        case "status":
            let statuses = client.serverStatus()
            if statuses.isEmpty {
                return textResult("No MCP servers configured.\nAdd servers to .dodexabash/mcp.json or use 'mcp add <name> <command> [args...]'\n")
            }
            if json {
                return jsonResult(statuses.map { ["name": $0.name, "connected": $0.connected, "tools": $0.toolCount] })
            }
            var lines: [String] = ["MCP Servers:"]
            for s in statuses {
                let indicator = s.connected ? "\u{25CF}" : "\u{25CB}"
                let status = s.connected ? "connected (\(s.toolCount) tools)" : "disconnected"
                lines.append("  \(indicator) \(s.name) — \(status)")
            }
            return textResult(lines.joined(separator: "\n") + "\n")

        case "tools":
            let tools = client.allTools
            if tools.isEmpty {
                return textResult("No MCP tools available. Connect servers with 'mcp connect <name>'.\n")
            }
            if json {
                return jsonResult(tools.map { ["server": $0.server, "name": $0.tool.name, "description": $0.tool.description ?? ""] })
            }
            var lines: [String] = ["Available MCP Tools (\(tools.count)):"]
            for (server, tool) in tools {
                let desc = tool.description.map { " — \($0)" } ?? ""
                lines.append("  \(server).\(tool.name)\(desc)")
            }
            return textResult(lines.joined(separator: "\n") + "\n")

        case "call":
            guard subArgs.count >= 1 else {
                return textResult("Usage: mcp call <tool-name> [key=value ...]\n")
            }
            let toolName = subArgs[0]
            var arguments: [String: Any] = [:]
            for arg in subArgs.dropFirst() where arg != "--json" {
                let parts = arg.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    arguments[String(parts[0])] = String(parts[1])
                }
            }
            guard let result = client.callTool(qualifiedName: toolName, arguments: arguments) else {
                return CommandResult(status: 1, io: ShellIO(stderr: Data("mcp call failed\n".utf8)))
            }
            if result.isError {
                return CommandResult(status: 1, io: ShellIO(stderr: Data(("Error: " + result.content + "\n").utf8)))
            }
            return textResult(result.content + "\n")

        case "add":
            guard subArgs.count >= 2 else {
                return textResult("Usage: mcp add <name> <command> [args...]\n")
            }
            let name = subArgs[0]
            let command = subArgs[1]
            let cmdArgs = Array(subArgs.dropFirst(2).filter { $0 != "--json" })
            let config = McpServerConfig(name: name, command: command, args: cmdArgs)
            client.addServer(config)
            return textResult("Added MCP server '\(name)'. Run 'mcp connect \(name)' to start.\n")

        case "connect":
            guard let name = subArgs.first else {
                return textResult("Usage: mcp connect <name>\n")
            }
            // Find config and connect
            let statuses = client.serverStatus()
            if let found = statuses.first(where: { $0.name == name }) {
                if found.connected {
                    return textResult("Already connected to '\(name)' (\(found.toolCount) tools).\n")
                }
            }
            // Re-read config and connect
            client.connectAll()
            let newStatus = client.serverStatus()
            if let s = newStatus.first(where: { $0.name == name }), s.connected {
                return textResult("Connected to '\(name)' — \(s.toolCount) tools available.\n")
            }
            return CommandResult(status: 1, io: ShellIO(stderr: Data("Failed to connect to '\(name)'\n".utf8)))

        case "disconnect":
            guard let name = subArgs.first else {
                return textResult("Usage: mcp disconnect <name>\n")
            }
            client.disconnect(name)
            return textResult("Disconnected from '\(name)'.\n")

        case "remove":
            guard let name = subArgs.first else {
                return textResult("Usage: mcp remove <name>\n")
            }
            client.removeServer(name)
            return textResult("Removed MCP server '\(name)'.\n")

        default:
            return textResult("Usage: mcp [status|tools|call|add|connect|disconnect|remove]\n")
        }
    }

    // MARK: - Block Builtins

    private static func blocksBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let sub = args.first ?? "list"
        let subArgs = Array(args.dropFirst())
        let store = runtime.blockStore
        let json = subArgs.contains("--json")
        let limit = subArgs.compactMap { Int($0) }.first ?? 5

        switch sub {
        case "list", "recent":
            let blocks = store.recent(limit)
            if blocks.isEmpty {
                return textResult("No blocks yet.\n")
            }
            if json {
                return jsonResult(blocks.map { blockSummary($0) })
            }
            var lines: [String] = ["Recent Blocks (\(store.count) total):"]
            for block in blocks {
                let status = block.exitCode == 0 ? "\u{2713}" : "\u{2717} exit \(block.exitCode)"
                let ms = Int(block.duration * 1000)
                let dur = ms >= 1000 ? String(format: "%.1fs", block.duration) : "\(ms)ms"
                let meta = [status, dur].joined(separator: " · ")
                lines.append("  \(block.command)")
                lines.append("    \(meta)")
                if !block.output.stdout.isEmpty {
                    lines.append("    " + block.output.preview(limit: 80))
                }
            }
            return textResult(lines.joined(separator: "\n") + "\n")

        case "search":
            let query = subArgs.filter { $0 != "--json" && Int($0) == nil }.joined(separator: " ")
            guard !query.isEmpty else {
                return textResult("Usage: blocks search <query>\n")
            }
            let results = store.search(query: query)
            if results.isEmpty {
                return textResult("No blocks matching '\(query)'.\n")
            }
            var lines: [String] = ["Found \(results.count) blocks:"]
            for block in results.suffix(10) {
                lines.append("  \(block.command) — exit \(block.exitCode)")
            }
            return textResult(lines.joined(separator: "\n") + "\n")

        case "failures":
            let failures = store.failures(limit: limit)
            if failures.isEmpty {
                return textResult("No failed blocks.\n")
            }
            var lines: [String] = ["Failed Blocks (\(failures.count)):"]
            for block in failures {
                lines.append("  \(block.command) — exit \(block.exitCode)")
                if !block.output.stderr.isEmpty {
                    lines.append("    " + block.output.stderr.prefix(80).replacingOccurrences(of: "\n", with: " "))
                }
                if block.repairId != nil {
                    lines.append("    \u{2692} repair available")
                }
            }
            return textResult(lines.joined(separator: "\n") + "\n")

        case "show":
            guard let query = subArgs.first(where: { $0 != "--json" }) else {
                return textResult("Usage: blocks show <id>\n")
            }
            guard let id = UUID(uuidString: query), let block = store.block(byId: id) else {
                return textError("blocks: not found '\(query)'\n", status: 1)
            }
            if json {
                return jsonResult(block)
            }
            return textResult(renderBlockDetail(block) + "\n")

        case "export":
            guard let data = store.exportJSON() else {
                return CommandResult(status: 1, io: ShellIO(stderr: Data("Export failed\n".utf8)))
            }
            return CommandResult(status: 0, io: ShellIO(stdout: data))

        case "count":
            return textResult("\(store.count)\n")

        default:
            return textResult("Usage: blocks [list|show <id>|search|failures|export|count] [--json]\n")
        }
    }

    private static func blockSummary(_ block: Block) -> [String: Any] {
        var dict: [String: Any] = [
            "id": block.id.uuidString,
            "command": block.command,
            "exitCode": block.exitCode,
            "duration": block.duration,
            "cwd": block.workingDirectory
        ]
        if let branch = block.gitBranch { dict["gitBranch"] = branch }
        if let proof = block.proofId { dict["proofId"] = proof }
        if let intent = block.intentId { dict["intentId"] = intent }
        if let repair = block.repairId { dict["repairId"] = repair }
        return dict
    }

    private static func renderBlockDetail(_ block: Block) -> String {
        var lines: [String] = []
        lines.append("Block [\(block.id.uuidString)]")
        lines.append("  command: \(block.command)")
        lines.append("  exit: \(block.exitCode)")
        let ms = Int(block.duration * 1000)
        let dur = ms >= 1000 ? String(format: "%.1fs", block.duration) : "\(ms)ms"
        lines.append("  duration: \(dur)")
        lines.append("  cwd: \(block.workingDirectory)")
        if let branch = block.gitBranch { lines.append("  branch: \(branch)") }
        if let proof = block.proofId { lines.append("  proofId: \(proof)") }
        if let intent = block.intentId { lines.append("  intentId: \(intent)") }
        if let repair = block.repairId { lines.append("  repairId: \(repair)") }
        if let uncertainty = block.uncertaintyLevel { lines.append("  uncertainty: \(uncertainty.rawValue)") }

        let stdoutPreview = block.output.stdout
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(8)
            .map(String.init)
        if !stdoutPreview.isEmpty {
            lines.append("  stdout:")
            for line in stdoutPreview {
                lines.append("    \(line)")
            }
        }

        let stderrPreview = block.output.stderr
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(8)
            .map(String.init)
        if !stderrPreview.isEmpty {
            lines.append("  stderr:")
            for line in stderrPreview {
                lines.append("    \(line)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Job Control Builtins

    private static func jobsBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jobs = runtime.jobTable.list()
        if jobs.isEmpty {
            return textResult("No active jobs.\n")
        }
        var lines: [String] = []
        for job in jobs {
            let marker = job.id == runtime.jobTable.current?.id ? "+" : "-"
            let stateStr: String
            switch job.state {
            case .running: stateStr = "Running"
            case .stopped: stateStr = "Stopped"
            case .done: stateStr = "Done"
            }
            lines.append("[\(job.id)]\(marker)  \(stateStr)\t\(job.command)")
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    private static func fgBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jobId = args.first.flatMap(Int.init)
        guard let job = runtime.jobTable.foreground(jobId) else {
            if jobId != nil {
                return CommandResult(status: 1, io: ShellIO(stderr: Data("fg: no such job\n".utf8)))
            }
            return CommandResult(status: 1, io: ShellIO(stderr: Data("fg: no current job\n".utf8)))
        }
        if job.state == .stopped {
            return textResult("[\(job.id)]  Stopped\t\(job.command)\n")
        }
        return textResult("[\(job.id)]  Done\t\(job.command)\n")
    }

    private static func bgBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let jobId = args.first.flatMap(Int.init)
        guard let job = runtime.jobTable.background(jobId) else {
            if jobId != nil {
                return CommandResult(status: 1, io: ShellIO(stderr: Data("bg: no such job\n".utf8)))
            }
            return CommandResult(status: 1, io: ShellIO(stderr: Data("bg: no current job\n".utf8)))
        }
        return textResult("[\(job.id)]  Running\t\(job.command) &\n")
    }

    private static func jsonResult<T>(_ value: T) -> CommandResult where T: Any {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return textResult("{}\n")
        }
        return textResult(text + "\n")
    }
}

private extension FileManager {
    func changeCurrentDirectoryPathCompat(_ path: String) throws {
        guard changeCurrentDirectoryPath(path) else {
            throw NSError(
                domain: "DodexaBash",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "could not change directory to \(path)"]
            )
        }
    }
}
