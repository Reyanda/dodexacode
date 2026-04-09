import Foundation

// Thread-safe box for URLSession closure captures
private final class ResponseBox: @unchecked Sendable {
    var stringValue: String?
    var arrayValue: [String]?
}

// MARK: - Brain Configuration

public enum BrainBackend: String, Codable, Sendable {
    case ollama         // local Ollama server
    case openrouter     // OpenRouter API (cloud, multi-model)
}

public struct BrainConfig: Codable, Sendable {
    public var endpoint: String
    public var model: String
    public var timeoutSeconds: Double
    public var enabled: Bool
    public var backend: BrainBackend
    public var apiKey: String?           // for OpenRouter / cloud APIs

    public static let `default` = BrainConfig(
        endpoint: "http://localhost:11434",
        model: "gemma4",
        timeoutSeconds: 30,
        enabled: true,
        backend: .ollama,
        apiKey: nil
    )

    public static let openRouter = BrainConfig(
        endpoint: "https://openrouter.ai/api/v1",
        model: "anthropic/claude-sonnet-4",
        timeoutSeconds: 60,
        enabled: true,
        backend: .openrouter,
        apiKey: nil
    )
}

// MARK: - Brain Response

public struct BrainResponse {
    public let command: String?      // shell command to execute (nil if NOOP)
    public let explanation: String   // what the brain thinks
    public let confidence: Double    // 0.0-1.0
    public let raw: String           // raw LLM output
}

// MARK: - Local Brain

public final class LocalBrain {
    public var config: BrainConfig
    private let configURL: URL
    private var lastPingOk = false
    private var lastPingTime: Date?

    public init(directory: URL) {
        self.configURL = directory.appendingPathComponent("brain.json")
        self.config = LocalBrain.loadConfig(from: configURL)
    }

    // MARK: - Status

    public func isAvailable() -> Bool {
        // Cache ping for 60 seconds
        if let lastPing = lastPingTime, Date().timeIntervalSince(lastPing) < 60 {
            return lastPingOk
        }
        lastPingOk = ping()
        if !lastPingOk {
            lastPingOk = autoStart()
        }
        if lastPingOk {
            resolveModel()
        }
        lastPingTime = Date()
        return lastPingOk
    }

    private func autoStart() -> Bool {
        // Check if ollama binary exists
        let paths = ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"]
        guard let ollamaPath = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return false
        }

