import Foundation

// MARK: - Git Refs: Branch, Tag, and Remote Reference Management
// Reads/writes .git/refs/ hierarchy and packed-refs.
// All updates use .lock + rename() for atomicity.

public struct GitRef: Sendable {
    public let name: String        // e.g. "refs/heads/main"
    public let target: GitObjectId
    public let isSymbolic: Bool

    public var shortName: String {
        if name.hasPrefix("refs/heads/") { return String(name.dropFirst(11)) }
        if name.hasPrefix("refs/remotes/") { return String(name.dropFirst(13)) }
        if name.hasPrefix("refs/tags/") { return String(name.dropFirst(10)) }
        return name
    }

    public var isBranch: Bool { name.hasPrefix("refs/heads/") }
    public var isRemote: Bool { name.hasPrefix("refs/remotes/") }
    public var isTag: Bool { name.hasPrefix("refs/tags/") }
}

public final class GitRefStore: @unchecked Sendable {
    public let gitDir: URL

    public init(gitDir: URL) {
        self.gitDir = gitDir
    }

    // MARK: - HEAD

    public func resolveHEAD() -> (ref: String?, sha: GitObjectId?) {
        let headURL = gitDir.appendingPathComponent("HEAD")
        guard let content = try? String(contentsOf: headURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return (nil, nil)
        }

        if content.hasPrefix("ref: ") {
            let refName = String(content.dropFirst(5))
            let sha = resolveRef(refName)
            return (refName, sha)
        }

        // Detached HEAD — content is a raw SHA
        if content.count == 40, content.allSatisfy({ $0.isHexDigit }) {
            return (nil, GitObjectId(hex: content))
        }

        return (nil, nil)
    }

    public var currentBranch: String? {
        let (ref, _) = resolveHEAD()
        guard let ref, ref.hasPrefix("refs/heads/") else { return nil }
        return String(ref.dropFirst(11))
    }

    public var headSHA: GitObjectId? {
        resolveHEAD().sha
    }

    // MARK: - Resolve

    public func resolveRef(_ name: String) -> GitObjectId? {
        // Try loose ref first
        let refURL = gitDir.appendingPathComponent(name)
        if let content = try? String(contentsOf: refURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) {
            if content.hasPrefix("ref: ") {
                // Symbolic ref — follow it
                return resolveRef(String(content.dropFirst(5)))
            }
            if content.count == 40 {
                return GitObjectId(hex: content)
            }
        }

        // Try packed-refs
        return resolveFromPackedRefs(name)
    }

    private func resolveFromPackedRefs(_ name: String) -> GitObjectId? {
        let packedURL = gitDir.appendingPathComponent("packed-refs")
        guard let content = try? String(contentsOf: packedURL, encoding: .utf8) else { return nil }

        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("^") { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if String(parts[1]) == name {
                return GitObjectId(hex: String(parts[0]))
            }
        }
        return nil
    }

    // MARK: - List Refs

    public func listBranches() -> [GitRef] {
        listRefs(prefix: "refs/heads")
    }

    public func listRemoteBranches() -> [GitRef] {
        listRefs(prefix: "refs/remotes")
    }

    public func listTags() -> [GitRef] {
        listRefs(prefix: "refs/tags")
    }

    public func listAllRefs() -> [GitRef] {
        var refs = listBranches() + listRemoteBranches() + listTags()
        // Add packed refs not covered by loose refs
        let looseNames = Set(refs.map(\.name))
        for ref in packedRefs() where !looseNames.contains(ref.name) {
            refs.append(ref)
        }
        return refs.sorted { $0.name < $1.name }
    }

    private func listRefs(prefix: String) -> [GitRef] {
        let dir = gitDir.appendingPathComponent(prefix, isDirectory: true)
        var refs: [GitRef] = []
        listRefsRecursive(dir: dir, prefix: prefix, into: &refs)
        return refs.sorted { $0.name < $1.name }
    }

