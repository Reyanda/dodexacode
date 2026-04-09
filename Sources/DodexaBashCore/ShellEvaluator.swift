import Darwin
import Foundation

public struct ShellRunResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let shouldExit: Bool

    public init(status: Int32, stdout: String, stderr: String, shouldExit: Bool) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.shouldExit = shouldExit
    }
}

public final class Shell {
    public let context: ShellContext
    public let sessionStore: SessionStore
    public let workspaceBriefer: WorkspaceBriefer
    public let workflowLibrary: WorkflowLibrary
    public let runtimeStore: FutureRuntimeStore
    public let brain: LocalBrain
    public let skillStore: SkillStore
    public let blockStore: BlockStore
    public let mcpClient: McpClient
    public let jobTable: JobTable
    public let codebaseIndexer: CodebaseIndexer
    public let pipelineExecutor: PipelineExecutor
    public let themeStore: ThemeStore
    public let researchEngine: ResearchEngine
    public let designEngine: DesignEngine

    /// Callback fired after each block is created (for TUI rendering, Active AI, etc.)
    public var onBlockCreated: ((Block) -> Void)?

    public init(context: ShellContext = ShellContext(), stateRoot: URL? = nil) {
        self.context = context
        let launchDirectory = stateRoot ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let persistedStateRoot: URL
        if let override = context.environment["DODEXABASH_HOME"], !override.isEmpty {
            persistedStateRoot = URL(fileURLWithPath: override)
        } else {
            persistedStateRoot = launchDirectory.appendingPathComponent(".dodexabash", isDirectory: true)
        }
        self.sessionStore = SessionStore(directory: persistedStateRoot)
        self.workspaceBriefer = WorkspaceBriefer()
        self.workflowLibrary = WorkflowLibrary.defaultLibrary()
        self.runtimeStore = FutureRuntimeStore(directory: persistedStateRoot)
        self.brain = LocalBrain(directory: persistedStateRoot)
        self.skillStore = SkillStore(directory: persistedStateRoot)
        self.blockStore = BlockStore(directory: persistedStateRoot)
        self.mcpClient = McpClient(directory: persistedStateRoot)
        self.jobTable = JobTable()
        self.codebaseIndexer = CodebaseIndexer(directory: persistedStateRoot)
        self.pipelineExecutor = PipelineExecutor()
        self.themeStore = ThemeStore(directory: persistedStateRoot)
        self.researchEngine = ResearchEngine()
        self.designEngine = DesignEngine()
        if context.environment["PWD"] == nil {
            context.environment["PWD"] = FileManager.default.currentDirectoryPath
        }
        // Auto-connect configured MCP servers
        mcpClient.connectAll()
        // Register default pipelines
        let (tokenPipeline, _, _) = TokenPipelineFactory.standard()
        pipelineExecutor.register(tokenPipeline)
        pipelineExecutor.register(TokenPipelineFactory.lightweight())
        let (aggressive, _, _) = TokenPipelineFactory.aggressive()
        pipelineExecutor.register(aggressive)
    }

    public func run(source: String) -> ShellRunResult {
        executeSource(source, shouldRecord: true)
    }

    private func runWithoutRecording(source: String) -> ShellRunResult {
        executeSource(source, shouldRecord: false)
    }

    private func executeSource(_ source: String, shouldRecord: Bool) -> ShellRunResult {
        let startedAt = Date()
        do {
            var lexer = Lexer(source: source)
            let tokens = try lexer.tokenize()
            var parser = Parser(tokens: tokens)
            let script = try parser.parseScript()
            let result = evaluate(script: script)
            context.lastStatus = result.status
            let shellResult = ShellRunResult(
                status: result.status,
                stdout: String(decoding: result.io.stdout, as: UTF8.self),
                stderr: String(decoding: result.io.stderr, as: UTF8.self),
                shouldExit: context.shouldExit
            )
            if shouldRecord {
                record(source: source, result: shellResult, startedAt: startedAt)
            }
            return shellResult
        } catch {
            context.lastStatus = 2
            let shellResult = ShellRunResult(
                status: 2,
                stdout: "",
                stderr: "parse error: \(error)\n",
                shouldExit: false
            )
            if shouldRecord {
                record(source: source, result: shellResult, startedAt: startedAt)
            }
            return shellResult
        }
    }

    private func evaluate(script: Script) -> CommandResult {
        var aggregate = ShellIO()
        var status: Int32 = 0

        for statement in script.statements {
            let result = evaluate(node: statement)
            aggregate.stdout.append(result.io.stdout)
            aggregate.stderr.append(result.io.stderr)
            status = result.status
            context.lastStatus = status
            if context.shouldExit {
                break
            }
        }

        return CommandResult(status: status, io: aggregate)
    }

    private func evaluate(node: CommandNode) -> CommandResult {
        switch node {
        case .simple(let command):
            return execute(simple: command, input: nil, pipelineMode: false)
        case .pipeline(let commands):
            return executePipeline(commands)
        case .conditional(let lhs, let op, let rhs):
            let leftResult = evaluate(node: lhs)
            var aggregate = leftResult.io
            var status = leftResult.status

            let shouldRunRight: Bool
            switch op {
            case .and:
                shouldRunRight = leftResult.status == 0
            case .or:
                shouldRunRight = leftResult.status != 0
            }

            if shouldRunRight {
                let rightResult = evaluate(node: rhs)
                aggregate.stdout.append(rightResult.io.stdout)
                aggregate.stderr.append(rightResult.io.stderr)
                status = rightResult.status
            }

            return CommandResult(status: status, io: aggregate)
        }
    }

