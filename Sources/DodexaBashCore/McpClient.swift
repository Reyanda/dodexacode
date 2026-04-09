import Foundation

// MARK: - MCP Client: Consume external MCP servers
// This is the inverse of McpServer.swift — instead of exposing dodexabash tools TO external
// clients, this lets dodexabash CALL tools from external MCP servers (GitHub, filesystem,
// databases, custom APIs, etc.)

// MARK: - Configuration

public struct McpServerConfig: Codable, Sendable {
    public let name: String
    public let command: String          // e.g. "npx", "python3", "node"
    public let args: [String]           // e.g. ["-y", "@modelcontextprotocol/server-github"]
    public let env: [String: String]?   // extra environment variables
    public let enabled: Bool

    public init(name: String, command: String, args: [String], env: [String: String]? = nil, enabled: Bool = true) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.enabled = enabled
    }
}

public struct McpClientConfig: Codable, Sendable {
    public var servers: [McpServerConfig]

    public static let empty = McpClientConfig(servers: [])
}

// MARK: - MCP Tool Definition (from remote servers)

public struct McpToolDefinition: Codable, Sendable {
    public let name: String
    public let description: String?
    public let inputSchema: McpToolSchema?
}

public struct McpToolSchema: Codable, Sendable {
    public let type: String?
    public let properties: [String: McpSchemaProperty]?
    public let required: [String]?
}

public struct McpSchemaProperty: Codable, Sendable {
    public let type: String?
    public let description: String?
}

// MARK: - MCP Tool Call Result

public struct McpToolResult: Sendable {
    public let content: String
    public let isError: Bool
}

// MARK: - Connected Server

private final class ConnectedServer: @unchecked Sendable {
    let config: McpServerConfig
    let process: Process
    let stdin: Pipe
    let stdout: Pipe
    var tools: [McpToolDefinition] = []
    var requestId: Int = 0
    var buffer = Data()

    init(config: McpServerConfig, process: Process, stdin: Pipe, stdout: Pipe) {
        self.config = config
        self.process = process
        self.stdin = stdin
        self.stdout = stdout
    }

    func nextRequestId() -> Int {
        requestId += 1
        return requestId
    }
}

// MARK: - MCP Client

public final class McpClient: @unchecked Sendable {
    private let configURL: URL
    private var config: McpClientConfig
    private var servers: [String: ConnectedServer] = [:]

    public init(directory: URL) {
        self.configURL = directory.appendingPathComponent("mcp.json")
        self.config = McpClient.loadConfig(from: configURL)
    }

    // MARK: - Server Lifecycle

    public func connectAll() {
        for serverConfig in config.servers where serverConfig.enabled {
            connect(serverConfig)
        }
    }

    public func connect(_ serverConfig: McpServerConfig) {
        guard servers[serverConfig.name] == nil else { return }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        // Resolve command
        let resolvedCommand: String
        if serverConfig.command.contains("/") {
            resolvedCommand = serverConfig.command
        } else {
            // Search PATH
            let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/usr/local/bin").split(separator: ":")
            var found: String?
            for dir in pathDirs {
                let candidate = String(dir) + "/" + serverConfig.command
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    found = candidate
                    break
                }
            }
            resolvedCommand = found ?? serverConfig.command
        }

        process.executableURL = URL(fileURLWithPath: resolvedCommand)
        process.arguments = serverConfig.args
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var env = ProcessInfo.processInfo.environment
        if let extra = serverConfig.env {
            for (key, value) in extra {
                env[key] = value
            }
        }
        process.environment = env

        do {
            try process.run()
        } catch {
            return
        }

        let server = ConnectedServer(
            config: serverConfig,
            process: process,
            stdin: stdinPipe,
            stdout: stdoutPipe
        )
        servers[serverConfig.name] = server

