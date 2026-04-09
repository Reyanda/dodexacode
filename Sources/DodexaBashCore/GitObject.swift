import CommonCrypto
import Darwin
import Foundation
import zlib

// MARK: - Git Object Store
// Native Swift implementation of git object read/write.
// Objects are stored as: zlib(header + content) at .git/objects/XX/YYYYYY...
// Header format: "<type> <size>\0"
// SHA-1 is computed over the raw (uncompressed) header + content.

// MARK: - Object Types

public enum GitObjectType: String, Codable, Sendable {
    case blob
    case tree
    case commit
    case tag
}

public struct GitObjectId: Hashable, Codable, Sendable, CustomStringConvertible {
    public let hex: String  // 40-char lowercase hex SHA-1

    public init(hex: String) {
        self.hex = hex.lowercased()
    }

    public init(raw: Data) {
        self.hex = raw.map { String(format: "%02x", $0) }.joined()
    }

    public var raw: Data {
        var data = Data(capacity: 20)
        var i = hex.startIndex
        for _ in 0..<20 {
            let next = hex.index(i, offsetBy: 2)
            if let byte = UInt8(hex[i..<next], radix: 16) {
                data.append(byte)
            }
            i = next
        }
        return data
    }

    public var short: String { String(hex.prefix(7)) }
    public var description: String { hex }

    public var objectPath: String {
        String(hex.prefix(2)) + "/" + String(hex.dropFirst(2))
    }
}

// MARK: - Parsed Objects

public struct GitBlob: Sendable {
    public let id: GitObjectId
    public let content: Data
    public var text: String? { String(data: content, encoding: .utf8) }
}

public struct GitTreeEntry: Sendable {
    public let mode: String     // "100644", "100755", "040000", "120000", "160000"
    public let name: String
    public let sha: GitObjectId

    public var isDirectory: Bool { mode == "040000" || mode == "40000" }
    public var isExecutable: Bool { mode == "100755" }
    public var isSymlink: Bool { mode == "120000" }
    public var isSubmodule: Bool { mode == "160000" }
}

public struct GitTree: Sendable {
    public let id: GitObjectId
    public let entries: [GitTreeEntry]

    public func entry(named name: String) -> GitTreeEntry? {
        entries.first { $0.name == name }
    }
}

public struct GitSignature: Codable, Sendable {
    public let name: String
    public let email: String
    public let timestamp: Date
    public let tzOffset: String  // e.g. "+0530"

    public init(name: String, email: String, timestamp: Date = Date(), tzOffset: String = "+0000") {
        self.name = name
        self.email = email
        self.timestamp = timestamp
        self.tzOffset = tzOffset
    }

    public var gitFormat: String {
        "\(name) <\(email)> \(Int(timestamp.timeIntervalSince1970)) \(tzOffset)"
    }

    public static func parse(_ line: String) -> GitSignature? {
        // Format: "Name <email> timestamp tzoffset"
        guard let angleOpen = line.firstIndex(of: "<"),
              let angleClose = line.firstIndex(of: ">") else { return nil }
        let name = String(line[line.startIndex..<angleOpen]).trimmingCharacters(in: .whitespaces)
        let email = String(line[line.index(after: angleOpen)..<angleClose])
        let rest = String(line[line.index(after: angleClose)...]).trimmingCharacters(in: .whitespaces)
        let parts = rest.split(separator: " ")
        let timestamp: Date
        let tz: String
        if let ts = parts.first.flatMap({ TimeInterval($0) }) {
            timestamp = Date(timeIntervalSince1970: ts)
            tz = parts.count > 1 ? String(parts[1]) : "+0000"
        } else {
            timestamp = Date()
            tz = "+0000"
        }
        return GitSignature(name: name, email: email, timestamp: timestamp, tzOffset: tz)
    }
}

public struct GitCommit: Sendable {
    public let id: GitObjectId
    public let treeId: GitObjectId
    public let parentIds: [GitObjectId]
    public let author: GitSignature
    public let committer: GitSignature
    public let message: String

    public var summary: String {
        message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message
    }
}

// MARK: - Raw Object Data

public struct GitRawObject {
    public let type: GitObjectType
    public let size: Int
    public let content: Data
}

// MARK: - Object Store