    private func executePipeline(_ commands: [SimpleCommand]) -> CommandResult {
        guard commands.count >= 2 else {
            if let first = commands.first {
                return execute(simple: first, input: nil, pipelineMode: false)
            }
            return CommandResult(status: 0, io: ShellIO())
        }

        // For external-only pipelines, use real OS pipes for true streaming.
        // Mixed builtin/external pipelines fall back to buffered handoff.
        if canStreamPipeline(commands) {
            return executeStreamingPipeline(commands)
        }
        return executeBufferedPipeline(commands)
    }

    /// True streaming pipeline using OS-level pipes between processes.
    /// Each stage's stdout is wired directly to the next stage's stdin —
    /// no buffering in userspace, handles arbitrarily large data.
    private func executeStreamingPipeline(_ commands: [SimpleCommand]) -> CommandResult {
        var processes: [Process] = []
        var pipes: [Pipe] = []
        var allStderrPipes: [Pipe] = []

        for (index, command) in commands.enumerated() {
            let resolvedWords: [String]
            switch resolveWords(command.words) {
            case .success(let words): resolvedWords = words
            case .failure(let error): return error
            }
            guard let programName = resolvedWords.first,
                  let executable = resolveExecutable(named: programName) else {
                return CommandResult(
                    status: 127,
                    io: ShellIO(stderr: Data("\(resolvedWords.first ?? "?"): command not found\n".utf8))
                )
            }

            let process = Process()
            process.executableURL = executable
            process.arguments = Array(resolvedWords.dropFirst())
            process.environment = context.environment
            process.currentDirectoryURL = URL(fileURLWithPath: context.currentDirectory)

            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            allStderrPipes.append(stderrPipe)

            // Wire stdin: first stage gets inherited stdin or nothing, rest get previous pipe
            if index == 0 {
                process.standardInput = FileHandle.nullDevice
            } else {
                process.standardInput = pipes[index - 1]
            }

            // Wire stdout: last stage captures output, rest create a pipe to next stage
            if index == commands.count - 1 {
                let outputPipe = Pipe()
                process.standardOutput = outputPipe
                pipes.append(outputPipe)
            } else {
                let pipe = Pipe()
                process.standardOutput = pipe
                pipes.append(pipe)
            }

            processes.append(process)
        }

        // Launch all processes
        for process in processes {
            do {
                try process.run()
            } catch {
                // Kill already-started processes
                for p in processes where p.isRunning { p.terminate() }
                return CommandResult(
                    status: 126,
                    io: ShellIO(stderr: Data("pipeline: \(error.localizedDescription)\n".utf8))
                )
            }
        }

        // Wait for all to complete
        for process in processes {
            process.waitUntilExit()
        }

        // Collect output from last stage
        let stdout = pipes.last?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        var stderr = Data()
        for pipe in allStderrPipes {
            stderr.append(pipe.fileHandleForReading.readDataToEndOfFile())
        }

        let lastStatus = processes.last?.terminationStatus ?? 0
        return CommandResult(status: lastStatus, io: ShellIO(stdout: stdout, stderr: stderr))
    }

    /// Buffered pipeline for mixed builtin/external commands.
    private func executeBufferedPipeline(_ commands: [SimpleCommand]) -> CommandResult {
        var input: Data?
        var stderr = Data()
        var status: Int32 = 0

        for (index, command) in commands.enumerated() {
            let isLast = index == commands.count - 1
            let result = execute(simple: command, input: input, pipelineMode: true)
            stderr.append(result.io.stderr)
            status = result.status
            input = result.io.stdout

            if isLast {
                return CommandResult(
                    status: status,
                    io: ShellIO(stdout: result.io.stdout, stderr: stderr)
                )
            }
        }

        return CommandResult(status: status, io: ShellIO(stderr: stderr))
    }

    /// Check if all commands in a pipeline are external (no builtins).
    /// External-only pipelines can use true OS pipe streaming.
    private func canStreamPipeline(_ commands: [SimpleCommand]) -> Bool {
        for command in commands {
            switch resolveWords(command.words) {
            case .success(let words):
                guard let name = words.first else { return false }
                // If it's a builtin, alias, or function, can't stream
                if Builtins.isKnown(name) { return false }
                if context.aliases[name] != nil { return false }
                if context.functions[name] != nil { return false }
            case .failure:
                return false
            }
        }
        return true
    }