    private func listRefsRecursive(dir: URL, prefix: String, into refs: inout [GitRef]) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return }

        for entry in entries {
            let fullPath = dir.appendingPathComponent(entry)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fullPath.path, isDirectory: &isDir)

            if isDir.boolValue {
                listRefsRecursive(dir: fullPath, prefix: prefix + "/" + entry, into: &refs)
            } else {
                let refName = prefix + "/" + entry
                if let sha = resolveRef(refName) {
                    refs.append(GitRef(name: refName, target: sha, isSymbolic: false))
                }
            }
        }
    }

    private func packedRefs() -> [GitRef] {
        let packedURL = gitDir.appendingPathComponent("packed-refs")
        guard let content = try? String(contentsOf: packedURL, encoding: .utf8) else { return [] }

        var refs: [GitRef] = []
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("^") { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].count == 40 else { continue }
            refs.append(GitRef(
                name: String(parts[1]),
                target: GitObjectId(hex: String(parts[0])),
                isSymbolic: false
            ))
        }
        return refs
    }

    // MARK: - Write Refs

    public func createBranch(name: String, target: GitObjectId) throws {
        let refPath = gitDir.appendingPathComponent("refs/heads/\(name)")
        try writeRefAtomic(path: refPath, content: target.hex + "\n")
    }

    public func deleteBranch(name: String) throws {
        let refPath = gitDir.appendingPathComponent("refs/heads/\(name)")
        guard FileManager.default.fileExists(atPath: refPath.path) else {
            throw GitError.refNotFound(name)
        }
        // Don't delete current branch
        if currentBranch == name {
            throw GitError.cannotDeleteCurrentBranch
        }
        try FileManager.default.removeItem(at: refPath)
    }

    public func updateHEAD(to ref: String) throws {
        let headURL = gitDir.appendingPathComponent("HEAD")
        try writeRefAtomic(path: headURL, content: "ref: \(ref)\n")
    }

    public func updateHEADDetached(to sha: GitObjectId) throws {
        let headURL = gitDir.appendingPathComponent("HEAD")
        try writeRefAtomic(path: headURL, content: sha.hex + "\n")
    }

    public func updateRef(_ name: String, to sha: GitObjectId) throws {
        let refPath = gitDir.appendingPathComponent(name)
        let dir = refPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeRefAtomic(path: refPath, content: sha.hex + "\n")
    }

    // MARK: - Atomic Write (lock + rename)

    private func writeRefAtomic(path: URL, content: String) throws {
        let lockPath = URL(fileURLWithPath: path.path + ".lock")

        // Check for stale lock
        if FileManager.default.fileExists(atPath: lockPath.path) {
            // If lock is older than 30 seconds, remove it (stale lock)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: lockPath.path),
               let date = attrs[.modificationDate] as? Date,
               Date().timeIntervalSince(date) > 30 {
                try? FileManager.default.removeItem(at: lockPath)
            } else {
                throw GitError.lockExists(path.lastPathComponent)
            }
        }

        try Data(content.utf8).write(to: lockPath, options: .atomic)
        _ = rename(lockPath.path, path.path)
    }

    // MARK: - Ahead/Behind

    public func aheadBehind(local: GitObjectId, remote: GitObjectId, store: GitObjectStore) -> (ahead: Int, behind: Int) {
        let localAncestors = ancestorSet(from: local, store: store, limit: 200)
        let remoteAncestors = ancestorSet(from: remote, store: store, limit: 200)

        let ahead = localAncestors.subtracting(remoteAncestors).count
        let behind = remoteAncestors.subtracting(localAncestors).count
        return (ahead, behind)
    }

    private func ancestorSet(from start: GitObjectId, store: GitObjectStore, limit: Int) -> Set<GitObjectId> {
        var visited = Set<GitObjectId>()
        var queue = [start]

        while let current = queue.first, visited.count < limit {
            queue.removeFirst()
            guard !visited.contains(current) else { continue }
            visited.insert(current)
            if let commit = store.readCommit(id: current) {
                queue.append(contentsOf: commit.parentIds)
            }
        }
        return visited
    }
}