        // Initialize the MCP connection
        _ = initialize(server: server)
        // Discover available tools
        discoverTools(server: server)
    }

    public func disconnect(_ name: String) {
        guard let server = servers.removeValue(forKey: name) else { return }
        if server.process.isRunning {
            server.process.terminate()
        }
    }

    public func disconnectAll() {
        for name in servers.keys {
            disconnect(name)
        }
    }

    // MARK: - Tool Discovery

    public var allTools: [(server: String, tool: McpToolDefinition)] {
        var result: [(String, McpToolDefinition)] = []
        for (name, server) in servers {
            for tool in server.tools {
                result.append((name, tool))
            }
        }
        return result
    }

    public func tools(forServer name: String) -> [McpToolDefinition] {
        servers[name]?.tools ?? []
    }

    public var connectedServers: [String] {
        Array(servers.keys.sorted())
    }

    public func serverStatus() -> [(name: String, connected: Bool, toolCount: Int)] {
        config.servers.map { cfg in
            let server = servers[cfg.name]
            return (cfg.name, server?.process.isRunning ?? false, server?.tools.count ?? 0)
        }
    }

    // MARK: - Tool Calling

    public func callTool(server serverName: String, tool: String, arguments: [String: Any]) -> McpToolResult? {
        guard let server = servers[serverName], server.process.isRunning else {
            return McpToolResult(content: "Server '\(serverName)' not connected", isError: true)
        }

        let reqId = server.nextRequestId()
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": reqId,
            "method": "tools/call",
            "params": [
                "name": tool,
                "arguments": arguments
            ]
        ]

        guard let response = sendRequest(request, to: server) else {
            return McpToolResult(content: "No response from server", isError: true)
        }

        // Parse result
        if let error = response["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown error"
            return McpToolResult(content: message, isError: true)
        }

        guard let result = response["result"] as? [String: Any] else {
            return McpToolResult(content: "Invalid response format", isError: true)
        }

        let isError = result["isError"] as? Bool ?? false
        if let content = result["content"] as? [[String: Any]] {
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return McpToolResult(content: text, isError: isError)
        }

        return McpToolResult(content: "Empty result", isError: false)
    }

    /// Call a tool using "server.tool" notation
    public func callTool(qualifiedName: String, arguments: [String: Any]) -> McpToolResult? {
        let parts = qualifiedName.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else {
            // Try to find the tool in any connected server
            for (name, server) in servers {
                if server.tools.contains(where: { $0.name == qualifiedName }) {
                    return callTool(server: name, tool: qualifiedName, arguments: arguments)
                }
            }
            return McpToolResult(content: "Tool '\(qualifiedName)' not found", isError: true)
        }
        return callTool(server: String(parts[0]), tool: String(parts[1]), arguments: arguments)
    }

    // MARK: - JSON-RPC Communication

    private func initialize(server: ConnectedServer) -> Bool {
        let reqId = server.nextRequestId()
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": reqId,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [
                    "roots": ["listChanged": true]
                ],
                "clientInfo": [
                    "name": "dodexabash",
                    "version": "1.0.0"
                ]
            ]
        ]

        guard let response = sendRequest(request, to: server),
              response["result"] != nil else {
            return false
        }

        // Send initialized notification
        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        ]
        sendNotification(notification, to: server)
        return true
    }

    private func discoverTools(server: ConnectedServer) {
        let reqId = server.nextRequestId()
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": reqId,
            "method": "tools/list",
            "params": [String: Any]()
        ]

        guard let response = sendRequest(request, to: server),
              let result = response["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            return
        }

        server.tools = tools.compactMap { toolDict -> McpToolDefinition? in
            guard let name = toolDict["name"] as? String else { return nil }
            let description = toolDict["description"] as? String

            var schema: McpToolSchema?
            if let inputSchema = toolDict["inputSchema"] as? [String: Any] {
                let type = inputSchema["type"] as? String
                let required = inputSchema["required"] as? [String]
                var properties: [String: McpSchemaProperty]?
                if let props = inputSchema["properties"] as? [String: [String: Any]] {
                    properties = [:]
                    for (key, value) in props {
                        properties?[key] = McpSchemaProperty(
                            type: value["type"] as? String,
                            description: value["description"] as? String
                        )
                    }
                }
                schema = McpToolSchema(type: type, properties: properties, required: required)
            }

            return McpToolDefinition(name: name, description: description, inputSchema: schema)
        }
    }

    private func sendRequest(_ request: [String: Any], to server: ConnectedServer) -> [String: Any]? {
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              server.process.isRunning else {
            return nil
        }

        var message = data
        message.append(contentsOf: "\n".utf8)

        do {
            try server.stdin.fileHandleForWriting.write(contentsOf: message)
        } catch {
            return nil
        }

        // Read response with timeout
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let available = server.stdout.fileHandleForReading.availableData
            if !available.isEmpty {
                server.buffer.append(available)
                // Try to parse a complete JSON line
                if let newlineRange = server.buffer.range(of: Data("\n".utf8)) {
                    let lineData = server.buffer[server.buffer.startIndex..<newlineRange.lowerBound]
                    server.buffer.removeSubrange(server.buffer.startIndex...newlineRange.lowerBound)
                    if let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                        return json
                    }
                }
            } else {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        return nil
    }

    private func sendNotification(_ notification: [String: Any], to server: ConnectedServer) {
        guard let data = try? JSONSerialization.data(withJSONObject: notification),
              server.process.isRunning else { return }
        var message = data
        message.append(contentsOf: "\n".utf8)
        try? server.stdin.fileHandleForWriting.write(contentsOf: message)
    }

    // MARK: - Config

    public func addServer(_ serverConfig: McpServerConfig) {
        config.servers.removeAll { $0.name == serverConfig.name }
        config.servers.append(serverConfig)
        saveConfig()
    }

    public func removeServer(_ name: String) {
        disconnect(name)
        config.servers.removeAll { $0.name == name }
        saveConfig()
    }

    private func saveConfig() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: configURL, options: .atomic)
    }

    private static func loadConfig(from url: URL) -> McpClientConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(McpClientConfig.self, from: data) else {
            return .empty
        }
        return config
    }
}