    private func execute(
        simple command: SimpleCommand,
        input: Data?,
        pipelineMode: Bool
    ) -> CommandResult {
        let resolvedWords: [String]
        switch resolveWords(command.words) {
        case .success(let words):
            resolvedWords = words
        case .failure(let error):
            return error
        }
        guard let commandName = resolvedWords.first else {
            return CommandResult(status: 0, io: ShellIO())
        }

        // Alias expansion — replace commandName with alias value and re-parse
        if let aliasValue = context.aliases[commandName] {
            let expanded = aliasValue + " " + Array(resolvedWords.dropFirst()).joined(separator: " ")
            let result = runWithoutRecording(source: expanded.trimmingCharacters(in: .whitespaces))
            return CommandResult(status: result.status, io: ShellIO(
                stdout: Data(result.stdout.utf8),
                stderr: Data(result.stderr.utf8)
            ))
        }

        // Shell function execution
        if let function = context.functions[commandName] {
            return executeFunction(function, args: Array(resolvedWords.dropFirst()), input: input)
        }

        let arguments = Array(resolvedWords.dropFirst())
        let resolvedRedirections = resolveRedirections(command.redirections)
        if let error = resolvedRedirections.error {
            return error
        }
        let redirections = (input: resolvedRedirections.input, output: resolvedRedirections.output)

        let effectiveInput = redirections.input ?? input

        let result: CommandResult
        if pipelineMode && Builtins.isStateful(commandName) {
            result = CommandResult(
                status: 1,
                io: ShellIO(stderr: Data("pipeline: stateful builtin '\(commandName)' is not supported\n".utf8))
            )
        } else if let builtin = Builtins.run(
            command: commandName,
            args: arguments,
            runtime: BuiltinRuntime(
                context: context,
                sessionStore: sessionStore,
                workspaceBriefer: workspaceBriefer,
                workflowLibrary: workflowLibrary,
                runtimeStore: runtimeStore,
                brain: brain,
                researchEngine: researchEngine,
                designEngine: designEngine,
                skillStore: skillStore,
                mcpClient: mcpClient,
                blockStore: blockStore,
                jobTable: jobTable,
                codebaseIndexer: codebaseIndexer,
                pipelineExecutor: pipelineExecutor,
                themeStore: themeStore
            ),
            input: effectiveInput
        ) {
            result = builtin
        } else {
            let fullPhrase = resolvedWords.joined(separator: " ")

            // 1. Try as arithmetic (4+9, 100/3, etc.)
            if let mathResult = handleAsArithmetic(fullPhrase) {
                result = mathResult
            }
            // 2. Try as a file (typing a filename opens it)
            else if let fileResult = handleAsFile(commandName, args: arguments) {
                result = fileResult
            }
            // 2. Brain is on? Route everything unknown through it
            else if brain.config.enabled, brain.isAvailable(), resolvedWords.count >= 2,
                    let brainResult = routeViaBrain(fullPhrase) {
                result = brainResult
            }
            // 3. Try external command
            else {
                let externalResult = runExternalCommand(
                    program: commandName,
                    args: arguments,
                    input: effectiveInput
                )
                if externalResult.status == 127 {
                    // Command not found — brain fallback or hint
                    if brain.config.enabled, brain.isAvailable(),
                       let brainResult = routeViaBrain(fullPhrase) {
                        result = brainResult
                    } else if !brain.config.enabled {
                        let hint = "\(commandName): command not found\nTip: run 'brain on' for natural language in any language\n"
                        result = CommandResult(status: 127, io: ShellIO(stderr: Data(hint.utf8)))
                    } else {
                        result = externalResult
                    }
                } else {
                    result = externalResult
                }
            }
        }

        return applyOutputRedirection(redirections.output, to: result)
    }

    private func resolveRedirections(_ redirections: [Redirection]) -> (input: Data?, output: OutputTarget?, error: CommandResult?) {
        var inputData: Data?
        var outputTarget: OutputTarget?

        for redirection in redirections {
            switch redirection {
            case .input(let word):
                let path: String
                switch resolveRedirectionTarget(word) {
                case .success(let resolvedPath):
                    path = resolvedPath
                case .failure(let error):
                    return (input: nil, output: outputTarget, error: error)
                }
                do {
                    inputData = try Data(contentsOf: URL(fileURLWithPath: path))
                } catch {
                    return (
                        input: nil,
                        output: outputTarget,
                        error: CommandResult(
                            status: 1,
                            io: ShellIO(stderr: Data("redirection: could not read \(path)\n".utf8))
                        )
                    )
                }
            case .output(let word, let append):
                switch resolveRedirectionTarget(word) {
                case .success(let path):
                    outputTarget = OutputTarget(path: path, append: append)
                case .failure(let error):
                    return (input: nil, output: outputTarget, error: error)
                }
            }
        }

        return (inputData, outputTarget, nil)
    }

    private func resolveWords(_ words: [Word]) -> Resolution<[String]> {
        var resolved: [String] = []

        for word in words {
            switch resolveWord(word) {
            case .success(let values):
                resolved.append(contentsOf: values)
            case .failure(let error):
                return .failure(error)
            }
        }

        return .success(resolved)
    }

    private func resolveRedirectionTarget(_ word: Word) -> Resolution<String> {
        switch resolveWord(word) {
        case .success(let values):
            guard values.count == 1, let value = values.first else {
                return .failure(CommandResult(
                    status: 1,
                    io: ShellIO(stderr: Data("redirection: ambiguous target '\(word.description)'\n".utf8))
                ))
            }
            return .success(value)
        case .failure(let error):
            return .failure(error)
        }
    }