        // Launch ollama serve in background
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ollamaPath)
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }

        // Wait briefly for it to become ready
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.5)
            if ping() { return true }
        }
        return false
    }

    public func status() -> [String: String] {
        var result: [String: String] = [
            "backend": config.backend.rawValue,
            "endpoint": config.endpoint,
            "model": config.model,
            "enabled": config.enabled ? "yes" : "no"
        ]
        if config.apiKey != nil && !config.apiKey!.isEmpty {
            result["api_key"] = "set (\(config.apiKey!.prefix(8))...)"
        }
        if config.enabled {
            let avail = isAvailable()
            result["connected"] = avail ? "yes" : "no"
            if avail {
                if let models = listModels() {
                    let displayModels = models.count > 10 ? models.prefix(10).joined(separator: ", ") + " ... (\(models.count) total)" : models.joined(separator: ", ")
                    result["available_models"] = displayModels
                }
            }
        }
        return result
    }

    // MARK: - Natural Language → Command

    public func routeNaturalLanguage(
        phrase: String,
        cwd: String,
        lastStatus: Int32,
        recentHistory: [String],
        activeIntent: String?,
        builtins: [String],
        workspaceBrief: String? = nil,
        activeLeases: Int = 0,
        pendingAttention: Int = 0,
        proofCount: Int = 0,
        lastRepairSummary: String? = nil
    ) -> BrainResponse? {
        guard config.enabled, isAvailable() else { return nil }

        let systemPrompt = buildSystemPrompt(
            cwd: cwd,
            lastStatus: lastStatus,
            recentHistory: recentHistory,
            activeIntent: activeIntent,
            builtins: builtins,
            workspaceBrief: workspaceBrief,
            activeLeases: activeLeases,
            pendingAttention: pendingAttention,
            proofCount: proofCount,
            lastRepairSummary: lastRepairSummary
        )

        let userPrompt = phrase

        guard let raw = chat(system: systemPrompt, user: userPrompt) else { return nil }

        return parseResponse(raw)
    }

    // MARK: - Direct Query

    public func ask(
        question: String,
        cwd: String,
        lastStatus: Int32,
        recentHistory: [String],
        context: String? = nil
    ) -> String? {
        guard config.enabled, isAvailable() else { return nil }

        let system = """
        You are a knowledgeable assistant inside a shell called dodexabash. \
        Answer ANY question — general knowledge, science, history, culture, code, workspace, anything. \
        You are NOT limited to shell topics. If someone asks "what is a mango" just answer about mangoes. \
        Be concise and direct. Never say "I don't understand" or "not a command." Just answer the question. \
        Current directory: \(cwd). \
        \(context.map { "Context: \($0)" } ?? "")
        """

        return chat(system: system, user: question, useHistory: true)
    }

    // MARK: - Extended Query (for longer generation — research, planning)

    public func askExtended(
        question: String,
        cwd: String,
        lastStatus: Int32,
        recentHistory: [String],
        context: String? = nil,
        maxTokens: Int = 512 // Reduced default for efficiency
    ) -> String? {
        guard config.enabled, isAvailable() else { return nil }

        let system = """
        You are an expert analyst and planner inside dodexabash, an AI-native shell. \
        Provide thorough, detailed responses. Be comprehensive but structured. \
        Use markdown formatting (headers, bullets, code blocks) for clarity. \
        Current directory: \(cwd). \
        \(context.map { "Context: \($0)" } ?? "")
        """

        print("DEBUG: askExtended backend: \(config.backend)")
        var result = chatExtended(system: system, user: question, maxTokens: maxTokens)
        
        // Fallback for token limit errors (like OpenRouter 402)
        if result?.contains("fewer max_tokens") == true {
             print("DEBUG: Retrying with minimal tokens...")
             result = chatExtended(system: system, user: question, maxTokens: 256)
        }
        
        return result
    }

    private func chatExtended(system: String, user: String, maxTokens: Int) -> String? {
        // Route through the appropriate backend
        switch config.backend {
        case .ollama:
            return chatOllama(system: system, user: user, useHistory: false, maxTokens: maxTokens)
        case .openrouter:
            return chatOpenAICompatible(system: system, user: user, useHistory: false, maxTokens: maxTokens)
        }
    }

    // Legacy chatExtended body kept as reference — now routed through backends above
    private func _chatExtendedLegacy(system: String, user: String, maxTokens: Int) -> String? {
        guard let url = URL(string: config.endpoint + "/api/chat") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = max(config.timeoutSeconds, 60)

        let messages: [[String: String]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": user]
        ]

        let body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "stream": false,
            "options": [
                "temperature": 0.3,
                "num_predict": maxTokens
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData

        let box = ResponseBox()
        let sem = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? [String: Any],
               let content = message["content"] as? String {
                box.stringValue = content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            sem.signal()
        }.resume()

        sem.wait()
        return box.stringValue
    }

    // MARK: - Repair Assistance

    public func analyzeFailure(
        command: String,
        exitStatus: Int32,
        stderr: String,
        cwd: String
    ) -> String? {
        guard config.enabled, isAvailable() else { return nil }

        let system = """
        You are a shell error analyst. A command failed. \
        Diagnose the root cause and suggest a fix. \
        Output format:
        CAUSE: <one line root cause>
        FIX: <shell command to fix it>
        EXPLANATION: <brief explanation>
        """

        let user = """
        Command: \(command)
        Exit status: \(exitStatus)
        Directory: \(cwd)
        Stderr: \(stderr.prefix(500))
        """

        return chat(system: system, user: user)
    }

    // MARK: - Natural Language to Command (# prefix)

    public struct TranslatedCommand {
        public let command: String
        public let explanation: String
        public let confidence: Double
    }

    public func translateToCommand(
        naturalLanguage query: String,
        cwd: String,
        recentHistory: [String]
    ) -> TranslatedCommand? {
        guard config.enabled, isAvailable() else { return nil }

        let system = """
        You are a shell command translator. Convert natural language to shell commands. \
        Current directory: \(cwd). \
        Recent commands: \(recentHistory.prefix(5).joined(separator: ", ")). \
        Output EXACTLY in this format (no other text):
        COMMAND: <the shell command>
        EXPLAIN: <one-line explanation of what it does>
        If the request is unclear or dangerous, still provide a safe command with explanation.
        """

        guard let raw = chat(system: system, user: query) else { return nil }

        var command: String?
        var explanation = ""

        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("COMMAND:") {
                command = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.uppercased().hasPrefix("EXPLAIN:") {
                explanation = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            }
        }

        guard let cmd = command, !cmd.isEmpty else {
            // Fallback: treat entire response as a command if it looks like one
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.count < 200, !cleaned.contains("\n") {
                return TranslatedCommand(command: cleaned, explanation: "", confidence: 0.4)
            }
            return nil
        }

        return TranslatedCommand(command: cmd, explanation: explanation, confidence: 0.8)
    }

    // MARK: - Config Management

    public func setModel(_ model: String) {
        config.model = model
        saveConfig()
    }

    // MARK: - Fine-Tuning

    /// Create a custom Ollama Modelfile tuned for dodexabash shell tasks and register it.
    public func tune(baseModel: String? = nil) -> (success: Bool, message: String) {
        let base = baseModel ?? config.model
        let tunedName = "dodexabash"

        let modelfile = """
        FROM \(base)

        SYSTEM \"\"\"
        You are dodexabash-brain, a fine-tuned assistant for an AI-native shell on macOS.

        Your primary roles:
        1. COMMAND TRANSLATION: Convert natural language to shell commands
        2. KNOWLEDGE: Answer general questions concisely
        3. DIAGNOSTICS: Analyze errors, suggest fixes
        4. WORKSPACE AWARENESS: Understand project structure and context

        Shell builtins you know: cd, pwd, echo, env, export, unset, brief, history, predict, workflow, tree, status, cards, next, help, exit, brain, ask, artifact, intent, lease, simulate, prove, entity, attention, policy, world, uncertainty, repair, delegate, replay, diff, md, graph, hi, who

        When given natural language:
        - If it's a knowledge question (who is X, what is Y, explain Z): ANSWER it directly and concisely
        - If it's a request to do something (list files, build project): output the shell command ONLY
        - If asking about you specifically (who are you, what are you): introduce yourself as dodexabash
        - Never refuse to answer. Never return empty responses. Be helpful, concise, direct.
        - For shell commands: output ONLY the command, no explanation unless asked

        Style: terse, expert, no filler. Like a senior engineer who happens to know everything.
        \"\"\"

        PARAMETER temperature 0.3
        PARAMETER num_predict 256
        PARAMETER top_p 0.9
        """

        // Write Modelfile
        let modelfileURL = FileManager.default.temporaryDirectory.appendingPathComponent("dodexabash-Modelfile")
        do {
            try modelfile.write(to: modelfileURL, atomically: true, encoding: .utf8)
        } catch {
            return (false, "Failed to write Modelfile: \(error.localizedDescription)")
        }

        // Find ollama binary
        let paths = ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"]
        guard let ollamaPath = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return (false, "Ollama not found. Install with: brew install ollama")
        }

        // Create the model
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ollamaPath)
        process.arguments = ["create", tunedName, "-f", modelfileURL.path]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (false, "Failed to run ollama create: \(error.localizedDescription)")
        }

        let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        if process.terminationStatus == 0 {
            config.model = tunedName
            saveConfig()
            try? FileManager.default.removeItem(at: modelfileURL)
            return (true, "Created tuned model '\(tunedName)' from \(base). Now active.")
        } else {
            try? FileManager.default.removeItem(at: modelfileURL)
            return (false, "ollama create failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Pull a model from Ollama registry if not already available.
    public func pull(model: String) -> (success: Bool, message: String) {
        let paths = ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"]
        guard let ollamaPath = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return (false, "Ollama not found. Install with: brew install ollama")
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ollamaPath)
        process.arguments = ["pull", model]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (false, "Failed to run ollama pull: \(error.localizedDescription)")
        }

        if process.terminationStatus == 0 {
            return (true, "Pulled \(model) successfully.")
        } else {
            let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (false, "ollama pull failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// If the configured model isn't found, try to find a matching one from available models.
    public func resolveModel() {
        guard let models = listModels(), !models.isEmpty else { return }
        // Already exact match
        if models.contains(config.model) { return }
        // Try prefix match (e.g., "gemma3" matches "gemma3:4b")
        if let match = models.first(where: { $0.hasPrefix(config.model) }) {
            config.model = match
            saveConfig()
        }
    }

    public func setEndpoint(_ endpoint: String) {
        config.endpoint = endpoint
        lastPingOk = false
        lastPingTime = nil
        saveConfig()
    }

    public func setEnabled(_ enabled: Bool) {
        config.enabled = enabled
        saveConfig()
    }

    public func setBackend(_ backend: BrainBackend) {
        config.backend = backend
        lastPingOk = false
        lastPingTime = nil
        saveConfig()
    }

    public func setApiKey(_ key: String) {
        config.apiKey = key
        saveConfig()
    }

    /// Switch to OpenRouter with API key and optional model
    public func useOpenRouter(apiKey: String, model: String = "anthropic/claude-sonnet-4") {
        config.backend = .openrouter
        config.endpoint = "https://openrouter.ai/api/v1"
        config.apiKey = apiKey
        config.model = model
        config.timeoutSeconds = 60
        config.enabled = true
        lastPingOk = false
        lastPingTime = nil
        saveConfig()
    }

    /// Switch back to local Ollama
    public func useOllama(model: String = "gemma4") {
        config.backend = .ollama
        config.endpoint = "http://localhost:11434"
        config.apiKey = nil
        config.model = model
        config.timeoutSeconds = 30
        config.enabled = true
        lastPingOk = false
        lastPingTime = nil
        saveConfig()
    }

    // MARK: - Connectivity

    private func ping() -> Bool {
        switch config.backend {
        case .ollama:
            return pingOllama()
        case .openrouter:
            return pingOpenRouter()
        }
    }

    private func pingOllama() -> Bool {
        guard let url = URL(string: config.endpoint) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3

        let box = ResponseBox()
        let sem = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                box.stringValue = "ok"
            }
            sem.signal()
        }.resume()

        sem.wait()
        return box.stringValue != nil
    }

    private func pingOpenRouter() -> Bool {
        // OpenRouter: check if API key is set and models endpoint responds
        guard config.apiKey != nil, !config.apiKey!.isEmpty else { return false }
        guard let url = URL(string: config.endpoint + "/models") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.setValue("Bearer \(config.apiKey!)", forHTTPHeaderField: "Authorization")

        let box = ResponseBox()
        let sem = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                box.stringValue = "ok"
            }
            sem.signal()
        }.resume()

        sem.wait()
        return box.stringValue != nil
    }

    private func listModels() -> [String]? {
        switch config.backend {
        case .ollama:
            guard let url = URL(string: config.endpoint + "/api/tags") else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 5

            let box = ResponseBox()
            let sem = DispatchSemaphore(value: 0)

            URLSession.shared.dataTask(with: request) { data, _, _ in
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let list = json["models"] as? [[String: Any]] {
                    box.arrayValue = list.compactMap { $0["name"] as? String }
                }
                sem.signal()
            }.resume()

            sem.wait()
            return box.arrayValue

        case .openrouter:
            guard let url = URL(string: config.endpoint + "/models") else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            if let apiKey = config.apiKey {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }

            let box = ResponseBox()
            let sem = DispatchSemaphore(value: 0)

            URLSession.shared.dataTask(with: request) { data, _, _ in
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let list = json["data"] as? [[String: Any]] {
                    box.arrayValue = list.compactMap { $0["id"] as? String }.sorted()
                }
                sem.signal()
            }.resume()

            sem.wait()
            return box.arrayValue
        }
    }

    private func chat(system: String, user: String, useHistory: Bool = false) -> String? {
        switch config.backend {
        case .ollama:
            return chatOllama(system: system, user: user, useHistory: useHistory, maxTokens: 256)
        case .openrouter:
            return chatOpenAICompatible(system: system, user: user, useHistory: useHistory, maxTokens: 256)
        }
    }

    // MARK: - Ollama Backend

    private func chatOllama(system: String, user: String, useHistory: Bool = false, maxTokens: Int = 256) -> String? {
        guard let url = URL(string: config.endpoint + "/api/chat") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = config.timeoutSeconds

        var messages: [[String: String]] = [["role": "system", "content": system]]
        if useHistory {
            for turn in conversationBuffer.suffix(maxConversationTurns * 2) {
                messages.append(["role": turn.role, "content": turn.content])
            }
        }
        messages.append(["role": "user", "content": user])

        let body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "stream": false,
            "options": [
                "temperature": 0.3,
                "num_predict": maxTokens
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData

        let box = ResponseBox()
        let sem = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? [String: Any],
               let content = message["content"] as? String {
                box.stringValue = content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            sem.signal()
        }.resume()

        sem.wait()

        if let result = box.stringValue {
            addToConversation(role: "user", content: user)
            addToConversation(role: "assistant", content: result)
        }

        return box.stringValue
    }

    // MARK: - OpenRouter / OpenAI-Compatible Backend

    private func chatOpenAICompatible(system: String, user: String, useHistory: Bool = false, maxTokens: Int = 256) -> String? {
        guard let url = URL(string: config.endpoint + "/chat/completions") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = max(config.timeoutSeconds, 60)

        // Auth header
        if let apiKey = config.apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        // OpenRouter-specific headers
        request.setValue("dodexabash/1.0", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("dodexabash", forHTTPHeaderField: "X-Title")

        var messages: [[String: String]] = [["role": "system", "content": system]]
        if useHistory {
            for turn in conversationBuffer.suffix(maxConversationTurns * 2) {
                messages.append(["role": turn.role, "content": turn.content])
            }
        }
        messages.append(["role": "user", "content": user])

        let body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "max_tokens": maxTokens,
            "temperature": 0.3,
            "stream": false
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData
        
        print("DEBUG: chatOpenAICompatible URL: \(url)")
        print("DEBUG: chatOpenAICompatible model: \(config.model)")

        let box = ResponseBox()
        let sem = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("DEBUG: chatOpenAICompatible transport error: \(error)")
            }
            if let http = response as? HTTPURLResponse {
                if http.statusCode != 200 {
                    print("DEBUG: chatOpenAICompatible HTTP error: \(http.statusCode)")
                }
            }
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // OpenAI format: choices[0].message.content
                if let choices = json["choices"] as? [[String: Any]],
                   let first = choices.first,
                   let message = first["message"] as? [String: Any],
                   let content = message["content"] as? String {
                    box.stringValue = content.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                // Error format
                else if let error = json["error"] as? [String: Any],
                        let message = error["message"] as? String {
                    print("DEBUG: chatOpenAICompatible API error: \(message)")
                    box.stringValue = "[OpenRouter Error] \(message)"
                } else {
                    print("DEBUG: chatOpenAICompatible unknown JSON format: \(json)")
                }
            } else if data != nil {
                print("DEBUG: chatOpenAICompatible failed to parse JSON: \(String(decoding: data!, as: UTF8.self))")
            } else {
                print("DEBUG: chatOpenAICompatible no data received.")
            }
            sem.signal()
        }.resume()

        sem.wait()

        if let result = box.stringValue {
            addToConversation(role: "user", content: user)
            addToConversation(role: "assistant", content: result)
        }

        return box.stringValue
    }

    // MARK: - System Prompt

    private func buildSystemPrompt(
        cwd: String,
        lastStatus: Int32,
        recentHistory: [String],
        activeIntent: String?,
        builtins: [String],
        workspaceBrief: String? = nil,
        activeLeases: Int = 0,
        pendingAttention: Int = 0,
        proofCount: Int = 0,
        lastRepairSummary: String? = nil
    ) -> String {
        var prompt = """
        You are the brain of dodexabash, an AI-native shell on macOS.

        STEP 1 - CLASSIFY the user input as SHELL or NATURAL LANGUAGE:

        SHELL means the user typed an actual command with proper syntax, e.g.:
          ls -la, git status, swift build, echo hello, cd Documents, cat file.txt
        These have a real program name followed by flags or file arguments.

        NATURAL LANGUAGE means the user typed a human question or request, e.g.:
          "who are you", "what is a number", "where do you stay", "list all files",
          "build the project", "show me the git log", "what time is it"
        If the input contains question words (who, what, where, when, why, how),
        pronouns (you, me, I, my, your), or conversational verbs (is, are, do, does, can, should),
        it is almost certainly NATURAL LANGUAGE even if the first word happens to be a command name.

        STEP 2 - RESPOND:
        - If SHELL: output exactly "SHELL" on the first line. Nothing else.
        - If NATURAL LANGUAGE request to DO something: output the shell command, then "// <explanation>".
        - If NATURAL LANGUAGE asking a knowledge QUESTION: output "NOOP" — the shell will answer it separately.
        - "who are you" / "what are you": output "hi" then "// greeting"

        RULES:
        - Output ONLY one of: SHELL, a command, or NOOP on the first line
        - Never wrap in backticks or markdown
        - Commands must be NON-INTERACTIVE (no prompts, no y/n questions, no read from stdin)
        - Use -f or -y flags to force non-interactive behavior
        - For file creation use the "create" builtin: create filename.ext
        - Prefer dodexabash builtins when they fit
        - Never output destructive commands without explicit intent

        DODEXABASH BUILTINS: \(builtins.joined(separator: ", "))

        SPECIALIZED TOOLS (PREFER THESE FOR NATURAL LANGUAGE):
        - Codebase Analysis: use "analyze <domain> [path]"
          Domains: web (UI/Next.js/React), stat (Models/Data), sec (Auth/Crypto), arch (General)
          Example: "tell me what this web app does" -> analyze web .
        - Design System: use "design init" or "design status"
          Example: "setup the visual theme" -> design init
        - Security Recon: use "sec recon <url>"
          Example: "review the public attack surface of example.com" -> policy set security mode:active hard ; sec recon example.com
        - Threat Intelligence: use "sec intel ..."
          Example: "show me defenses for font engine exploitation" -> sec intel mirror ATK-007
        - Multi-Agent Orchestration: use "lead <intent>"
          Example: "audit the web portal and patch vulnerabilities" -> lead "audit the web portal and patch vulnerabilities"
        - Epidemiological Research: use "epi <query>"
          Example: "research dengue trends in Asia" -> epi "impact of urban temperature on dengue incidence in SE Asia"

        RULES:

        - Working directory: \(cwd)
        - Last exit status: \(lastStatus)
        """

        if let intent = activeIntent {
            prompt += "\n- Active intent: \(intent)"
        }

        if !recentHistory.isEmpty {
            prompt += "\n- Recent: \(recentHistory.prefix(5).joined(separator: " ; "))"
        }

        if let brief = workspaceBrief, !brief.isEmpty {
            prompt += "\n- Workspace: \(brief)"
        }

        if activeLeases > 0 { prompt += "\n- Active leases: \(activeLeases)" }
        if pendingAttention > 0 { prompt += "\n- Pending attention: \(pendingAttention)" }
        if proofCount > 0 { prompt += "\n- Proofs recorded: \(proofCount)" }

        if let repair = lastRepairSummary {
            prompt += "\n- Last failure: \(repair)"
        }

        return prompt
    }

    // MARK: - Response Parsing

    private func parseResponse(_ raw: String) -> BrainResponse {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        guard let firstLine = lines.first else {
            return BrainResponse(command: nil, explanation: raw, confidence: 0.1, raw: raw)
        }

        let commandLine = firstLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // SHELL — brain says this is already a valid command, let the shell handle it normally
        if commandLine.uppercased() == "SHELL" {
            return BrainResponse(command: nil, explanation: "pass-through", confidence: 0.0, raw: raw)
        }

        // NOOP — brain understood but can't map to a command
        if commandLine.uppercased().hasPrefix("NOOP") {
            let explanation = lines.dropFirst().joined(separator: " ")
                .replacingOccurrences(of: "//", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return BrainResponse(command: nil, explanation: explanation.isEmpty ? raw : explanation, confidence: 0.3, raw: raw)
        }

        // Extract explanation from second line
        let explanation = lines.dropFirst()
            .first(where: { $0.hasPrefix("//") })
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? "brain-routed command"

        // Confidence based on response characteristics
        var confidence = 0.7
        if commandLine.contains("|") || commandLine.contains(";") { confidence = 0.6 }
        if commandLine.split(separator: " ").count <= 3 { confidence = 0.8 }
        if commandLine.contains("rm ") || commandLine.contains("sudo ") { confidence = 0.4 }

        // Strip any markdown code fencing
        var cleaned = commandLine
        if cleaned.hasPrefix("`") && cleaned.hasSuffix("`") {
            cleaned = String(cleaned.dropFirst().dropLast())
        }

        // Detect if the "command" is actually prose (a direct answer, not a shell command).
        // Real commands are short, start with a word that looks like a program name.
        if looksLikeProse(cleaned) {
            // Brain answered the question directly — return it as explanation, not a command
            return BrainResponse(command: nil, explanation: raw, confidence: 0.8, raw: raw)
        }

        return BrainResponse(command: cleaned, explanation: explanation, confidence: confidence, raw: raw)
    }

    private func looksLikeProse(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        // Too long for a command (most commands are < 10 words)
        if words.count > 12 { return true }
        // Contains sentence-ending punctuation mid-text
        if text.contains(". ") || text.contains("? ") || text.contains("! ") { return true }
        // Starts with a capital letter followed by lowercase (sentence, not a path/command)
        if let first = words.first, first.count > 1 {
            let s = String(first)
            if s.first?.isUppercase == true && s.dropFirst().first?.isLowercase == true {
                // But not known commands that start with uppercase (rare in unix)
                let lower = s.lowercased()
                if !["docker", "python3", "node", "swift", "make", "cmake"].contains(lower) {
                    return true
                }
            }
        }
        // Contains articles/pronouns typical of prose
        let proseWords: Set<String> = ["is", "the", "a", "an", "was", "were", "has", "have", "been", "their", "known"]
        let overlap = Set(words.map { String($0).lowercased() }).intersection(proseWords)
        if overlap.count >= 3 { return true }
        return false
    }

    // MARK: - Conversation Memory

    private var conversationBuffer: [(role: String, content: String)] = []
    private let maxConversationTurns = 10

    private func addToConversation(role: String, content: String) {
        conversationBuffer.append((role: role, content: content))
        if conversationBuffer.count > maxConversationTurns * 2 {
            conversationBuffer.removeFirst(2)
        }
    }

    public func clearConversation() {
        conversationBuffer.removeAll()
    }

    // MARK: - Agent Loop (brain do <task>)

    public struct AgentStep: Codable {
        public let step: Int
        public let thought: String
        public let command: String?
        public let output: String?
        public let status: String  // "running", "done", "error"
    }

    /// Execute a multi-step task autonomously.
    /// The brain plans, executes commands via the shell, observes results, and iterates.
    public func executeTask(
        task: String,
        cwd: String,
        executeCommand: (String) -> (status: Int32, stdout: String, stderr: String),
        maxSteps: Int = 10
    ) -> [AgentStep] {
        guard config.enabled, isAvailable() else { return [] }

        var steps: [AgentStep] = []
        var context = "Task: \(task)\nWorking directory: \(cwd)\n"

        let system = """
        You are an autonomous agent inside dodexabash shell on macOS. \
        You must complete the given task by executing shell commands one at a time.

        For each step, output EXACTLY this format:
        THOUGHT: <what you're doing and why>
        COMMAND: <the shell command to run>

        When the task is complete, output:
        THOUGHT: <summary of what was done>
        DONE

        Rules:
        - One command per step. Wait for the result before deciding the next step.
        - Use dodexabash builtins: create, open, tree, brief, cd, echo, etc.
        - Commands must be non-interactive (no prompts, no y/n)
        - Never run destructive commands without the task explicitly asking for it
        - If a command fails, diagnose and try a different approach
        - Maximum \(maxSteps) steps
        """

        for stepNum in 1...maxSteps {
            guard let response = chat(system: system, user: context, useHistory: false) else {
                steps.append(AgentStep(step: stepNum, thought: "Brain did not respond", command: nil, output: nil, status: "error"))
                break
            }

            let parsed = parseAgentResponse(response)

            if parsed.done {
                steps.append(AgentStep(step: stepNum, thought: parsed.thought, command: nil, output: nil, status: "done"))
                break
            }

            guard let command = parsed.command else {
                steps.append(AgentStep(step: stepNum, thought: parsed.thought, command: nil, output: nil, status: "error"))
                break
            }

            // Execute the command
            let result = executeCommand(command)
            let output = result.stdout + result.stderr
            let truncatedOutput = output.count > 500 ? String(output.prefix(500)) + "..." : output

            steps.append(AgentStep(
                step: stepNum,
                thought: parsed.thought,
                command: command,
                output: truncatedOutput,
                status: result.status == 0 ? "running" : "error"
            ))

            // Feed result back into context
            context += "\nStep \(stepNum):\n"
            context += "Command: \(command)\n"
            context += "Exit status: \(result.status)\n"
            context += "Output: \(truncatedOutput)\n"
        }

        return steps
    }

    private struct AgentParsedResponse {
        let thought: String
        let command: String?
        let done: Bool
    }

    private func parseAgentResponse(_ raw: String) -> AgentParsedResponse {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var thought = ""
        var command: String?
        var done = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("THOUGHT:") {
                thought = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.uppercased().hasPrefix("COMMAND:") {
                let cmd = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "`", with: "")
                if !cmd.isEmpty { command = cmd }
            } else if trimmed.uppercased() == "DONE" {
                done = true
            }
        }

        return AgentParsedResponse(thought: thought, command: command, done: done)
    }

    // MARK: - Persistence

    private func saveConfig() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: configURL, options: .atomic)
    }

    private static func loadConfig(from url: URL) -> BrainConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(BrainConfig.self, from: data) else {
            return .default
        }
        return config
    }
}
