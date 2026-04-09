import Foundation

public struct ToolDefinition {
    public let name: String
    public let description: String
    public let inputSchema: [String: JSONValue]
    public let annotations: [String: JSONValue]
    public let handler: ([String: JSONValue]) -> [String: JSONValue]

    public init(
        name: String,
        description: String,
        inputSchema: [String: JSONValue],
        annotations: [String: JSONValue] = [:],
        handler: @escaping ([String: JSONValue]) -> [String: JSONValue]
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.handler = handler
    }

    public func descriptor() -> [String: JSONValue] {
        [
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .object(inputSchema),
            "annotations": .object(annotations)
        ]
    }
}

public enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .integer(let value): return value
        case .number(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public static func fromEncodable<T: Encodable>(_ value: T) -> JSONValue {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(AnyEncodable(value)),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .null
        }
        return decoded
    }
}

public final class DodexaMcpServer {
    public static let defaultProtocolVersion = "2024-11-05"

    private let shell: Shell
    private let tools: [String: ToolDefinition]

    public init(shell: Shell) {
        self.shell = shell
        let definitions = DodexaMcpServer.makeTools(shell: shell)
        self.tools = Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) })
    }

    public func handle(_ message: [String: JSONValue]) -> [String: JSONValue]? {
        let method = message["method"]?.stringValue ?? ""
        let requestId = message["id"] ?? .null
        let params = message["params"]?.objectValue ?? [:]

        switch method {
        case "initialize":
            let requestedProtocol = params["protocolVersion"]?.stringValue ?? Self.defaultProtocolVersion
            return [
                "jsonrpc": .string("2.0"),
                "id": requestId,
                "result": .object([
                    "protocolVersion": .string(requestedProtocol),
                    "capabilities": .object(["tools": .object([:])]),
                    "serverInfo": .object([
                        "name": .string("dodexabash"),
                        "version": .string("0.1.0")
                    ])
                ])
            ]
        case "notifications/initialized":
            return nil
        case "ping":
            return [
                "jsonrpc": .string("2.0"),
                "id": requestId,
                "result": .object([:])
            ]
        case "tools/list":
            return [
                "jsonrpc": .string("2.0"),
                "id": requestId,
                "result": .object([
                    "tools": .array(tools.values.sorted { $0.name < $1.name }.map { .object($0.descriptor()) })
                ])
            ]
        case "tools/call":
            let name = params["name"]?.stringValue ?? ""
            let arguments = params["arguments"]?.objectValue ?? [:]
            guard let tool = tools[name] else {
                return Self.errorResponse(id: requestId, code: -32602, message: "Unknown tool: \(name)")
            }
            let payload = tool.handler(arguments)
            return [
                "jsonrpc": .string("2.0"),
                "id": requestId,
                "result": .object(payload)
            ]
        default:
            return Self.errorResponse(id: requestId, code: -32601, message: "Unsupported method: \(method)")
        }
    }

    public func serve(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        while let message = Self.readMessage(from: input) {
            if let response = handle(message) {
                Self.writeMessage(response, to: output)
            }
        }
    }

    public static func readMessage(from input: FileHandle = .standardInput) -> [String: JSONValue]? {
        var headers: [String: String] = [:]
        while true {
            guard let rawLine = readHeaderLine(from: input) else {
                return nil
            }
            if rawLine.isEmpty {
                let contentLength = Int(headers["content-length"] ?? "") ?? 0
                guard contentLength > 0,
                      let bodyData = readExactly(contentLength, from: input) else {
                    return nil
                }
                return try? JSONDecoder().decode([String: JSONValue].self, from: bodyData)
            }

            let pair = rawLine.split(separator: ":", maxSplits: 1).map(String.init)
            if pair.count == 2 {
                headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
            }
        }
    }

    public static func writeMessage(_ message: [String: JSONValue], to output: FileHandle = .standardOutput) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(message) else {
            return
        }
        let header = "Content-Length: \(body.count)\r\n\r\n"
        output.write(Data(header.utf8))
        output.write(body)
    }

    public static func toolText(_ payload: [String: JSONValue], isError: Bool = false) -> [String: JSONValue] {
        let text = prettyJSONString(payload)
        return [
            "content": .array([.object([
                "type": .string("text"),
                "text": .string(text)
            ])]),
            "structuredContent": .object(payload),
            "isError": .bool(isError)
        ]
    }

    private static func errorResponse(id: JSONValue, code: Int, message: String) -> [String: JSONValue] {
        [
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .integer(code),
                "message": .string(message)
            ])
        ]
    }

    private static func prettyJSONString(_ payload: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func makeTools(shell: Shell) -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "dodexabash_run",
                description: "Run a dodexabash command string through the shell parser and return status, stdout, and stderr.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "source": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("source")])
                ],
                annotations: [
                    "readOnlyHint": .bool(false),
                    "riskLevel": .string("medium"),
                    "tags": .array([.string("execution"), .string("shell"), .string("mutable")])
                ],
                handler: { arguments in
                    let source = arguments["source"]?.stringValue ?? ""
                    let result = shell.run(source: source)
                    return toolResult(toolName: "dodexabash_run", payload: [
                        "status": .integer(Int(result.status)),
                        "stdout": .string(result.stdout),
                        "stderr": .string(result.stderr),
                        "shouldExit": .bool(result.shouldExit)
                    ], isError: result.status != 0)
                }
            ),
            ToolDefinition(
                name: "dodexabash_route_intent",
                description: "Route an intent without executing it. Returns workflow matches, workspace brief fingerprint, predicted next actions, and suggested tools.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "intent": .object(["type": .string("string")]),
                        "workspace": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("intent")])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("planning"), .string("routing"), .string("future-shell")])
                ],
                handler: { arguments in
                    let intent = arguments["intent"]?.stringValue ?? ""
                    let workspace = arguments["workspace"]?.stringValue ?? shell.context.currentDirectory
                    let brief = shell.workspaceBriefer.generate(atPath: workspace)
                    let workflows = shell.workflowLibrary.match(query: intent, limit: 3)
                    let predictions = shell.sessionStore.predictions(seedCommand: intent, limit: 3)
                    let suggestedTools = suggestedTools(for: intent)
                    return toolResult(toolName: "dodexabash_route_intent", payload: [
                        "intent": .string(intent),
                        "workspace": .string(workspace),
                        "workspaceFingerprint": .string(brief.fingerprint),
                        "compactBrief": .string(brief.compactText),
                        "workflowMatches": .fromEncodable(workflows),
                        "predictions": .fromEncodable(predictions),
                        "suggestedTools": .array(suggestedTools.map(JSONValue.string)),
                        "mutationRisk": .string(mutationRisk(for: intent)),
                        "timeHorizon": .string("immediate"),
                        "intentClass": .string(intentClass(for: intent))
                    ])
                }
            ),
            ToolDefinition(
                name: "dodexabash_brief",
                description: "Generate a compact workspace brief with language mix, symbol counts, key files, and recent edits.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string")])
                    ])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("context"), .string("workspace"), .string("briefing")])
                ],
                handler: { arguments in
                    let path = arguments["path"]?.stringValue ?? shell.context.currentDirectory
                    let brief = shell.workspaceBriefer.generate(atPath: path)
                    return toolResult(toolName: "dodexabash_brief", payload: ["brief": .fromEncodable(brief)])
                }
            ),
            ToolDefinition(
                name: "dodexabash_history",
                description: "Return structured local command history with cwd, duration, status, and previews.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "limit": .object(["type": .string("integer")])
                    ])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("history"), .string("memory"), .string("session")])
                ],
                handler: { arguments in
                    let limit = max(1, arguments["limit"]?.intValue ?? 20)
                    let traces = shell.sessionStore.recent(limit: limit)
                    return toolResult(toolName: "dodexabash_history", payload: ["traces": .fromEncodable(traces)])
                }
            ),
            ToolDefinition(
                name: "dodexabash_predict",
                description: "Suggest likely next commands from local session memory and heuristic operator rules.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "seed_command": .object(["type": .string("string")]),
                        "limit": .object(["type": .string("integer")])
                    ])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("prediction"), .string("scheduler"), .string("memory")])
                ],
                handler: { arguments in
                    let seed = arguments["seed_command"]?.stringValue
                    let limit = max(1, arguments["limit"]?.intValue ?? 4)
                    let predictions = shell.sessionStore.predictions(seedCommand: seed, limit: limit)
                    return toolResult(toolName: "dodexabash_predict", payload: ["predictions": .fromEncodable(predictions)])
                }
            ),
            ToolDefinition(
                name: "dodexabash_workflow_match",
                description: "Match a task or query against built-in workflow cards for debugging, verification, and release work.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string")]),
                        "limit": .object(["type": .string("integer")])
                    ]),
                    "required": .array([.string("query")])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("workflow"), .string("planning"), .string("routing")])
                ],
                handler: { arguments in
                    let query = arguments["query"]?.stringValue ?? ""
                    let limit = max(1, arguments["limit"]?.intValue ?? 4)
                    let matches = shell.workflowLibrary.match(query: query, limit: limit)
                    return toolResult(toolName: "dodexabash_workflow_match", payload: ["matches": .fromEncodable(matches)])
                }
            ),
            ToolDefinition(
                name: "dodexabash_workflow_list",
                description: "List built-in workflow cards exposed by dodexabash.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([:])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("workflow"), .string("catalog")])
                ],
                handler: { _ in
                    return toolResult(toolName: "dodexabash_workflow_list", payload: ["workflows": .fromEncodable(shell.workflowLibrary.listCards())])
                }
            ),
            ToolDefinition(
                name: "dodexabash_plugins_list",
                description: "Scan workspace plugin roots and list Codex plugin manifests for integration into existing flows.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "workspace": .object(["type": .string("string")])
                    ])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("plugins"), .string("integration"), .string("workspace")])
                ],
                handler: { arguments in
                    let workspace = arguments["workspace"]?.stringValue ?? shell.context.currentDirectory
                    let manifests = SystemTools.discoverPluginManifests(workspace: workspace)
                    return toolResult(toolName: "dodexabash_plugins_list", payload: ["plugins": .fromEncodable(manifests)])
                }
            ),
            ToolDefinition(
                name: "dodexabash_system_snapshot",
                description: "Return a low-level system snapshot useful for kernel-adjacent or assembly-level operator context.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([:])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("system"), .string("kernel-context"), .string("platform")])
                ],
                handler: { _ in
                    let snapshot = SystemTools.captureSystemSnapshot(cwd: shell.context.currentDirectory)
                    return toolResult(toolName: "dodexabash_system_snapshot", payload: ["system": .fromEncodable(snapshot)])
                }
            ),
            ToolDefinition(
                name: "dodexabash_binary_info",
                description: "Inspect a Mach-O or other local binary with file type, Mach header, and linked libraries.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("path")])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("binary"), .string("mach-o"), .string("inspection")])
                ],
                handler: { arguments in
                    let path = arguments["path"]?.stringValue ?? ""
                    let info = SystemTools.inspectBinary(path: path)
                    return toolResult(toolName: "dodexabash_binary_info", payload: ["binary": .fromEncodable(info)])
                }
            ),
            ToolDefinition(
                name: "dodexabash_binary_symbols",
                description: "List binary symbols using nm for low-level analysis and LLM tool use.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string")]),
                        "limit": .object(["type": .string("integer")])
                    ]),
                    "required": .array([.string("path")])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("binary"), .string("symbols"), .string("assembly")])
                ],
                handler: { arguments in
                    let path = arguments["path"]?.stringValue ?? ""
                    let limit = max(1, arguments["limit"]?.intValue ?? 120)
                    let result = SystemTools.binarySymbols(path: path, limit: limit)
                    return toolResult(toolName: "dodexabash_binary_symbols", payload: [
                        "command": .fromEncodable(result.command),
                        "status": .integer(Int(result.status)),
                        "stdout": .string(result.stdout),
                        "stderr": .string(result.stderr)
                    ], isError: result.status != 0)
                }
            ),
            ToolDefinition(
                name: "dodexabash_disassemble",
                description: "Disassemble a local binary using otool for assembly-level inspection. Optional symbol filter narrows the output.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string")]),
                        "symbol": .object(["type": .string("string")]),
                        "limit": .object(["type": .string("integer")])
                    ]),
                    "required": .array([.string("path")])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("binary"), .string("disassembly"), .string("assembly")])
                ],
                handler: { arguments in
                    let path = arguments["path"]?.stringValue ?? ""
                    let symbol = arguments["symbol"]?.stringValue
                    let limit = max(1, arguments["limit"]?.intValue ?? 160)
                    let result = SystemTools.disassemble(path: path, symbol: symbol, limit: limit)
                    return toolResult(toolName: "dodexabash_disassemble", payload: [
                        "command": .fromEncodable(result.command),
                        "status": .integer(Int(result.status)),
                        "stdout": .string(result.stdout),
                        "stderr": .string(result.stderr)
                    ], isError: result.status != 0)
                }
            ),
            ToolDefinition(
                name: "dodexabash_md_parse",
                description: "Parse a Markdown file into native section, bullet, and code-block structure without external parser dependencies.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("path")])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("markdown"), .string("document"), .string("parsing")])
                ],
                handler: { arguments in
                    let path = arguments["path"]?.stringValue ?? ""
                    do {
                        let document = try MarkdownNative.load(from: path, cwd: shell.context.currentDirectory)
                        return toolResult(toolName: "dodexabash_md_parse", payload: ["document": .fromEncodable(document)])
                    } catch {
                        return toolResult(toolName: "dodexabash_md_parse", payload: ["error": .string(String(describing: error))], isError: true)
                    }
                }
            ),
            ToolDefinition(
                name: "dodexabash_md_section",
                description: "Extract a specific Markdown section by heading, slug, or heading path from a local Markdown file.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string")]),
                        "heading": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("path"), .string("heading")])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("markdown"), .string("document"), .string("section")])
                ],
                handler: { arguments in
                    let path = arguments["path"]?.stringValue ?? ""
                    let heading = arguments["heading"]?.stringValue ?? ""
                    do {
                        let document = try MarkdownNative.load(from: path, cwd: shell.context.currentDirectory)
                        guard let section = MarkdownNative.findSection(in: document, matching: heading) else {
                            return toolResult(toolName: "dodexabash_md_section", payload: ["error": .string("section not found: \(heading)")], isError: true)
                        }
                        return toolResult(toolName: "dodexabash_md_section", payload: [
                            "section": .fromEncodable(section),
                            "documentTitle": .string(document.title)
                        ])
                    } catch {
                        return toolResult(toolName: "dodexabash_md_section", payload: ["error": .string(String(describing: error))], isError: true)
                    }
                }
            ),
            ToolDefinition(
                name: "dodexabash_md_ingest",
                description: "Ingest a Markdown file into the runtime artifact store as a typed markdown artifact with source provenance.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object(["type": .string("string")]),
                        "label": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("path")])
                ],
                annotations: [
                    "readOnlyHint": .bool(false),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("markdown"), .string("artifact"), .string("ingest")])
                ],
                handler: { arguments in
                    let path = arguments["path"]?.stringValue ?? ""
                    let resolved = MarkdownNative.resolve(path: path, cwd: shell.context.currentDirectory)
                    guard let source = try? String(contentsOfFile: resolved, encoding: .utf8) else {
                        return toolResult(toolName: "dodexabash_md_ingest", payload: ["error": .string("could not read \(resolved)")], isError: true)
                    }
                    let document = MarkdownNative.parse(source, path: resolved)
                    let label = arguments["label"]?.stringValue ?? URL(fileURLWithPath: resolved).lastPathComponent
                    let artifact = shell.runtimeStore.createArtifact(
                        kind: .markdown,
                        label: label,
                        content: source,
                        sourceFile: resolved,
                        tags: ["markdown", "document"] + document.sections.prefix(4).map(\.slug)
                    )
                    return toolResult(toolName: "dodexabash_md_ingest", payload: [
                        "document": .fromEncodable(document),
                        "artifact": .fromEncodable(artifact)
                    ])
                }
            ),

            // MARK: - Future Runtime Tools

            ToolDefinition(
                name: "dodexabash_artifact_list",
                description: "List typed artifact envelopes stored in the runtime. Artifacts carry provenance, content hashes, and policy tags.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "limit": .object(["type": .string("integer")])
                    ])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("artifact"), .string("future-shell"), .string("provenance")])
                ],
                handler: { arguments in
                    let limit = max(1, arguments["limit"]?.intValue ?? 20)
                    let items = Array(shell.runtimeStore.artifacts.suffix(limit))
                    return toolResult(toolName: "dodexabash_artifact_list", payload: ["artifacts": .fromEncodable(items)])
                }
            ),
            ToolDefinition(
                name: "dodexabash_artifact_create",
                description: "Create a typed artifact envelope with kind, label, content, provenance tracking, and optional policy tags.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "label": .object(["type": .string("string")]),
                        "kind": .object(["type": .string("string")]),
                        "content": .object(["type": .string("string")]),
                        "tags": .object(["type": .string("array"), "items": .object(["type": .string("string")])])
                    ]),
                    "required": .array([.string("label"), .string("content")])
                ],
                annotations: [
                    "readOnlyHint": .bool(false),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("artifact"), .string("future-shell"), .string("create")])
                ],
                handler: { arguments in
                    let label = arguments["label"]?.stringValue ?? "unnamed"
                    let kindStr = arguments["kind"]?.stringValue ?? "text"
                    let content = arguments["content"]?.stringValue ?? ""
                    let kind = ArtifactKind(rawValue: kindStr) ?? .text
                    let a = shell.runtimeStore.createArtifact(kind: kind, label: label, content: content)
                    return toolResult(toolName: "dodexabash_artifact_create", payload: ["artifact": .fromEncodable(a)])
                }
            ),
            ToolDefinition(
                name: "dodexabash_intent_set",
                description: "Declare an intent contract: what the agent is trying to achieve, what it may mutate, and how to verify success.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "statement": .object(["type": .string("string")]),
                        "reason": .object(["type": .string("string")]),
                        "mutations": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                        "success_criteria": .object(["type": .string("string")]),
                        "risk_level": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("statement")])
                ],
                annotations: [
                    "readOnlyHint": .bool(false),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("intent"), .string("future-shell"), .string("planning")])
                ],
                handler: { arguments in
                    let statement = arguments["statement"]?.stringValue ?? ""
                    let reason = arguments["reason"]?.stringValue
                    let riskStr = arguments["risk_level"]?.stringValue ?? "medium"
                    let risk = RiskLevel(rawValue: riskStr) ?? .medium
                    let intent = shell.runtimeStore.setIntent(
                        statement: statement, reason: reason, riskLevel: risk
                    )
                    return toolResult(toolName: "dodexabash_intent_set", payload: ["intent": .fromEncodable(intent)])
                }
            ),
            ToolDefinition(
                name: "dodexabash_intent_get",
                description: "Get the currently active intent contract, if any.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([:])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("intent"), .string("future-shell")])
                ],
                handler: { _ in
                    if let intent = shell.runtimeStore.activeIntent {
                        return toolResult(toolName: "dodexabash_intent_get", payload: ["intent": .fromEncodable(intent), "active": .bool(true)])
                    }
                    return toolResult(toolName: "dodexabash_intent_get", payload: ["active": .bool(false)])
                }
            ),
            ToolDefinition(
                name: "dodexabash_lease_grant",
                description: "Grant a scoped, time-limited capability lease for a specific resource. Leases auto-expire after TTL.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "capability": .object(["type": .string("string")]),
                        "resource": .object(["type": .string("string")]),
                        "grantee": .object(["type": .string("string")]),
                        "actions": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                        "ttl_seconds": .object(["type": .string("integer")])
                    ]),
                    "required": .array([.string("capability"), .string("resource")])
                ],
                annotations: [
                    "readOnlyHint": .bool(false),
                    "riskLevel": .string("medium"),
                    "tags": .array([.string("lease"), .string("capability"), .string("security"), .string("future-shell")])
                ],
                handler: { arguments in
                    let capability = arguments["capability"]?.stringValue ?? ""
                    let resource = arguments["resource"]?.stringValue ?? ""
                    let grantee = arguments["grantee"]?.stringValue ?? "agent"
                    let ttl = arguments["ttl_seconds"]?.intValue ?? 300
                    let lease = shell.runtimeStore.grantLease(
                        capability: capability, resource: resource, grantee: grantee, ttlSeconds: ttl
                    )
                    return toolResult(toolName: "dodexabash_lease_grant", payload: ["lease": .fromEncodable(lease)])
                }
            ),
            ToolDefinition(
                name: "dodexabash_lease_list",
                description: "List active (non-expired, non-revoked) capability leases.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([:])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("lease"), .string("capability"), .string("future-shell")])
                ],
                handler: { _ in
                    let active = shell.runtimeStore.activeLeases()
                    return toolResult(toolName: "dodexabash_lease_list", payload: ["leases": .fromEncodable(active), "count": .integer(active.count)])
                }
            ),
            ToolDefinition(
                name: "dodexabash_simulate",
                description: "Simulate a command without executing it. Returns predicted effects, risk assessment, rollback path, and alternatives.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "command": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("command")])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("simulate"), .string("counterfactual"), .string("future-shell"), .string("safety")])
                ],
                handler: { arguments in
                    let command = arguments["command"]?.stringValue ?? ""
                    let report = shell.runtimeStore.simulate(command: command)
                    return toolResult(toolName: "dodexabash_simulate", payload: ["report": .fromEncodable(report)])
                }
            ),
            ToolDefinition(
                name: "dodexabash_prove_last",
                description: "Return the most recent proof envelope with evidence chain, confidence, and replay token.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([:])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("proof"), .string("provenance"), .string("future-shell")])
                ],
                handler: { _ in
                    if let proof = shell.runtimeStore.lastProof() {
                        return toolResult(toolName: "dodexabash_prove_last", payload: ["proof": .fromEncodable(proof)])
                    }
                    return toolResult(toolName: "dodexabash_prove_last", payload: ["proof": .null])
                }
            ),
            ToolDefinition(
                name: "dodexabash_entity_list",
                description: "List entity handles — latent object references with multimodal views.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "limit": .object(["type": .string("integer")])
                    ])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("entity"), .string("handle"), .string("future-shell")])
                ],
                handler: { arguments in
                    let limit = max(1, arguments["limit"]?.intValue ?? 20)
                    let items = Array(shell.runtimeStore.entities.suffix(limit))
                    return toolResult(toolName: "dodexabash_entity_list", payload: ["entities": .fromEncodable(items)])
                }
            ),
            ToolDefinition(
                name: "dodexabash_attention_list",
                description: "List pending attention events ranked by priority. Attention events are structured interrupts from the runtime.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([:])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("attention"), .string("interrupt"), .string("future-shell")])
                ],
                handler: { _ in
                    let pending = shell.runtimeStore.pendingAttention()
                    return toolResult(toolName: "dodexabash_attention_list", payload: [
                        "events": .fromEncodable(pending),
                        "count": .integer(pending.count)
                    ])
                }
            ),
            ToolDefinition(
                name: "dodexabash_attention_push",
                description: "Push a new attention event into the queue with a priority level.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "priority": .object(["type": .string("string")]),
                        "source": .object(["type": .string("string")]),
                        "summary": .object(["type": .string("string")]),
                        "detail": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("summary")])
                ],
                annotations: [
                    "readOnlyHint": .bool(false),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("attention"), .string("interrupt"), .string("future-shell")])
                ],
                handler: { arguments in
                    let priorityStr = arguments["priority"]?.stringValue ?? "normal"
                    let priority = AttentionPriority(rawValue: priorityStr) ?? .normal
                    let source = arguments["source"]?.stringValue ?? "mcp"
                    let summary = arguments["summary"]?.stringValue ?? ""
                    let detail = arguments["detail"]?.stringValue
                    let event = shell.runtimeStore.pushAttention(priority: priority, source: source, summary: summary, detail: detail)
                    return toolResult(toolName: "dodexabash_attention_push", payload: ["event": .fromEncodable(event)])
                }
            ),
            ToolDefinition(
                name: "dodexabash_policy_get",
                description: "Get the active policy envelope with enforcement rules for privacy, budget, locality, and audit.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([:])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("policy"), .string("governance"), .string("future-shell")])
                ],
                handler: { _ in
                    if let policy = shell.runtimeStore.activePolicy {
                        return toolResult(toolName: "dodexabash_policy_get", payload: ["policy": .fromEncodable(policy), "active": .bool(true)])
                    }
                    return toolResult(toolName: "dodexabash_policy_get", payload: ["active": .bool(false)])
                }
            ),
            ToolDefinition(
                name: "dodexabash_world_snapshot",
                description: "Build a world graph from the workspace: files, directories, and their relationships as inspectable nodes.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "workspace": .object(["type": .string("string")])
                    ])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("world"), .string("graph"), .string("future-shell"), .string("context")])
                ],
                handler: { arguments in
                    let workspace = arguments["workspace"]?.stringValue ?? shell.context.currentDirectory
                    let nodes = shell.runtimeStore.buildWorldSnapshot(workspace: workspace)
                    let dirs = nodes.filter { $0.kind == "directory" }.count
                    let files = nodes.filter { $0.kind == "file" }.count
                    return toolResult(toolName: "dodexabash_world_snapshot", payload: [
                        "nodes": .fromEncodable(nodes),
                        "summary": .object([
                            "totalNodes": .integer(nodes.count),
                            "directories": .integer(dirs),
                            "files": .integer(files)
                        ])
                    ])
                }
            ),
            ToolDefinition(
                name: "dodexabash_uncertainty_assess",
                description: "Assess the current uncertainty surface: what is known, inferred, guessed, stale, or contradicted in runtime state.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([:])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("uncertainty"), .string("epistemic"), .string("future-shell")])
                ],
                handler: { _ in
                    let surface = shell.runtimeStore.autoAssessUncertainty()
                    return toolResult(toolName: "dodexabash_uncertainty_assess", payload: ["surface": .fromEncodable(surface)])
                }
            ),
            ToolDefinition(
                name: "dodexabash_repair_suggest",
                description: "Get the most recent repair plan with root causes, repair options, and safe retry strategy.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([:])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("repair"), .string("recovery"), .string("future-shell")])
                ],
                handler: { _ in
                    if let plan = shell.runtimeStore.lastRepairPlan() {
                        return toolResult(toolName: "dodexabash_repair_suggest", payload: ["plan": .fromEncodable(plan)])
                    }
                    return toolResult(toolName: "dodexabash_repair_suggest", payload: ["plan": .null])
                }
            ),
            ToolDefinition(
                name: "dodexabash_delegate_spawn",
                description: "Spawn a delegation ticket: assign a task to a named agent with ownership rules, merge strategy, and capability leases.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "task": .object(["type": .string("string")]),
                        "delegatee": .object(["type": .string("string")]),
                        "ownership": .object(["type": .string("string")]),
                        "merge_rule": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("task"), .string("delegatee")])
                ],
                annotations: [
                    "readOnlyHint": .bool(false),
                    "riskLevel": .string("medium"),
                    "tags": .array([.string("delegation"), .string("agent"), .string("future-shell")])
                ],
                handler: { arguments in
                    let task = arguments["task"]?.stringValue ?? ""
                    let delegatee = arguments["delegatee"]?.stringValue ?? ""
                    let ownership = arguments["ownership"]?.stringValue ?? "shared"
                    let ticket = shell.runtimeStore.spawnDelegation(
                        delegatee: delegatee, task: task, ownership: ownership
                    )
                    return toolResult(toolName: "dodexabash_delegate_spawn", payload: ["ticket": .fromEncodable(ticket)])
                }
            ),
            ToolDefinition(
                name: "dodexabash_replay_last",
                description: "Get the most recent cognitive packet: compressed decision state for agent handoff or session replay.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "create": .object(["type": .string("boolean")])
                    ])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("replay"), .string("cognition"), .string("future-shell"), .string("handoff")])
                ],
                handler: { arguments in
                    let shouldCreate = arguments["create"]?.stringValue == "true" || arguments["create"]?.intValue == 1
                    if shouldCreate {
                        let packet = shell.runtimeStore.compressCognition()
                        return toolResult(toolName: "dodexabash_replay_last", payload: ["packet": .fromEncodable(packet)])
                    }
                    if let packet = shell.runtimeStore.lastCognitivePacket() {
                        return toolResult(toolName: "dodexabash_replay_last", payload: ["packet": .fromEncodable(packet)])
                    }
                    return toolResult(toolName: "dodexabash_replay_last", payload: ["packet": .null])
                }
            ),
            ToolDefinition(
                name: "dodexabash_semantic_diff",
                description: "Compare two values or files semantically: symbol changes, behavior preservation, and breaking change detection.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "before": .object(["type": .string("string")]),
                        "after": .object(["type": .string("string")]),
                        "kind": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("before"), .string("after")])
                ],
                annotations: [
                    "readOnlyHint": .bool(true),
                    "riskLevel": .string("low"),
                    "tags": .array([.string("diff"), .string("semantic"), .string("future-shell")])
                ],
                handler: { arguments in
                    let before = arguments["before"]?.stringValue ?? ""
                    let after = arguments["after"]?.stringValue ?? ""
                    let kind = arguments["kind"]?.stringValue ?? "value"
                    let d = shell.runtimeStore.createSemanticDiff(
                        kind: kind,
                        summary: before == after ? "identical" : "different",
                        before: before,
                        after: after,
                        preservesBehavior: before == after
                    )
                    return toolResult(toolName: "dodexabash_semantic_diff", payload: ["diff": .fromEncodable(d)])
                }
            )
        ]
    }
}