    private func resolveWord(_ word: Word) -> Resolution<[String]> {
        var raw = ""

        for segment in word.segments {
            switch segment {
            case .literal(let literal):
                raw.append(literal)
            case .variable(let name):
                raw.append(context.environment[name] ?? "")
            case .lastExitStatus:
                raw.append(String(context.lastStatus))
            case .commandSubstitution(let source):
                switch evaluateCommandSubstitution(source) {
                case .success(let output):
                    raw.append(output)
                case .failure(let error):
                    return .failure(error)
                }
            }
        }

        let expandedTilde = expandTilde(in: raw, original: word)
        return .success(expandGlobsIfNeeded(expandedTilde))
    }

    private func expandTilde(in raw: String, original word: Word) -> String {
        guard let first = word.segments.first else {
            return raw
        }

        guard case .literal(let literal) = first, literal.hasPrefix("~") else {
            return raw
        }

        guard let home = context.environment["HOME"] else {
            return raw
        }

        if raw == "~" {
            return home
        }

        if raw.hasPrefix("~/") {
            return home + String(raw.dropFirst())
        }

        return raw
    }

    private func evaluateCommandSubstitution(_ source: String) -> Resolution<String> {
        let originalDirectory = context.currentDirectory
        let originalPWD = context.environment["PWD"]
        let childContext = ShellContext(
            environment: context.environment,
            lastStatus: context.lastStatus,
            shouldExit: false,
            requestedExitStatus: 0
        )
        let childShell = Shell(context: childContext)
        let result = childShell.runWithoutRecording(source: source)

        if FileManager.default.currentDirectoryPath != originalDirectory {
            _ = FileManager.default.changeCurrentDirectoryPath(originalDirectory)
        }
        context.environment["PWD"] = originalPWD ?? originalDirectory

        guard result.status == 0 else {
            let stderr = result.stderr.isEmpty
                ? "command substitution failed: \(source)\n"
                : result.stderr
            return .failure(CommandResult(status: result.status, io: ShellIO(stderr: Data(stderr.utf8))))
        }

        var output = result.stdout
        while output.hasSuffix("\n") || output.hasSuffix("\r") {
            output.removeLast()
        }
        output = output.replacingOccurrences(of: "\r\n", with: "\n")
        output = output.replacingOccurrences(of: "\n", with: " ")
        return .success(output)
    }

    private func expandGlobsIfNeeded(_ value: String) -> [String] {
        guard containsGlobPattern(value) else {
            return [value]
        }

        var matches = glob_t()
        defer { globfree(&matches) }

        let result = value.withCString { pattern in
            glob(pattern, 0, nil, &matches)
        }

        guard result == 0 else {
            return [value]
        }

        var expanded: [String] = []
        for index in 0..<Int(matches.gl_matchc) {
            guard let path = matches.gl_pathv[index] else {
                continue
            }
            expanded.append(String(cString: path))
        }

        return expanded.isEmpty ? [value] : expanded
    }

    private func containsGlobPattern(_ value: String) -> Bool {
        value.contains("*") || value.contains("?") || value.contains("[")
    }