// MARK: - Git Config Parser

public struct GitConfig: Sendable {
    public var sections: [(name: String, subsection: String?, entries: [(key: String, value: String)])]

    public init() {
        self.sections = []
    }

    public static func parse(at url: URL) -> GitConfig {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return GitConfig()
        }
        return parse(content)
    }

    public static func parse(_ content: String) -> GitConfig {
        var config = GitConfig()
        var currentSection: String?
        var currentSubsection: String?
        var currentEntries: [(String, String)] = []

        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { continue }

            if trimmed.hasPrefix("[") {
                // Flush previous section
                if let section = currentSection {
                    config.sections.append((section, currentSubsection, currentEntries))
                }
                currentEntries = []

                // Parse section header
                let header = trimmed.dropFirst().dropLast() // remove [ ]
                let headerStr = String(header)
                if let spaceIdx = headerStr.firstIndex(of: " ") {
                    currentSection = String(headerStr[..<spaceIdx]).lowercased()
                    var sub = String(headerStr[headerStr.index(after: spaceIdx)...])
                        .trimmingCharacters(in: .whitespaces)
                    if sub.hasPrefix("\"") && sub.hasSuffix("\"") {
                        sub = String(sub.dropFirst().dropLast())
                    }
                    currentSubsection = sub
                } else {
                    currentSection = headerStr.lowercased()
                    currentSubsection = nil
                }
            } else if let eqIdx = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<eqIdx]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(trimmed[trimmed.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
                currentEntries.append((key, value))
            }
        }

        // Flush last section
        if let section = currentSection {
            config.sections.append((section, currentSubsection, currentEntries))
        }

        return config
    }

    public func value(section: String, key: String) -> String? {
        for s in sections where s.name == section.lowercased() && s.subsection == nil {
            for e in s.entries where e.key == key.lowercased() {
                return e.value
            }
        }
        return nil
    }

    public func value(section: String, subsection: String, key: String) -> String? {
        for s in sections where s.name == section.lowercased() && s.subsection == subsection {
            for e in s.entries where e.key == key.lowercased() {
                return e.value
            }
        }
        return nil
    }

    public func remotes() -> [(name: String, url: String, fetchSpec: String?)] {
        var result: [(String, String, String?)] = []
        for s in sections where s.name == "remote" {
            guard let name = s.subsection else { continue }
            let url = s.entries.first { $0.0 == "url" }?.1 ?? ""
            let fetch = s.entries.first { $0.0 == "fetch" }?.1
            result.append((name, url, fetch))
        }
        return result
    }

    public func userName() -> String? { value(section: "user", key: "name") }
    public func userEmail() -> String? { value(section: "user", key: "email") }
}

// MARK: - Errors

public enum GitError: Error, CustomStringConvertible {
    case notARepository
    case refNotFound(String)
    case cannotDeleteCurrentBranch
    case lockExists(String)
    case objectNotFound(GitObjectId)
    case mergeConflict(paths: [String])
    case dirtyWorkingTree
    case invalidIndex
    case authenticationFailed(String)
    case networkError(String)

    public var description: String {
        switch self {
        case .notARepository: return "not a git repository"
        case .refNotFound(let name): return "ref not found: \(name)"
        case .cannotDeleteCurrentBranch: return "cannot delete the currently checked out branch"
        case .lockExists(let name): return "lock exists for \(name) — another git process may be running"
        case .objectNotFound(let id): return "object not found: \(id.short)"
        case .mergeConflict(let paths): return "merge conflict in \(paths.count) file(s): \(paths.prefix(3).joined(separator: ", "))"
        case .dirtyWorkingTree: return "working tree has uncommitted changes"
        case .invalidIndex: return "corrupt or invalid index file"
        case .authenticationFailed(let msg): return "authentication failed: \(msg)"
        case .networkError(let msg): return "network error: \(msg)"
        }
    }
}