private extension DodexaMcpServer {
    static func readHeaderLine(from input: FileHandle) -> String? {
        var data = Data()
        while true {
            guard let byte = try? input.read(upToCount: 1) else {
                return nil
            }
            if byte.isEmpty {
                return data.isEmpty ? nil : String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            }
            data.append(byte)
            if byte == Data([0x0A]) {
                return String(decoding: data, as: UTF8.self)
                    .replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\n", with: "")
            }
        }
    }

    static func readExactly(_ count: Int, from input: FileHandle) -> Data? {
        var data = Data()
        while data.count < count {
            let remaining = count - data.count
            guard let chunk = try? input.read(upToCount: remaining), !chunk.isEmpty else {
                return nil
            }
            data.append(chunk)
        }
        return data
    }

    static func toolResult(toolName: String, payload: [String: JSONValue], isError: Bool = false) -> [String: JSONValue] {
        let envelope: [String: JSONValue] = [
            "tool": .string(toolName),
            "generatedAt": .string(ISO8601DateFormatter().string(from: Date())),
            "traceId": .string(UUID().uuidString.lowercased()),
            "payload": .object(payload),
            "futureHints": .object([
                "provenanceMode": .string("local"),
                "replayable": .bool(true),
                "stateCarrier": .string("structuredContent"),
                "transportHint": .string("stdio-jsonrpc")
            ])
        ]
        return toolText(envelope, isError: isError)
    }