    private func applyOutputRedirection(_ target: OutputTarget?, to result: CommandResult) -> CommandResult {
        guard let target else {
            return result
        }

        let url = URL(fileURLWithPath: target.path)
        do {
            if target.append, FileManager.default.fileExists(atPath: target.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: result.io.stdout)
                try handle.close()
            } else {
                try result.io.stdout.write(to: url, options: .atomic)
            }
            return CommandResult(
                status: result.status,
                io: ShellIO(stderr: result.io.stderr)
            )
        } catch {
            return CommandResult(
                status: 1,
                io: ShellIO(stderr: Data("redirection: \(error.localizedDescription)\n".utf8))
            )
        }
    }

    private func runExternalCommand(program: String, args: [String], input: Data?) -> CommandResult {
        guard let executable = resolveExecutable(named: program) else {
            return CommandResult(
                status: 127,
                io: ShellIO(stderr: Data("\(program): command not found\n".utf8))
            )
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executable
        process.arguments = args
        process.environment = context.environment
        process.currentDirectoryURL = URL(fileURLWithPath: context.currentDirectory)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if input != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            process.standardInput = FileHandle.standardInput
            stdinPipe = nil
        }

        do {
            try process.run()
            if let input, let stdinPipe {
                try stdinPipe.fileHandleForWriting.write(contentsOf: input)
                try stdinPipe.fileHandleForWriting.close()
            }
            process.waitUntilExit()

            let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            return CommandResult(
                status: process.terminationStatus,
                io: ShellIO(stdout: stdout, stderr: stderr)
            )
        } catch {
            return CommandResult(
                status: 126,
                io: ShellIO(stderr: Data("\(program): \(error.localizedDescription)\n".utf8))
            )
        }
    }

    private func resolveExecutable(named name: String) -> URL? {
        if name.contains("/") {
            let url = URL(fileURLWithPath: name)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        let pathEntries = (context.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":")
        for entry in pathEntries {
            let candidate = URL(fileURLWithPath: String(entry)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    private func record(source: String, result: ShellRunResult, startedAt: Date) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        let finishedAt = Date()
        let durationMs = Int(finishedAt.timeIntervalSince(startedAt) * 1000.0)

        sessionStore.record(
            source: trimmed,
            cwd: context.currentDirectory,
            status: result.status,
            durationMs: durationMs,
            stdoutPreview: preview(result.stdout),
            stderrPreview: preview(result.stderr)
        )

        // Auto-generate proof for every execution
        let proof = runtimeStore.proveExecution(
            command: trimmed,
            status: result.status,
            stdout: result.stdout,
            stderr: result.stderr,
            durationMs: durationMs,
            cwd: context.currentDirectory
        )
        let proofId = proof.id

        // Auto-generate repair plan on failure
        var repairId: String?
        if result.status != 0 {
            let repair = runtimeStore.suggestRepair(
                command: trimmed,
                exitStatus: result.status,
                stderr: result.stderr
            )
            repairId = repair.id
        }

        // Auto-create artifact from non-trivial output
        if result.status == 0 && result.stdout.count > 10 {
            runtimeStore.createArtifact(
                kind: .text,
                label: "output:\(trimmed.prefix(40))",
                content: result.stdout.count > 2000 ? String(result.stdout.prefix(2000)) : result.stdout,
                sourceCommand: trimmed
            )
        }

        // Create Block — the structured output unit
        let block = Block(
            command: trimmed,
            output: BlockOutput(
                stdout: result.stdout,
                stderr: result.stderr
            ),
            exitCode: result.status,
            duration: finishedAt.timeIntervalSince(startedAt),
            startedAt: startedAt,
            finishedAt: finishedAt,
            workingDirectory: context.currentDirectory,
            gitBranch: resolveGitBranch(),
            proofId: proofId,
            intentId: runtimeStore.activeIntent?.id,
            uncertaintyLevel: result.status == 0 ? .known : .inferred,
            repairId: repairId
        )
        blockStore.append(block)
        onBlockCreated?(block)
    }

    private func resolveGitBranch() -> String? {
        let gitHead = context.currentDirectory + "/.git/HEAD"
        guard let content = try? String(contentsOfFile: gitHead, encoding: .utf8) else {
            // Walk up to find .git
            var dir = context.currentDirectory
            while dir != "/" {
                let head = dir + "/.git/HEAD"
                if let content = try? String(contentsOfFile: head, encoding: .utf8) {
                    let prefix = "ref: refs/heads/"
                    if content.hasPrefix(prefix) {
                        return content.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    return String(content.prefix(8))
                }
                dir = (dir as NSString).deletingLastPathComponent
            }
            return nil
        }
        let prefix = "ref: refs/heads/"
        if content.hasPrefix(prefix) {
            return content.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(content.prefix(8))
    }

    // MARK: - Natural Language Routing

    private func executeFunction(_ function: ShellFunction, args: [String], input: Data?) -> CommandResult {
        // Set positional parameters $1, $2, etc.
        let savedVars: [(String, String?)] = args.indices.map { i in
            let key = String(i + 1)
            let old = context.environment[key]
            context.environment[key] = args[i]
            return (key, old)
        }
        context.environment["@"] = args.joined(separator: " ")
        context.environment["#"] = String(args.count)

        let result = runWithoutRecording(source: function.body)

        // Restore
        for (key, old) in savedVars {
            if let old { context.environment[key] = old }
            else { context.environment.removeValue(forKey: key) }
        }
        context.environment.removeValue(forKey: "@")
        context.environment.removeValue(forKey: "#")

        return CommandResult(status: result.status, io: ShellIO(
            stdout: Data(result.stdout.utf8),
            stderr: Data(result.stderr.utf8)
        ))
    }

    /// Gather real workspace context — file listings, key file contents, structure
    private func gatherWorkspaceContext() -> String {
        var parts: [String] = []
        let fm = FileManager.default
        let cwd = context.currentDirectory

        // List files with type annotations
        if let entries = try? fm.contentsOfDirectory(atPath: cwd) {
            let sorted = entries.filter { !$0.hasPrefix(".") }.sorted()
            var listing: [String] = []
            for entry in sorted.prefix(30) {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: cwd + "/" + entry, isDirectory: &isDir)
                listing.append(isDir.boolValue ? "\(entry)/" : entry)
            }
            parts.append("Directory contents: \(listing.joined(separator: ", "))")
            if sorted.count > 30 { parts.append("(\(sorted.count) total items)") }
        }

        // Workspace brief
        let brief = workspaceBriefer.generate(atPath: cwd)
        parts.append("Workspace: \(brief.compactText)")

        // Read key file contents (README, Package.swift, etc.) — like Codex indexing
        let keyFiles = ["README.md", "Package.swift", "package.json", "pyproject.toml",
                        "Makefile", "Dockerfile", ".mcp.json", "CLAUDE.md"]
        for filename in keyFiles {
            let path = cwd + "/" + filename
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                let preview = content.count > 500 ? String(content.prefix(500)) + "..." : content
                parts.append("[\(filename)]:\n\(preview)")
            }
        }

        // Read first few source files to understand the codebase
        let sourceExts: Set<String> = ["swift", "py", "js", "ts", "go", "rs", "java"]
        if let entries = try? fm.contentsOfDirectory(atPath: cwd) {
            let sourceFiles = entries.filter { entry in
                let ext = (entry as NSString).pathExtension.lowercased()
                return sourceExts.contains(ext)
            }.sorted().prefix(3)

            for file in sourceFiles {
                if let content = try? String(contentsOfFile: cwd + "/" + file, encoding: .utf8) {
                    let preview = content.count > 300 ? String(content.prefix(300)) + "..." : content
                    parts.append("[\(file)]:\n\(preview)")
                }
            }
        }

        // Git info
        if let branch = resolveGitBranch() {
            parts.append("Git branch: \(branch)")
        }

        // Active intent
        if let intent = runtimeStore.activeIntent {
            parts.append("Active intent: \(intent.statement)")
        }

        // Recent commands
        let recent = sessionStore.commandHistory(limit: 5)
        if !recent.isEmpty {
            parts.append("Recent commands: \(recent.joined(separator: ", "))")
        }

        return parts.joined(separator: "\n")
    }

    // Pattern matching is a minimal offline-only fallback.
    // When brain is on, all routing goes through routeViaBrain directly.

    // Detect pure math expressions like "4+9", "100/3", "(2+3)*4"
    private func handleAsArithmetic(_ phrase: String) -> CommandResult? {
        let cleaned = phrase.replacingOccurrences(of: " ", with: "")
        // Must contain at least one operator and only math characters
        let mathChars = CharacterSet(charactersIn: "0123456789.+-*/%()")
        guard cleaned.unicodeScalars.allSatisfy({ mathChars.contains($0) }),
              cleaned.contains(where: { "+-*/%".contains($0) }),
              cleaned.first?.isNumber == true || cleaned.first == "(" else {
            return nil
        }
        guard let result = Builtins.evaluateArithmetic(phrase) else { return nil }
        // Format: remove .0 for integers
        let formatted = result == result.rounded() && !result.isInfinite
            ? String(Int(result))
            : String(result)
        return CommandResult(status: 0, io: ShellIO(stdout: Data((formatted + "\n").utf8)))
    }

    // When a user types a filename directly, display its content inline
    private func handleAsFile(_ name: String, args: [String]) -> CommandResult? {
        guard name.contains("."), !name.hasPrefix("-") else { return nil }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return nil }

        let fm = FileManager.default
        let fullPath = name.hasPrefix("/") ? name : context.currentDirectory + "/" + name
        if fm.fileExists(atPath: fullPath) || fm.fileExists(atPath: name) {
            return executeNLCommand(command: "open \(name)", explanation: "Showing \(name)")
        }
        return nil
    }

    private func patternMatchNL(_ phrase: String) -> CommandResult? {
        let lowered = phrase.lowercased()
        let words = Set(lowered.split(whereSeparator: { !$0.isLetter }).map(String.init))
        guard words.count >= 2 else { return nil }

        var best: (command: String, score: Int, explanation: String)?

        for (pattern, candidate) in Self.naturalLanguagePatterns {
            let patternWords = Set(pattern.split(whereSeparator: { !$0.isLetter }).map(String.init))
            let overlap = words.intersection(patternWords).count
            guard overlap >= 2 else { continue }
            let score = overlap * 10 + (lowered.contains(pattern) ? 20 : 0)
            if best == nil || score > best!.score {
                best = (candidate.command, score, candidate.explanation)
            }
        }

        guard let match = best, match.score >= 20 else {
            return nil
        }

        return executeNLCommand(command: match.command, explanation: match.explanation)
    }

    // Detect obvious natural language locally before asking the brain to classify.
    // If the phrase has question words + pronouns/conversational verbs, it's NL — don't
    // let the brain return SHELL just because the first word happens to be a binary name.
    private static let nlQuestionWords: Set<String> = ["who", "what", "where", "when", "why", "how"]
    private static let nlPronouns: Set<String> = ["you", "me", "my", "your", "we", "they", "us", "i"]
    private static let nlVerbs: Set<String> = ["is", "are", "do", "does", "can", "should", "would", "could", "will", "shall"]

    private func isObviousNaturalLanguage(_ phrase: String) -> Bool {
        let words = Set(phrase.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        let hasQuestion = !words.intersection(Self.nlQuestionWords).isEmpty
        let hasPronoun = !words.intersection(Self.nlPronouns).isEmpty
        let hasVerb = !words.intersection(Self.nlVerbs).isEmpty
        // Two or more NL indicators = definitely natural language
        return [hasQuestion, hasPronoun, hasVerb].filter({ $0 }).count >= 2
    }

    private func routeViaBrain(_ phrase: String) -> CommandResult? {
        let recentHistory = sessionStore.commandHistory(limit: 5)
        let builtins = [
            "cd", "pwd", "echo", "env", "export", "unset", "set",
            "brief", "history", "predict", "workflow", "tree", "status",
            "cards", "next", "help", "exit", "brain", "ask", "theme", "tip", "skill",
            "open", "cat", "show", "create", "tree", "clear", "alias", "function", "source",
            "artifact", "intent", "lease", "simulate", "prove",
            "entity", "attention", "policy", "world", "uncertainty",
            "repair", "delegate", "replay", "diff", "md"
        ]

        // Gather rich context for the brain
        let brief = workspaceBriefer.generate(atPath: context.currentDirectory)
        let lastRepair = runtimeStore.lastRepairPlan()
        let indexContext = codebaseIndexer.contextForBrain(limit: 1500)
        let combinedBrief = indexContext.isEmpty ? brief.compactText : brief.compactText + "\n" + indexContext

        guard let response = brain.routeNaturalLanguage(
            phrase: phrase,
            cwd: context.currentDirectory,
            lastStatus: context.lastStatus,
            recentHistory: recentHistory,
            activeIntent: runtimeStore.activeIntent?.statement,
            builtins: builtins,
            workspaceBrief: combinedBrief,
            activeLeases: runtimeStore.activeLeases().count,
            pendingAttention: runtimeStore.pendingAttention().count,
            proofCount: runtimeStore.proofs.count,
            lastRepairSummary: lastRepair.map { "\($0.failedCommand): \($0.errorSummary.prefix(100))" }
        ) else {
            return nil
        }

        // Brain classified as SHELL — but if it's obviously NL, override
        if response.explanation == "pass-through" {
            if isObviousNaturalLanguage(phrase) {
                // Force brain to translate — ask again without SHELL option
                if let answer = brain.ask(
                    question: phrase,
                    cwd: context.currentDirectory,
                    lastStatus: context.lastStatus,
                    recentHistory: recentHistory
                ) {
                    let output = "brain> " + answer + "\n"
                    return CommandResult(status: 0, io: ShellIO(stdout: Data(output.utf8)))
                }
            }
            return nil
        }

        guard let command = response.command else {
            // Brain returned NOOP — answer the question with full workspace context.
            let workspaceContext = gatherWorkspaceContext()
            if let answer = brain.ask(
                question: phrase,
                cwd: context.currentDirectory,
                lastStatus: context.lastStatus,
                recentHistory: sessionStore.commandHistory(limit: 5),
                context: workspaceContext
            ), !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let output = "brain> " + answer + "\n"
                return CommandResult(status: 0, io: ShellIO(stdout: Data(output.utf8)))
            }
            let explanation = response.explanation.isEmpty ? "No answer" : response.explanation
            let output = "brain> \(explanation)\nTip: try a different model with 'brain set <model>'\n"
            return CommandResult(status: 0, io: ShellIO(stdout: Data(output.utf8)))
        }

        // Guard: if brain returns a greeting command but the user asked about something else,
        // answer the question directly instead
        let greetingCommands: Set<String> = ["hi", "hey", "hello", "who"]
        let lowered = phrase.lowercased()
        let isAboutSelf = lowered.contains("are you") || lowered.contains("is this") || lowered.contains("dodexabash")
        if greetingCommands.contains(command) && !isAboutSelf {
            if let answer = brain.ask(
                question: phrase,
                cwd: context.currentDirectory,
                lastStatus: context.lastStatus,
                recentHistory: sessionStore.commandHistory(limit: 5)
            ), !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return CommandResult(status: 0, io: ShellIO(stdout: Data(("brain> " + answer + "\n").utf8)))
            }
        }

        return executeNLCommand(command: command, explanation: response.explanation)
    }

    private func executeNLCommand(command: String, explanation: String) -> CommandResult {
        let header = ">> \(explanation)\n>> running: \(command)\n\n"
        let executed = runWithoutRecording(source: command)
        let combined = header + executed.stdout + executed.stderr
        return CommandResult(
            status: executed.status,
            io: ShellIO(
                stdout: Data(combined.utf8),
                stderr: Data()
            )
        )
    }

    private struct NLCandidate {
        let command: String
        let explanation: String
    }

    private static let naturalLanguagePatterns: [(String, NLCandidate)] = [
        // Identity
        ("who are you",             NLCandidate(command: "hi", explanation: "Introducing myself")),
        ("what are you",            NLCandidate(command: "hi", explanation: "Introducing myself")),
        ("introduce yourself",      NLCandidate(command: "hi", explanation: "Introducing myself")),

        // Listing / browsing
        ("list files",              NLCandidate(command: "ls", explanation: "Listing files")),
        ("list all files",          NLCandidate(command: "ls -la", explanation: "Listing all files with details")),
        ("show files",              NLCandidate(command: "ls", explanation: "Listing files")),
        ("what files",              NLCandidate(command: "ls", explanation: "Listing files")),
        ("show directory",          NLCandidate(command: "ls", explanation: "Listing directory contents")),
        ("show hidden files",       NLCandidate(command: "ls -la", explanation: "Listing all files including hidden")),

        // Navigation
        ("where am i",              NLCandidate(command: "pwd", explanation: "Showing current directory")),
        ("current directory",       NLCandidate(command: "pwd", explanation: "Showing current directory")),
        ("go home",                 NLCandidate(command: "cd ~", explanation: "Going to home directory")),
        ("go back",                 NLCandidate(command: "cd -", explanation: "Going to previous directory")),
        ("go up",                   NLCandidate(command: "cd ..", explanation: "Going up one directory")),

        // Info
        ("show environment",        NLCandidate(command: "env", explanation: "Showing environment variables")),
        ("show variables",          NLCandidate(command: "env", explanation: "Showing environment variables")),
        ("system info",             NLCandidate(command: "uname -a", explanation: "Showing system information")),
        ("disk space",              NLCandidate(command: "df -h", explanation: "Showing disk usage")),
        ("show date",               NLCandidate(command: "date", explanation: "Showing current date and time")),
        ("what time",               NLCandidate(command: "date", explanation: "Showing current date and time")),
        ("who am i",                NLCandidate(command: "whoami", explanation: "Showing current user")),

        // Workspace
        ("show workspace",          NLCandidate(command: "brief", explanation: "Generating workspace briefing")),
        ("workspace briefing",      NLCandidate(command: "brief", explanation: "Generating workspace briefing")),
        ("what is this project",    NLCandidate(command: "brief", explanation: "Generating workspace briefing")),
        ("summarize repo",          NLCandidate(command: "brief", explanation: "Generating workspace briefing")),
        ("show context",            NLCandidate(command: "brief", explanation: "Generating workspace briefing")),

        // History
        ("show history",            NLCandidate(command: "history", explanation: "Showing command history")),
        ("what did i do",           NLCandidate(command: "history", explanation: "Showing command history")),
        ("recent commands",         NLCandidate(command: "history", explanation: "Showing command history")),
        ("last commands",           NLCandidate(command: "history 5", explanation: "Showing last 5 commands")),

        // Prediction
        ("what should i do",        NLCandidate(command: "predict", explanation: "Predicting next commands")),
        ("what next",               NLCandidate(command: "predict", explanation: "Predicting next commands")),
        ("suggest command",         NLCandidate(command: "predict", explanation: "Predicting next commands")),

        // Build
        ("build project",           NLCandidate(command: "swift build", explanation: "Building the Swift project")),
        ("build",                   NLCandidate(command: "swift build", explanation: "Building the Swift project")),
        ("compile",                 NLCandidate(command: "swift build", explanation: "Building the Swift project")),
        ("run tests",               NLCandidate(command: "swift test", explanation: "Running tests")),
        ("test",                    NLCandidate(command: "swift test", explanation: "Running tests")),

        // Git
        ("show status",             NLCandidate(command: "git status", explanation: "Showing git status")),
        ("git status",              NLCandidate(command: "git status", explanation: "Showing git status")),
        ("show changes",            NLCandidate(command: "git diff", explanation: "Showing git changes")),
        ("show log",                NLCandidate(command: "git log --oneline -10", explanation: "Showing recent git history")),
        ("show branches",           NLCandidate(command: "git branch", explanation: "Listing git branches")),

        // Runtime
        ("show intent",             NLCandidate(command: "intent show", explanation: "Showing active intent")),
        ("show leases",             NLCandidate(command: "lease list", explanation: "Listing active leases")),
        ("show attention",          NLCandidate(command: "attention list", explanation: "Listing attention events")),
        ("show proofs",             NLCandidate(command: "prove list", explanation: "Listing proof envelopes")),
        ("show uncertainty",        NLCandidate(command: "uncertainty show", explanation: "Assessing uncertainty surface")),
        ("show world",              NLCandidate(command: "world show", explanation: "Building world graph")),
        ("show repair",             NLCandidate(command: "repair last", explanation: "Showing last repair plan")),
        ("show policy",             NLCandidate(command: "policy show", explanation: "Showing active policy")),
        ("what do i know",          NLCandidate(command: "uncertainty show", explanation: "Assessing uncertainty surface")),
        ("compress state",          NLCandidate(command: "replay create", explanation: "Creating cognitive packet")),

        // Help
        ("help me",                 NLCandidate(command: "help", explanation: "Showing available commands")),
        ("what can i do",           NLCandidate(command: "help", explanation: "Showing available commands")),
        ("show commands",           NLCandidate(command: "help", explanation: "Showing available commands")),
        ("show help",               NLCandidate(command: "help", explanation: "Showing available commands")),

        // Process
        ("show processes",          NLCandidate(command: "ps aux", explanation: "Listing running processes")),
        ("running processes",       NLCandidate(command: "ps aux", explanation: "Listing running processes")),

        // File creation
        ("create web page",         NLCandidate(command: "create index.html", explanation: "Creating web page")),
        ("create webpage",          NLCandidate(command: "create index.html", explanation: "Creating web page")),
        ("create html",             NLCandidate(command: "create index.html", explanation: "Creating HTML file")),
        ("create python",           NLCandidate(command: "create main.py", explanation: "Creating Python file")),
        ("create script",           NLCandidate(command: "create script.sh", explanation: "Creating shell script")),
        ("create markdown",         NLCandidate(command: "create notes.md", explanation: "Creating markdown file")),
        ("new file",                NLCandidate(command: "create new_file.txt", explanation: "Creating new file")),
    ]

    private func preview(_ text: String, limit: Int = 160) -> String {
        let compact = text.replacingOccurrences(of: "\n", with: "\\n")
        if compact.count <= limit {
            return compact
        }
        return String(compact.prefix(limit)) + "..."
    }
}

private struct OutputTarget {
    let path: String
    let append: Bool
}

private enum Resolution<Value> {
    case success(Value)
    case failure(CommandResult)
}
