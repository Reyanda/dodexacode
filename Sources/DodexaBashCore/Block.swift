import Foundation

// MARK: - Block: The fundamental structured output unit
// Every command execution produces a Block — a discrete, navigable, provenance-aware object.
// This is the core UX primitive that transforms undifferentiated terminal scroll into
// structured, selectable, shareable, AI-readable units.

public struct Block: Codable, Sendable, Identifiable {
    public let id: UUID
    public let command: String
    public let output: BlockOutput
    public let exitCode: Int32
    public let duration: TimeInterval  // seconds
    public let startedAt: Date
    public let finishedAt: Date
    public let workingDirectory: String
    public let gitBranch: String?

    // Future-shell metadata — what makes this different from Warp
    public let proofId: String?           // reference to Proof envelope
    public let intentId: String?          // what was the user trying to do
    public let uncertaintyLevel: UncertaintyLevel?
    public let repairId: String?          // repair plan if failed

    public init(
        command: String,
        output: BlockOutput,
        exitCode: Int32,
        duration: TimeInterval,
        startedAt: Date,
        finishedAt: Date,
        workingDirectory: String,
        gitBranch: String? = nil,
        proofId: String? = nil,
        intentId: String? = nil,
        uncertaintyLevel: UncertaintyLevel? = nil,
        repairId: String? = nil
    ) {
        self.id = UUID()
        self.command = command
        self.output = output
        self.exitCode = exitCode
        self.duration = duration
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.workingDirectory = workingDirectory
        self.gitBranch = gitBranch
        self.proofId = proofId
        self.intentId = intentId
        self.uncertaintyLevel = uncertaintyLevel
        self.repairId = repairId
    }
}

public enum UncertaintyLevel: String, Codable, Sendable {
    case known      // verified, deterministic
    case inferred   // high confidence but not verified
    case guessed    // heuristic, low confidence
    case stale      // was known, may have changed
    case unknown    // no information
}

// MARK: - BlockOutput: Structured terminal output with ANSI preservation

public struct BlockOutput: Codable, Sendable {
    public let stdout: String
    public let stderr: String
    public let rawStdout: Data   // preserves ANSI escape sequences
    public let rawStderr: Data

    public init(stdout: String, stderr: String, rawStdout: Data = Data(), rawStderr: Data = Data()) {
        self.stdout = stdout
        self.stderr = stderr
        self.rawStdout = rawStdout.isEmpty ? Data(stdout.utf8) : rawStdout
        self.rawStderr = rawStderr.isEmpty ? Data(stderr.utf8) : rawStderr
    }

    public var isEmpty: Bool {
        stdout.isEmpty && stderr.isEmpty
    }

    public var combinedText: String {
        if stderr.isEmpty { return stdout }
        if stdout.isEmpty { return stderr }
        return stdout + stderr
    }

    /// Truncated preview for status lines and summaries
    public func preview(limit: Int = 120) -> String {
        let text = combinedText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count <= limit { return text }
        return String(text.prefix(limit)) + "…"
    }
}

// MARK: - BlockStore: In-memory block ring buffer with persistence

public final class BlockStore: @unchecked Sendable {
    private let fileURL: URL
    private var blocks: [Block] = []
    private let maxBlocks = 500
    private var selectedIndex: Int?

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("blocks.json")
        // Load last session's blocks for continuity
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Block].self, from: data) {
            self.blocks = Array(saved.suffix(maxBlocks))
        }
    }

    public func append(_ block: Block) {
        blocks.append(block)
        if blocks.count > maxBlocks {
            blocks.removeFirst(blocks.count - maxBlocks)
        }
        persist()
    }

    public var count: Int { blocks.count }

    public var all: [Block] { blocks }

    public func recent(_ n: Int) -> [Block] {
        Array(blocks.suffix(n))
    }

    public var latest: Block? { blocks.last }

    public func block(at index: Int) -> Block? {
        guard blocks.indices.contains(index) else { return nil }
        return blocks[index]
    }

    public func block(byId id: UUID) -> Block? {
        blocks.first { $0.id == id }
    }

    // MARK: - Navigation (for TUI block selection)

    public var currentSelection: Int? {
        get { selectedIndex }
        set { selectedIndex = newValue }
    }

    public func selectPrevious() -> Block? {
        guard !blocks.isEmpty else { return nil }
        if let current = selectedIndex {
            selectedIndex = max(0, current - 1)
        } else {
            selectedIndex = blocks.count - 1
        }
        return selectedIndex.flatMap { block(at: $0) }
    }

    public func selectNext() -> Block? {
        guard !blocks.isEmpty, let current = selectedIndex else { return nil }
        if current >= blocks.count - 1 {
            selectedIndex = nil  // deselect = back to input
            return nil
        }
        selectedIndex = current + 1
        return selectedIndex.flatMap { block(at: $0) }
    }

    public func clearSelection() {
        selectedIndex = nil
    }

    // MARK: - Search

    public func search(query: String) -> [Block] {
        let lowered = query.lowercased()
        return blocks.filter {
            $0.command.lowercased().contains(lowered) ||
            $0.output.stdout.lowercased().contains(lowered)
        }
    }

    /// Blocks that failed (for repair context)
    public func failures(limit: Int = 10) -> [Block] {
        Array(blocks.filter { $0.exitCode != 0 }.suffix(limit))
    }

    // MARK: - Export

    public func exportJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(blocks)
    }

    public func exportSession() -> SessionExport {
        SessionExport(
            exportedAt: Date(),
            blockCount: blocks.count,
            blocks: blocks
        )
    }

    // MARK: - Persistence

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Array(blocks.suffix(100))) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

public struct SessionExport: Codable, Sendable {
    public let exportedAt: Date
    public let blockCount: Int
    public let blocks: [Block]
}
