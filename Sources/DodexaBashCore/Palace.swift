import Foundation

// MARK: - MemPalace: Native AI Memory System for dodexabash
// Port of MemPalace v3.0.14 to zero-dependency Swift.
// Palace metaphor: Wing → Room → Closet → Drawer
// 4-layer memory stack: L0 (identity) + L1 (critical) + L2 (room) + L3 (deep search)

// MARK: - Palace Hierarchy

public struct PalaceDrawer: Codable, Sendable, Identifiable {
    public let id: String
    public let content: String
    public let summary: String
    public let wing: String
    public let room: String
    public let tags: [String]
    public let source: String         // "manual", "auto-block", "ingest", "brain"
    public let createdAt: Date
    public let importance: Int        // 1-5

    public init(content: String, summary: String, wing: String, room: String,
                tags: [String] = [], source: String = "manual", importance: Int = 3) {
        self.id = Self.shortId()
        self.content = content
        self.summary = summary.isEmpty ? String(content.prefix(120)) : summary
        self.wing = wing
        self.room = room
        self.tags = tags
        self.source = source
        self.createdAt = Date()
        self.importance = min(5, max(1, importance))
    }

    private static func shortId() -> String {
        var bytes = [UInt8](repeating: 0, count: 6)
        _ = bytes.withUnsafeMutableBufferPointer { SecRandomCopyBytes(kSecRandomDefault, 6, $0.baseAddress!) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct PalaceRoom: Codable, Sendable {
    public let name: String
    public let wing: String
    public var drawerCount: Int
    public var summary: String
    public var tags: [String]
}

public struct PalaceWing: Codable, Sendable {
    public let name: String
    public var rooms: [String]       // room names
    public var summary: String
    public var kind: String          // "person", "project", "topic"
}

// MARK: - Hall (corridor metadata)

public enum HallType: String, Codable, Sendable, CaseIterable {
    case facts          // decisions locked in
    case events         // sessions, milestones
    case discoveries    // breakthroughs, learnings
    case preferences    // habits, opinions, config
    case advice         // recommendations
}

public struct HallEntry: Codable, Sendable {
    public let id: String
    public let wing: String
    public let type: HallType
    public let content: String
    public let createdAt: Date
    public let importance: Int
}

// MARK: - Tunnel (cross-wing connections)

public struct PalaceTunnel: Codable, Sendable {
    public let id: String
    public let fromWing: String
    public let fromRoom: String
    public let toWing: String
    public let toRoom: String
    public let reason: String
    public let createdAt: Date
}

// MARK: - Knowledge Graph

public struct KGTriple: Codable, Sendable {
    public let id: String
    public let subject: String
    public let predicate: String
    public let object: String
    public let validFrom: Date
    public var validTo: Date?         // nil = still true
    public let source: String
    public let createdAt: Date

    public var isActive: Bool { validTo == nil || validTo! > Date() }
}

// MARK: - Memory Layers

public struct MemoryContext: Sendable {
    public let l0: String   // identity (~100 tokens)
    public let l1: String   // critical facts (~120 tokens)
    public let l2: String   // room recall (on demand)
    public let l3: String   // deep search results (on demand)

    public var wakeUp: String { l0 + "\n" + l1 }
    public var full: String { l0 + "\n" + l1 + "\n" + l2 + "\n" + l3 }

    public static let empty = MemoryContext(l0: "", l1: "", l2: "", l3: "")
}

// MARK: - Palace Snapshot (persistence)

private struct PalaceSnapshot: Codable, Sendable {
    var version: Int = 1
    var wings: [PalaceWing] = []
    var rooms: [PalaceRoom] = []
    var hallEntries: [HallEntry] = []
    var tunnels: [PalaceTunnel] = []
    var kgTriples: [KGTriple] = []
    var identity: String = ""          // L0 content
    var criticalFacts: [String] = []   // L1 entries
}

// MARK: - Palace Store

public final class PalaceStore: @unchecked Sendable {
    private let directory: URL
    private let drawersDir: URL
    private var snapshot: PalaceSnapshot
    private var drawers: [PalaceDrawer] = []

    public init(directory: URL) {
        self.directory = directory
        self.drawersDir = directory.appendingPathComponent("drawers", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: drawersDir, withIntermediateDirectories: true)
        self.snapshot = Self.loadSnapshot(from: directory)
        self.drawers = Self.loadDrawers(from: drawersDir)
    }

    public var isInitialized: Bool { !snapshot.wings.isEmpty || !drawers.isEmpty }

    // MARK: - Wings

    public func wings() -> [PalaceWing] { snapshot.wings }

    public func wing(named name: String) -> PalaceWing? {
        snapshot.wings.first { $0.name.lowercased() == name.lowercased() }
    }

    @discardableResult
    public func createWing(name: String, kind: String = "project", summary: String = "") -> PalaceWing {
        if let existing = wing(named: name) { return existing }
        let w = PalaceWing(name: name, rooms: [], summary: summary, kind: kind)
        snapshot.wings.append(w)
        persist()
        return w
    }

    // MARK: - Rooms

    public func rooms(inWing wing: String? = nil) -> [PalaceRoom] {
        if let w = wing {
            return snapshot.rooms.filter { $0.wing.lowercased() == w.lowercased() }
        }
        return snapshot.rooms
    }

    @discardableResult
    public func createRoom(name: String, wing: String, summary: String = "") -> PalaceRoom {
        if let existing = snapshot.rooms.first(where: { $0.name == name && $0.wing == wing }) { return existing }
        // Ensure wing exists
        createWing(name: wing)
        let room = PalaceRoom(name: name, wing: wing, drawerCount: 0, summary: summary, tags: [])
        snapshot.rooms.append(room)
        // Add room to wing
        if let idx = snapshot.wings.firstIndex(where: { $0.name == wing }) {
            if !snapshot.wings[idx].rooms.contains(name) {
                snapshot.wings[idx].rooms.append(name)
            }
        }
        persist()
        return room
    }

    // MARK: - Drawers (content storage)

    @discardableResult
    public func addDrawer(content: String, wing: String, room: String, tags: [String] = [],
                          source: String = "manual", importance: Int = 3, summary: String = "") -> PalaceDrawer {
        createRoom(name: room, wing: wing)
        let drawer = PalaceDrawer(content: content, summary: summary, wing: wing, room: room,
                                   tags: tags, source: source, importance: importance)
        drawers.append(drawer)
        // Update room drawer count
        if let idx = snapshot.rooms.firstIndex(where: { $0.name == room && $0.wing == wing }) {
            snapshot.rooms[idx].drawerCount += 1
        }
        persistDrawer(drawer)
        persist()
        return drawer
    }

    public func drawer(byId id: String) -> PalaceDrawer? {
        drawers.first { $0.id == id }
    }

    public func drawers(inWing wing: String? = nil, inRoom room: String? = nil) -> [PalaceDrawer] {
        drawers.filter { d in
            (wing == nil || d.wing.lowercased() == wing!.lowercased()) &&
            (room == nil || d.room.lowercased() == room!.lowercased())
        }
    }

    public func deleteDrawer(id: String) {
        drawers.removeAll { $0.id == id }
        let url = drawersDir.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: url)
    }

    public var drawerCount: Int { drawers.count }
    public var allDrawers: [PalaceDrawer] { drawers }

    // MARK: - Halls

    @discardableResult
    public func addHallEntry(wing: String, type: HallType, content: String, importance: Int = 3) -> HallEntry {
        createWing(name: wing)
        let entry = HallEntry(id: shortId(), wing: wing, type: type, content: content,
                               createdAt: Date(), importance: importance)
        snapshot.hallEntries.append(entry)
        if snapshot.hallEntries.count > 500 { snapshot.hallEntries.removeFirst() }
        persist()
        return entry
    }

    public func hallEntries(wing: String? = nil, type: HallType? = nil) -> [HallEntry] {
        snapshot.hallEntries.filter { e in
            (wing == nil || e.wing.lowercased() == wing!.lowercased()) &&
            (type == nil || e.type == type)
        }
    }

    // MARK: - Tunnels

    @discardableResult
    public func createTunnel(fromWing: String, fromRoom: String, toWing: String, toRoom: String, reason: String = "") -> PalaceTunnel {
        let tunnel = PalaceTunnel(id: shortId(), fromWing: fromWing, fromRoom: fromRoom,
                                   toWing: toWing, toRoom: toRoom, reason: reason, createdAt: Date())
        snapshot.tunnels.append(tunnel)
        persist()
        return tunnel
    }

    public func tunnels(involving wing: String? = nil) -> [PalaceTunnel] {
        if let w = wing {
            return snapshot.tunnels.filter { $0.fromWing == w || $0.toWing == w }
        }
        return snapshot.tunnels
    }

    // MARK: - Knowledge Graph

    @discardableResult
    public func kgAdd(subject: String, predicate: String, object: String, source: String = "manual") -> KGTriple {
        let triple = KGTriple(id: shortId(), subject: subject, predicate: predicate, object: object,
                               validFrom: Date(), validTo: nil, source: source, createdAt: Date())
        snapshot.kgTriples.append(triple)
        persist()
        return triple
    }

    public func kgQuery(entity: String) -> [KGTriple] {
        snapshot.kgTriples.filter { t in
            t.isActive && (t.subject.lowercased() == entity.lowercased() ||
                          t.object.lowercased() == entity.lowercased())
        }
    }

    public func kgInvalidate(subject: String, predicate: String) {
        for i in snapshot.kgTriples.indices {
            if snapshot.kgTriples[i].subject.lowercased() == subject.lowercased() &&
               snapshot.kgTriples[i].predicate.lowercased() == predicate.lowercased() &&
               snapshot.kgTriples[i].validTo == nil {
                snapshot.kgTriples[i].validTo = Date()
            }
        }
        persist()
    }

    public func kgTimeline(entity: String) -> [KGTriple] {
        snapshot.kgTriples.filter { t in
            t.subject.lowercased() == entity.lowercased() ||
            t.object.lowercased() == entity.lowercased()
        }.sorted { $0.validFrom < $1.validFrom }
    }

    public func kgStats() -> (entities: Int, triples: Int, active: Int) {
        let active = snapshot.kgTriples.filter(\.isActive)
        let entities = Set(snapshot.kgTriples.flatMap { [$0.subject, $0.object] })
        return (entities.count, snapshot.kgTriples.count, active.count)
    }

    // MARK: - Memory Layers

    public var identity: String {
        get { snapshot.identity }
        set { snapshot.identity = newValue; persist() }
    }

    public var criticalFacts: [String] {
        get { snapshot.criticalFacts }
        set { snapshot.criticalFacts = newValue; persist() }
    }

    public func generateContext(query: String? = nil, searchEngine: PalaceSearchEngine? = nil) -> MemoryContext {
        // L0: Identity
        let l0 = snapshot.identity.isEmpty
            ? "dodexabash AI-native shell with memory palace."
            : snapshot.identity

        // L1: Critical facts
        let l1 = snapshot.criticalFacts.isEmpty
            ? ""
            : "Key facts: " + snapshot.criticalFacts.prefix(10).joined(separator: "; ")

        // L2: Room context (most recent rooms with hall entries)
        var l2Parts: [String] = []
        for hall in snapshot.hallEntries.suffix(5) {
            l2Parts.append("[\(hall.type.rawValue)] \(hall.content)")
        }
        let l2 = l2Parts.joined(separator: "\n")

        // L3: Deep search (if query provided)
        var l3 = ""
        if let q = query, let engine = searchEngine {
            let results = engine.search(query: q, limit: 5)
            if !results.isEmpty {
                l3 = "Memories matching '\(q)':\n" + results.map { r in
                    "- [\(r.wing)/\(r.room)] \(r.summary)"
                }.joined(separator: "\n")
            }
        }

        return MemoryContext(l0: l0, l1: l1, l2: l2, l3: l3)
    }

    // MARK: - Stats

    public func status() -> PalaceStatus {
        PalaceStatus(
            wingCount: snapshot.wings.count,
            roomCount: snapshot.rooms.count,
            drawerCount: drawers.count,
            hallEntryCount: snapshot.hallEntries.count,
            tunnelCount: snapshot.tunnels.count,
            kgTripleCount: snapshot.kgTriples.count,
            kgActiveTriples: snapshot.kgTriples.filter(\.isActive).count,
            kgEntityCount: Set(snapshot.kgTriples.flatMap { [$0.subject, $0.object] }).count,
            identitySet: !snapshot.identity.isEmpty,
            criticalFactCount: snapshot.criticalFacts.count,
            totalContentSize: drawers.reduce(0) { $0 + $1.content.count }
        )
    }

    // MARK: - Persistence

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: directory.appendingPathComponent("palace.json"), options: .atomic)
    }

