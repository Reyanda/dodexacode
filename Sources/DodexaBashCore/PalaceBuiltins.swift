import Foundation

// MARK: - Palace Builtins: Shell integration for MemPalace memory system

extension Builtins {
    static func palaceBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let palaceDir = palaceDirectory(runtime: runtime)
        let store = PalaceStore(directory: palaceDir)
        let sub = args.first ?? "status"
        let subArgs = Array(args.dropFirst())

        switch sub {
        case "status":
            return palaceStatus(store: store)
        case "add", "file":
            return palaceAdd(args: subArgs, store: store)
        case "search", "find", "recall":
            return palaceSearch(args: subArgs, store: store)
        case "wings":
            return palaceWings(store: store)
        case "rooms":
            return palaceRooms(args: subArgs, store: store)
        case "halls":
            return palaceHalls(args: subArgs, store: store)
        case "hall":
            return palaceAddHall(args: subArgs, store: store)
        case "kg":
            return palaceKG(args: subArgs, store: store)
        case "wake", "wakeup", "wake-up":
            return palaceWake(args: subArgs, store: store)
        case "identity":
            return palaceIdentity(args: subArgs, store: store)
        case "fact":
            return palaceFact(args: subArgs, store: store)
        case "mine", "ingest":
            return palaceMine(args: subArgs, store: store, runtime: runtime)
        case "connect", "tunnel":
            return palaceTunnel(args: subArgs, store: store)
        case "graph":
            return palaceGraph(store: store)
        case "drawers":
            return palaceDrawers(args: subArgs, store: store)
        case "delete":
            return palaceDelete(args: subArgs, store: store)
        default:
            return palaceHelp()
        }
    }

    // MARK: - Status

    private static func palaceStatus(store: PalaceStore) -> CommandResult {
        let s = store.status()
        if !store.isInitialized {
            return textResult("Memory Palace: empty\nStart with: palace add <wing> <room> <text>\n")
        }
        var lines: [String] = ["Memory Palace:"]
        lines.append("  Wings: \(s.wingCount)  Rooms: \(s.roomCount)  Drawers: \(s.drawerCount)")
        lines.append("  Hall entries: \(s.hallEntryCount)  Tunnels: \(s.tunnelCount)")
        lines.append("  Knowledge graph: \(s.kgEntityCount) entities, \(s.kgActiveTriples) active facts")
        lines.append("  Identity: \(s.identitySet ? "set" : "not set")  Critical facts: \(s.criticalFactCount)")
        let kb = s.totalContentSize / 1024
        lines.append("  Content: \(kb > 0 ? "\(kb) KB" : "\(s.totalContentSize) bytes")")
        lines.append("")
        lines.append("  Wake-up cost: ~\(s.criticalFactCount * 12 + 100) tokens (L0+L1)")
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Add Drawer

    private static func palaceAdd(args: [String], store: PalaceStore) -> CommandResult {
        guard args.count >= 3 else {
            return textResult("Usage: palace add <wing> <room> <content>\n  Example: palace add work dodexabash \"Built native git library with zero deps\"\n")
        }
        let wing = args[0]
        let room = args[1]
        let content = args.dropFirst(2).joined(separator: " ")
        let drawer = store.addDrawer(content: content, wing: wing, room: room)
        return textResult("Filed in \(wing)/\(room) [\(drawer.id)]\n")
    }

    // MARK: - Search

    private static func palaceSearch(args: [String], store: PalaceStore) -> CommandResult {
        let wing = flagValue(args, flag: "--wing")
        let room = flagValue(args, flag: "--room")
        let query = args.filter { !$0.hasPrefix("--") && $0 != wing && $0 != room }.joined(separator: " ")
        guard !query.isEmpty else {
            return textResult("Usage: palace search <query> [--wing X] [--room Y]\n")
        }

        let engine = PalaceSearchEngine()
        engine.indexAll(store.allDrawers)

        let results = engine.search(query: query, limit: 10, wing: wing, room: room)
        if results.isEmpty {
            return textResult("No memories matching '\(query)'.\n")
        }

        var lines: [String] = ["Found \(results.count) memories:"]
        for r in results {
            let score = String(format: "%.2f", r.score)
            lines.append("  [\(r.wing)/\(r.room)] (\(score)) \(r.summary)")
            if !r.content.isEmpty && r.content != r.summary {
                lines.append("    \(String(r.content.prefix(100)))")
            }
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Wings

    private static func palaceWings(store: PalaceStore) -> CommandResult {
        let wings = store.wings()
        if wings.isEmpty { return textResult("No wings. Create with: palace add <wing> <room> <text>\n") }
        var lines: [String] = ["Wings (\(wings.count)):"]
        for w in wings {
            lines.append("  \(w.name) [\(w.kind)] — \(w.rooms.count) rooms")
            if !w.summary.isEmpty { lines.append("    \(w.summary)") }
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Rooms

    private static func palaceRooms(args: [String], store: PalaceStore) -> CommandResult {
        let wing = args.first
        let rooms = store.rooms(inWing: wing)
        if rooms.isEmpty { return textResult("No rooms\(wing.map { " in wing '\($0)'" } ?? "").\n") }
        var lines: [String] = ["Rooms (\(rooms.count)):"]
        for r in rooms {
            lines.append("  \(r.wing)/\(r.name) — \(r.drawerCount) drawers")
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Drawers

    private static func palaceDrawers(args: [String], store: PalaceStore) -> CommandResult {
        let wing = args.first
        let room = args.count > 1 ? args[1] : nil
        let drawers = store.drawers(inWing: wing, inRoom: room)
        if drawers.isEmpty { return textResult("No drawers.\n") }
        var lines: [String] = ["Drawers (\(drawers.count)):"]
        for d in drawers.suffix(20) {
            let preview = String(d.content.prefix(80)).replacingOccurrences(of: "\n", with: " ")
            lines.append("  [\(d.id)] \(d.wing)/\(d.room): \(preview)")
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Delete

    private static func palaceDelete(args: [String], store: PalaceStore) -> CommandResult {
        guard let id = args.first else { return textResult("Usage: palace delete <drawer-id>\n") }
        store.deleteDrawer(id: id)
        return textResult("Deleted drawer \(id).\n")
    }

    // MARK: - Halls

    private static func palaceHalls(args: [String], store: PalaceStore) -> CommandResult {
        let wing = args.first
        let entries = store.hallEntries(wing: wing)
        if entries.isEmpty { return textResult("No hall entries\(wing.map { " for '\($0)'" } ?? "").\n") }
        var lines: [String] = ["Hall (\(entries.count) entries):"]
        for e in entries.suffix(15) {
            lines.append("  [\(e.type.rawValue)] \(e.content)")
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    private static func palaceAddHall(args: [String], store: PalaceStore) -> CommandResult {
        guard args.count >= 3 else {
            return textResult("Usage: palace hall <wing> <type> <content>\n  Types: facts, events, discoveries, preferences, advice\n")
        }
        let wing = args[0]
        guard let type = HallType(rawValue: args[1]) else {
            return textResult("Invalid hall type '\(args[1])'. Use: facts, events, discoveries, preferences, advice\n")
        }
        let content = args.dropFirst(2).joined(separator: " ")
        let entry = store.addHallEntry(wing: wing, type: type, content: content)
        return textResult("Added to \(wing) hall [\(entry.type.rawValue)]\n")
    }

    // MARK: - Knowledge Graph

    private static func palaceKG(args: [String], store: PalaceStore) -> CommandResult {
        let sub = args.first ?? "stats"
        let kgArgs = Array(args.dropFirst())

        switch sub {
        case "add":
            guard kgArgs.count >= 3 else { return textResult("Usage: palace kg add <subject> <predicate> <object>\n") }
            let triple = store.kgAdd(subject: kgArgs[0], predicate: kgArgs[1],
                                      object: kgArgs.dropFirst(2).joined(separator: " "))
            return textResult("Added: \(triple.subject) —[\(triple.predicate)]→ \(triple.object)\n")

        case "query":
            guard let entity = kgArgs.first else { return textResult("Usage: palace kg query <entity>\n") }
            let triples = store.kgQuery(entity: entity)
            if triples.isEmpty { return textResult("No facts about '\(entity)'.\n") }
            var lines: [String] = ["Facts about \(entity):"]
            for t in triples {
                lines.append("  \(t.subject) —[\(t.predicate)]→ \(t.object)")
            }
            return textResult(lines.joined(separator: "\n") + "\n")

        case "timeline":
            guard let entity = kgArgs.first else { return textResult("Usage: palace kg timeline <entity>\n") }
            let timeline = store.kgTimeline(entity: entity)
            if timeline.isEmpty { return textResult("No timeline for '\(entity)'.\n") }
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
            var lines: [String] = ["Timeline for \(entity):"]
            for t in timeline {
                let status = t.isActive ? "\u{25CF}" : "\u{25CB}"
                lines.append("  \(status) \(fmt.string(from: t.validFrom)): \(t.subject) \(t.predicate) \(t.object)")
            }
            return textResult(lines.joined(separator: "\n") + "\n")

        case "invalidate":
            guard kgArgs.count >= 2 else { return textResult("Usage: palace kg invalidate <subject> <predicate>\n") }
            store.kgInvalidate(subject: kgArgs[0], predicate: kgArgs[1])
            return textResult("Invalidated: \(kgArgs[0]) \(kgArgs[1])\n")

        case "stats":
            let stats = store.kgStats()
            return textResult("Knowledge Graph: \(stats.entities) entities, \(stats.triples) triples (\(stats.active) active)\n")

        default:
            return textResult("Usage: palace kg [add|query|timeline|invalidate|stats]\n")
        }
    }

    // MARK: - Wake-up (L0+L1)

    private static func palaceWake(args: [String], store: PalaceStore) -> CommandResult {
        let query = args.joined(separator: " ")
        let engine = PalaceSearchEngine()
        engine.indexAll(store.allDrawers)
        let ctx = store.generateContext(query: query.isEmpty ? nil : query, searchEngine: engine)
        if ctx.wakeUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return textResult("Palace empty. Add memories first.\n")
        }
        var lines: [String] = ["Memory Context (wake-up):"]
        lines.append("L0: \(ctx.l0)")
        if !ctx.l1.isEmpty { lines.append("L1: \(ctx.l1)") }
        if !ctx.l2.isEmpty { lines.append("L2: \(ctx.l2)") }
        if !ctx.l3.isEmpty { lines.append("L3: \(ctx.l3)") }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Identity (L0)

    private static func palaceIdentity(args: [String], store: PalaceStore) -> CommandResult {
        if args.isEmpty {
            let id = store.identity
            return textResult(id.isEmpty ? "No identity set. Use: palace identity <description>\n" : "Identity: \(id)\n")
        }
        store.identity = args.joined(separator: " ")
        return textResult("Identity set.\n")
    }

    // MARK: - Critical Fact (L1)

    private static func palaceFact(args: [String], store: PalaceStore) -> CommandResult {
        if args.isEmpty {
            let facts = store.criticalFacts
            if facts.isEmpty { return textResult("No critical facts. Use: palace fact <fact>\n") }
            var lines: [String] = ["Critical Facts (\(facts.count)):"]
            for (i, f) in facts.enumerated() { lines.append("  \(i + 1). \(f)") }
            return textResult(lines.joined(separator: "\n") + "\n")
        }
        var facts = store.criticalFacts
        facts.append(args.joined(separator: " "))
        store.criticalFacts = facts
        return textResult("Added critical fact (\(facts.count) total).\n")
    }

    // MARK: - Mine/Ingest

    private static func palaceMine(args: [String], store: PalaceStore, runtime: BuiltinRuntime) -> CommandResult {
        let path = args.first ?? runtime.context.currentDirectory
        let wing = flagValue(args, flag: "--wing") ?? URL(fileURLWithPath: path).lastPathComponent
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return textResult("Cannot read directory: \(path)\n")
        }

        let codeExts: Set<String> = ["swift", "py", "js", "ts", "go", "rs", "c", "cpp", "h", "java", "rb", "md", "txt"]
        let ignoreNames: Set<String> = [".git", ".build", "node_modules", "__pycache__", "DerivedData", "dist", ".dodexabash"]
        var filed = 0
        let maxFiles = 200

        while let url = enumerator.nextObject() as? URL, filed < maxFiles {
            let name = url.lastPathComponent
            if ignoreNames.contains(name) { enumerator.skipDescendants(); continue }

            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize, size > 0, size < 50000 else { continue }

            let ext = url.pathExtension.lowercased()
            guard codeExts.contains(ext) else { continue }

            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }

            let rootPath = path.hasSuffix("/") ? path : path + "/"
            let relative = url.path.hasPrefix(rootPath) ? String(url.path.dropFirst(rootPath.count)) : url.lastPathComponent
            let room = relative.components(separatedBy: "/").first ?? "root"

            // Chunk by paragraphs (800 chars each)
            let chunks = chunkText(content, maxChars: 800)
            for (i, chunk) in chunks.enumerated() {
                let label = chunks.count > 1 ? "\(relative) [part \(i + 1)]" : relative
                store.addDrawer(content: chunk, wing: wing, room: room, tags: [ext],
                               source: "ingest", importance: 2, summary: label)
                filed += 1
            }
        }

        return textResult("Mined \(filed) content chunks into wing '\(wing)' from \(path)\n")
    }

    // MARK: - Tunnel

    private static func palaceTunnel(args: [String], store: PalaceStore) -> CommandResult {
        guard args.count >= 2 else {
            return textResult("Usage: palace connect <wing/room> <wing/room> [reason]\n")
        }
        let from = args[0].split(separator: "/")
        let to = args[1].split(separator: "/")
        guard from.count == 2, to.count == 2 else {
            return textResult("Use wing/room format: palace connect work/auth personal/security\n")
        }
        let reason = args.count > 2 ? args.dropFirst(2).joined(separator: " ") : ""
        let tunnel = store.createTunnel(fromWing: String(from[0]), fromRoom: String(from[1]),
                                         toWing: String(to[0]), toRoom: String(to[1]), reason: reason)
        return textResult("Tunnel created: \(tunnel.fromWing)/\(tunnel.fromRoom) ↔ \(tunnel.toWing)/\(tunnel.toRoom)\n")
    }

    // MARK: - Graph

    private static func palaceGraph(store: PalaceStore) -> CommandResult {
        let wings = store.wings()
        let tunnels = store.tunnels()
        if wings.isEmpty { return textResult("Empty palace.\n") }

        var lines: [String] = ["Palace Graph:"]
        for wing in wings {
            lines.append("  \u{250C} \(wing.name) [\(wing.kind)]")
            let rooms = store.rooms(inWing: wing.name)
            for (i, room) in rooms.enumerated() {
                let connector = i == rooms.count - 1 ? "\u{2514}" : "\u{251C}"
                lines.append("  \u{2502} \(connector)\u{2500} \(room.name) (\(room.drawerCount) drawers)")
            }
            lines.append("  \u{2502}")
        }
        if !tunnels.isEmpty {
            lines.append("  Tunnels:")
            for t in tunnels {
                lines.append("    \(t.fromWing)/\(t.fromRoom) \u{2194} \(t.toWing)/\(t.toRoom)\(t.reason.isEmpty ? "" : " (\(t.reason))")")
            }
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Help

    private static func palaceHelp() -> CommandResult {
        textResult("""
        Memory Palace — Local AI Memory System

        Storage:
          palace add <wing> <room> <content>    File a memory
          palace mine [path] [--wing name]       Ingest project files
          palace delete <drawer-id>              Remove a drawer

        Recall:
          palace search <query> [--wing] [--room]  Semantic search
          palace wake [query]                      Generate L0+L1 context
          palace drawers [wing] [room]             List stored content

        Structure:
          palace status                 Overview
          palace wings                  List wings (people/projects)
          palace rooms [wing]           List rooms in a wing
          palace graph                  Visualize palace structure
          palace connect <w/r> <w/r>    Create tunnel between rooms

        Metadata:
          palace identity <text>        Set L0 identity
          palace fact <text>            Add L1 critical fact
          palace hall <wing> <type> <text>  Add hall entry
          palace halls [wing]           Show hall entries
          Types: facts, events, discoveries, preferences, advice

        Knowledge Graph:
          palace kg add <s> <p> <o>     Add temporal fact
          palace kg query <entity>      Query entity
          palace kg timeline <entity>   Chronological story
          palace kg invalidate <s> <p>  Retire a fact
          palace kg stats               Graph statistics

        """)
    }

    // MARK: - Helpers

    private static func chunkText(_ text: String, maxChars: Int) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
        var chunks: [String] = []
        var current = ""

        for para in paragraphs {
            if current.count + para.count > maxChars && !current.isEmpty {
                chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
            current += (current.isEmpty ? "" : "\n\n") + para
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return chunks.isEmpty ? [text] : chunks
    }

    private static func flagValue(_ args: [String], flag: String) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    private static func palaceDirectory(runtime: BuiltinRuntime) -> URL {
        let home: String
        if let override = runtime.context.environment["DODEXABASH_HOME"], !override.isEmpty {
            home = override
        } else {
            home = runtime.context.currentDirectory + "/.dodexabash"
        }
        return URL(fileURLWithPath: home).appendingPathComponent("palace", isDirectory: true)
    }
}