    static func suggestedTools(for intent: String) -> [String] {
        let lowered = intent.lowercased()
        if lowered.contains("debug") || lowered.contains("error") || lowered.contains("fail") {
            return ["dodexabash_repair_suggest", "dodexabash_workflow_match", "dodexabash_history", "dodexabash_prove_last", "dodexabash_run"]
        }
        if lowered.contains("binary") || lowered.contains("asm") || lowered.contains("disassemble") {
            return ["dodexabash_binary_info", "dodexabash_binary_symbols", "dodexabash_disassemble"]
        }
        if lowered.contains("plugin") || lowered.contains("mcp") {
            return ["dodexabash_plugins_list", "dodexabash_workflow_list", "dodexabash_system_snapshot"]
        }
        if lowered.contains("markdown") || lowered.contains(".md") || lowered.contains("readme") || lowered.contains("session") {
            return ["dodexabash_md_parse", "dodexabash_md_section", "dodexabash_md_ingest"]
        }
        if lowered.contains("safe") || lowered.contains("risk") || lowered.contains("dry") || lowered.contains("simulate") {
            return ["dodexabash_simulate", "dodexabash_policy_get", "dodexabash_lease_list"]
        }
        if lowered.contains("intent") || lowered.contains("plan") || lowered.contains("goal") {
            return ["dodexabash_intent_set", "dodexabash_intent_get", "dodexabash_workflow_match"]
        }
        if lowered.contains("delegate") || lowered.contains("agent") || lowered.contains("handoff") {
            return ["dodexabash_delegate_spawn", "dodexabash_replay_last", "dodexabash_lease_grant"]
        }
        if lowered.contains("uncertain") || lowered.contains("confidence") || lowered.contains("know") {
            return ["dodexabash_uncertainty_assess", "dodexabash_prove_last", "dodexabash_brief"]
        }
        return ["dodexabash_brief", "dodexabash_workflow_match", "dodexabash_predict", "dodexabash_simulate"]
    }

    static func mutationRisk(for intent: String) -> String {
        let lowered = intent.lowercased()
        if ["delete", "remove", "reset", "push", "write", "deploy", "apply"].contains(where: lowered.contains) {
            return "high"
        }
        if ["edit", "change", "run", "execute", "build", "test"].contains(where: lowered.contains) {
            return "medium"
        }
        return "low"
    }

    static func intentClass(for intent: String) -> String {
        let lowered = intent.lowercased()
        if lowered.contains("binary") || lowered.contains("kernel") || lowered.contains("assembly") {
            return "systems"
        }
        if lowered.contains("plugin") || lowered.contains("mcp") || lowered.contains("tool") {
            return "integration"
        }
        if lowered.contains("debug") || lowered.contains("fix") || lowered.contains("error") {
            return "triage"
        }
        return "generalist"
    }
}

private struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        self.encodeImpl = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}