    private func persistDrawer(_ drawer: PalaceDrawer) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(drawer) else { return }
        try? data.write(to: drawersDir.appendingPathComponent("\(drawer.id).json"), options: .atomic)
    }

    private static func loadSnapshot(from dir: URL) -> PalaceSnapshot {
        let url = dir.appendingPathComponent("palace.json")
        guard let data = try? Data(contentsOf: url) else { return PalaceSnapshot() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(PalaceSnapshot.self, from: data)) ?? PalaceSnapshot()
    }

    private static func loadDrawers(from dir: URL) -> [PalaceDrawer] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.compactMap { file -> PalaceDrawer? in
            guard file.hasSuffix(".json") else { return nil }
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)) else { return nil }
            return try? decoder.decode(PalaceDrawer.self, from: data)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    private func shortId() -> String {
        var bytes = [UInt8](repeating: 0, count: 6)
        _ = bytes.withUnsafeMutableBufferPointer { SecRandomCopyBytes(kSecRandomDefault, 6, $0.baseAddress!) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Status

public struct PalaceStatus: Sendable {
    public let wingCount: Int
    public let roomCount: Int
    public let drawerCount: Int
    public let hallEntryCount: Int
    public let tunnelCount: Int
    public let kgTripleCount: Int
    public let kgActiveTriples: Int
    public let kgEntityCount: Int
    public let identitySet: Bool
    public let criticalFactCount: Int
    public let totalContentSize: Int

    public var summary: String {
        "\(wingCount) wings, \(roomCount) rooms, \(drawerCount) drawers, \(kgActiveTriples) facts"
    }
}