public final class GitObjectStore: @unchecked Sendable {
    public let objectsDir: URL  // .git/objects/

    public init(gitDir: URL) {
        self.objectsDir = gitDir.appendingPathComponent("objects", isDirectory: true)
    }

    // MARK: - Read

    public func readRaw(id: GitObjectId) -> GitRawObject? {
        let path = objectsDir.appendingPathComponent(id.objectPath)
        guard let compressed = try? Data(contentsOf: path) else { return nil }
        guard let decompressed = zlibDecompress(compressed) else { return nil }
        return parseRawObject(data: decompressed)
    }

    public func readBlob(id: GitObjectId) -> GitBlob? {
        guard let raw = readRaw(id: id), raw.type == .blob else { return nil }
        return GitBlob(id: id, content: raw.content)
    }

    public func readTree(id: GitObjectId) -> GitTree? {
        guard let raw = readRaw(id: id), raw.type == .tree else { return nil }
        return parseTree(id: id, data: raw.content)
    }

    public func readCommit(id: GitObjectId) -> GitCommit? {
        guard let raw = readRaw(id: id), raw.type == .commit else { return nil }
        return parseCommit(id: id, data: raw.content)
    }

    public func objectExists(id: GitObjectId) -> Bool {
        let path = objectsDir.appendingPathComponent(id.objectPath)
        return FileManager.default.fileExists(atPath: path.path)
    }

    // MARK: - Write

    @discardableResult
    public func writeBlob(content: Data) -> GitObjectId {
        writeObject(type: .blob, content: content)
    }

    @discardableResult
    public func writeTree(entries: [GitTreeEntry]) -> GitObjectId {
        var data = Data()
        let sorted = entries.sorted { a, b in
            // Git sorts tree entries with trailing / for directories
            let aKey = a.isDirectory ? a.name + "/" : a.name
            let bKey = b.isDirectory ? b.name + "/" : b.name
            return aKey < bKey
        }
        for entry in sorted {
            data.append(contentsOf: "\(entry.mode) \(entry.name)\0".utf8)
            data.append(entry.sha.raw)
        }
        return writeObject(type: .tree, content: data)
    }

    @discardableResult
    public func writeCommit(
        treeId: GitObjectId,
        parentIds: [GitObjectId],
        author: GitSignature,
        committer: GitSignature,
        message: String
    ) -> GitObjectId {
        var lines: [String] = []
        lines.append("tree \(treeId.hex)")
        for parent in parentIds {
            lines.append("parent \(parent.hex)")
        }
        lines.append("author \(author.gitFormat)")
        lines.append("committer \(committer.gitFormat)")
        lines.append("")
        lines.append(message)
        let content = Data(lines.joined(separator: "\n").utf8)
        return writeObject(type: .commit, content: content)
    }

    @discardableResult
    public func writeObject(type: GitObjectType, content: Data) -> GitObjectId {
        let header = "\(type.rawValue) \(content.count)\0"
        var fullData = Data(header.utf8)
        fullData.append(content)

        let id = sha1(fullData)

        // Don't overwrite existing objects
        let path = objectsDir.appendingPathComponent(id.objectPath)
        guard !FileManager.default.fileExists(atPath: path.path) else { return id }

        // Compress and write
        guard let compressed = zlibCompress(fullData) else { return id }

        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? compressed.write(to: path, options: .atomic)

        return id
    }

    // MARK: - SHA-1

