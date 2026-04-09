import Foundation

// MARK: - Git Index: Staging Area (.git/index)
// Binary format parser/writer for the git index file.
// Version 2 format (most common), big-endian throughout.

public struct GitIndexEntry: Sendable {
    public let ctimeSec: UInt32
    public let ctimeNano: UInt32
    public let mtimeSec: UInt32
    public let mtimeNano: UInt32
    public let dev: UInt32
    public let ino: UInt32
    public let mode: UInt32
    public let uid: UInt32
    public let gid: UInt32
    public let size: UInt32
    public let sha: GitObjectId
    public let flags: UInt16
    public let path: String

    public var modeString: String {
        switch mode & 0xF000 {
        case 0x8000: return mode & 0x40 != 0 ? "100755" : "100644"
        case 0xA000: return "120000"
        case 0xE000: return "160000"
        default: return String(mode, radix: 8)
        }
    }

    /// Conflict stage (0=normal, 1=base, 2=ours, 3=theirs)
    public var stage: Int { Int((flags >> 12) & 0x3) }

    public static func fromFile(at path: String, relativeTo root: String, sha: GitObjectId) -> GitIndexEntry? {
        let fullPath = root + "/" + path
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fullPath) else { return nil }

        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        let size = (attrs[.size] as? UInt64) ?? 0
        let isExecutable = fm.isExecutableFile(atPath: fullPath)
        let mode: UInt32 = isExecutable ? 0o100755 : 0o100644

        let pathLen = min(path.utf8.count, 0xFFF)

        return GitIndexEntry(
            ctimeSec: UInt32(mtime.timeIntervalSince1970),
            ctimeNano: 0,
            mtimeSec: UInt32(mtime.timeIntervalSince1970),
            mtimeNano: 0,
            dev: 0,
            ino: 0,
            mode: mode,
            uid: 0,
            gid: 0,
            size: UInt32(min(size, UInt64(UInt32.max))),
            sha: sha,
            flags: UInt16(pathLen),
            path: path
        )
    }
}

public final class GitIndex: @unchecked Sendable {
    private let indexURL: URL
    public var entries: [GitIndexEntry] = []
    public private(set) var version: UInt32 = 2

    public init(gitDir: URL) {
        self.indexURL = gitDir.appendingPathComponent("index")
    }

    // MARK: - Read

    public func load() throws {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            entries = []
            return
        }
        let data = try Data(contentsOf: indexURL)
        guard data.count >= 12 else { throw GitError.invalidIndex }

        // Header: DIRC + version (4 bytes) + entry count (4 bytes)
        let magic = String(data: data[0..<4], encoding: .ascii)
        guard magic == "DIRC" else { throw GitError.invalidIndex }

        version = readUInt32(data, offset: 4)
        let count = readUInt32(data, offset: 8)

        var offset = 12
        var parsed: [GitIndexEntry] = []

        for _ in 0..<count {
            guard offset + 62 <= data.count else { throw GitError.invalidIndex }

            let ctimeSec = readUInt32(data, offset: offset)
            let ctimeNano = readUInt32(data, offset: offset + 4)
            let mtimeSec = readUInt32(data, offset: offset + 8)
            let mtimeNano = readUInt32(data, offset: offset + 12)
            let dev = readUInt32(data, offset: offset + 16)
            let ino = readUInt32(data, offset: offset + 20)
            let mode = readUInt32(data, offset: offset + 24)
            let uid = readUInt32(data, offset: offset + 28)
            let gid = readUInt32(data, offset: offset + 32)
            let size = readUInt32(data, offset: offset + 36)

            let shaData = data[(offset + 40)..<(offset + 60)]
            let sha = GitObjectId(raw: Data(shaData))
            let flags = readUInt16(data, offset: offset + 60)

            // Path starts at offset + 62
            let pathStart = offset + 62
            let nameLen = Int(flags & 0xFFF)

            // Find the null terminator
            var pathEnd = pathStart + nameLen
            if pathEnd < data.count && data[pathEnd] == 0 {
                // Good — use nameLen
            } else {
                // Scan for null
                pathEnd = pathStart
                while pathEnd < data.count && data[pathEnd] != 0 {
                    pathEnd += 1
                }
            }

            let pathData = data[pathStart..<pathEnd]
            let path = String(data: pathData, encoding: .utf8) ?? ""

            parsed.append(GitIndexEntry(
                ctimeSec: ctimeSec, ctimeNano: ctimeNano,
                mtimeSec: mtimeSec, mtimeNano: mtimeNano,
                dev: dev, ino: ino, mode: mode, uid: uid, gid: gid,
                size: size, sha: sha, flags: flags, path: path
            ))

            // Entries are padded to 8-byte boundaries (measured from start of entry)
            let entryLen = 62 + pathEnd - pathStart + 1  // +1 for at least one NUL
            let padded = (entryLen + 7) & ~7
            offset += padded
        }

        entries = parsed
    }

    // MARK: - Write

    public func save() throws {
        var data = Data()

        // Header
        data.append(contentsOf: "DIRC".utf8)
        appendUInt32(&data, version)
        appendUInt32(&data, UInt32(entries.count))

        // Sort entries by path
        let sorted = entries.sorted { $0.path < $1.path }

        for entry in sorted {
            let entryStart = data.count

            appendUInt32(&data, entry.ctimeSec)
            appendUInt32(&data, entry.ctimeNano)
            appendUInt32(&data, entry.mtimeSec)
            appendUInt32(&data, entry.mtimeNano)
            appendUInt32(&data, entry.dev)
            appendUInt32(&data, entry.ino)
            appendUInt32(&data, entry.mode)
            appendUInt32(&data, entry.uid)
            appendUInt32(&data, entry.gid)
            appendUInt32(&data, entry.size)
            data.append(entry.sha.raw)
            appendUInt16(&data, entry.flags)
            data.append(contentsOf: entry.path.utf8)
            data.append(0)  // NUL terminator

            // Pad to 8-byte boundary
            let entryLen = data.count - entryStart
            let padded = (entryLen + 7) & ~7
            let padding = padded - entryLen
            for _ in 0..<padding {
                data.append(0)
            }
        }

        // Write atomically via lock file
        let lockURL = URL(fileURLWithPath: indexURL.path + ".lock")
        try data.write(to: lockURL, options: .atomic)
        _ = rename(lockURL.path, indexURL.path)
    }

    // MARK: - Stage / Unstage

    public func stage(path: String, sha: GitObjectId, rootDir: String) {
        // Remove existing entry for this path
        entries.removeAll { $0.path == path }

        // Add new entry
        if let entry = GitIndexEntry.fromFile(at: path, relativeTo: rootDir, sha: sha) {
            entries.append(entry)
        }
    }

    public func unstage(path: String) {
        entries.removeAll { $0.path == path }
    }

    // MARK: - Query

    public func entry(for path: String) -> GitIndexEntry? {
        entries.first { $0.path == path }
    }

    public var stagedPaths: [String] {
        entries.map(\.path).sorted()
    }

    public var conflictedPaths: [String] {
        entries.filter { $0.stage != 0 }.map(\.path)
    }

    // MARK: - Binary Helpers

    private func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        let bytes = data[offset..<(offset + 4)]
        return bytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }

    private func readUInt16(_ data: Data, offset: Int) -> UInt16 {
        let bytes = data[offset..<(offset + 2)]
        return bytes.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
    }

    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var big = value.bigEndian
        data.append(Data(bytes: &big, count: 4))
    }

    private func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var big = value.bigEndian
        data.append(Data(bytes: &big, count: 2))
    }
}