    public func sha1(_ data: Data) -> GitObjectId {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA1(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return GitObjectId(raw: Data(digest))
    }

    /// Compute SHA-1 of file content as a blob (without writing)
    public func hashFile(at path: String) -> GitObjectId? {
        guard let content = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let header = "blob \(content.count)\0"
        var fullData = Data(header.utf8)
        fullData.append(content)
        return sha1(fullData)
    }

    // MARK: - Parsing

    private func parseRawObject(data: Data) -> GitRawObject? {
        // Find the null byte separating header from content
        guard let nullIndex = data.firstIndex(of: 0) else { return nil }
        let headerData = data[data.startIndex..<nullIndex]
        guard let header = String(data: headerData, encoding: .ascii) else { return nil }

        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2,
              let type = GitObjectType(rawValue: String(parts[0])),
              let size = Int(parts[1]) else { return nil }

        let content = data[data.index(after: nullIndex)...]
        return GitRawObject(type: type, size: size, content: Data(content))
    }

    private func parseTree(id: GitObjectId, data: Data) -> GitTree {
        var entries: [GitTreeEntry] = []
        var offset = data.startIndex

        while offset < data.endIndex {
            // Find space after mode
            guard let spaceIdx = data[offset...].firstIndex(of: 0x20) else { break }
            let modeData = data[offset..<spaceIdx]
            guard let mode = String(data: modeData, encoding: .ascii) else { break }

            // Find null after name
            let nameStart = data.index(after: spaceIdx)
            guard let nullIdx = data[nameStart...].firstIndex(of: 0) else { break }
            let nameData = data[nameStart..<nullIdx]
            guard let name = String(data: nameData, encoding: .utf8) else { break }

            // Next 20 bytes are raw SHA
            let shaStart = data.index(after: nullIdx)
            let shaEnd = data.index(shaStart, offsetBy: 20, limitedBy: data.endIndex) ?? data.endIndex
            guard data.distance(from: shaStart, to: shaEnd) == 20 else { break }
            let sha = GitObjectId(raw: Data(data[shaStart..<shaEnd]))

            entries.append(GitTreeEntry(mode: mode, name: name, sha: sha))
            offset = shaEnd
        }

        return GitTree(id: id, entries: entries)
    }

    private func parseCommit(id: GitObjectId, data: Data) -> GitCommit? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        var treeId: GitObjectId?
        var parentIds: [GitObjectId] = []
        var author: GitSignature?
        var committer: GitSignature?
        var messageStartIndex: Int?

        for (i, line) in lines.enumerated() {
            if line.isEmpty {
                messageStartIndex = i + 1
                break
            }
            if line.hasPrefix("tree ") {
                treeId = GitObjectId(hex: String(line.dropFirst(5)))
            } else if line.hasPrefix("parent ") {
                parentIds.append(GitObjectId(hex: String(line.dropFirst(7))))
            } else if line.hasPrefix("author ") {
                author = GitSignature.parse(String(line.dropFirst(7)))
            } else if line.hasPrefix("committer ") {
                committer = GitSignature.parse(String(line.dropFirst(10)))
            }
        }

        guard let tree = treeId, let auth = author, let comm = committer else { return nil }

        let message: String
        if let start = messageStartIndex, start < lines.count {
            message = lines[start...].joined(separator: "\n")
        } else {
            message = ""
        }

        return GitCommit(
            id: id,
            treeId: tree,
            parentIds: parentIds,
            author: auth,
            committer: comm,
            message: message
        )
    }

    // MARK: - Zlib (via Darwin's libz)

    private func zlibDecompress(_ data: Data) -> Data? {
        // Git loose objects use zlib format (RFC 1950), wbits = 15
        var stream = z_stream()
        var result = Data()
        let bufferSize = 65536
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        let initResult = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int32 in
            guard let ptr = bytes.baseAddress else { return Z_ERRNO }
            stream.next_in = UnsafeMutablePointer(mutating: ptr.assumingMemoryBound(to: UInt8.self))
            stream.avail_in = uInt(data.count)
            return inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        }
        guard initResult == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        repeat {
            stream.next_out = UnsafeMutablePointer(&buffer)
            stream.avail_out = uInt(bufferSize)
            let status = inflate(&stream, Z_NO_FLUSH)
            guard status == Z_OK || status == Z_STREAM_END else { return nil }
            let produced = bufferSize - Int(stream.avail_out)
            result.append(buffer, count: produced)
            if status == Z_STREAM_END { break }
        } while stream.avail_in > 0

        return result
    }

    private func zlibCompress(_ data: Data) -> Data? {
        let bufferSize = Int(compressBound(uLong(data.count)))
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var destLen = uLong(bufferSize)

        let result = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int32 in
            guard let ptr = bytes.baseAddress else { return Z_ERRNO }
            return compress2(&buffer, &destLen, ptr.assumingMemoryBound(to: UInt8.self), uLong(data.count), Z_DEFAULT_COMPRESSION)
        }
        guard result == Z_OK else { return nil }
        return Data(buffer[0..<Int(destLen)])
    }
}
