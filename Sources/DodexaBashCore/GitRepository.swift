import Foundation

// MARK: - Git Repository: High-Level Operations
// Ties together GitObjectStore, GitRefStore, GitIndex, GitDiff, and GitAuth
// into a complete native git implementation.

public struct GitStatus: Sendable {
    public let branch: String?
    public let headSHA: GitObjectId?
    public let staged: [GitFileChange]
    public let modified: [GitFileChange]
    public let untracked: [String]
    public let conflicted: [String]
    public let aheadBehind: (ahead: Int, behind: Int)?

    public var isClean: Bool { staged.isEmpty && modified.isEmpty && untracked.isEmpty && conflicted.isEmpty }
}

public struct GitFileChange: Sendable {
    public let path: String
    public let changeType: FileChangeType
}

public struct GitLogEntry: Sendable {
    public let commit: GitCommit
    public let refs: [String]  // branch/tag names pointing at this commit
}

public final class GitRepository: @unchecked Sendable {
    public let rootDir: URL       // working tree root
    public let gitDir: URL        // .git directory
    public let objects: GitObjectStore
    public let refs: GitRefStore
    public var index: GitIndex
    public let config: GitConfig

    private init(rootDir: URL, gitDir: URL) {
        self.rootDir = rootDir
        self.gitDir = gitDir
        self.objects = GitObjectStore(gitDir: gitDir)
        self.refs = GitRefStore(gitDir: gitDir)
        self.index = GitIndex(gitDir: gitDir)
        self.config = GitConfig.parse(at: gitDir.appendingPathComponent("config"))
    }

    // MARK: - Open / Discover

    public static func open(at path: String) throws -> GitRepository {
        let url = URL(fileURLWithPath: path)
        return try open(at: url)
    }

    public static func open(at url: URL) throws -> GitRepository {
        // Walk up looking for .git
        var current = url.standardizedFileURL
        let fm = FileManager.default

        while true {
            let gitDir = current.appendingPathComponent(".git")
            var isDir: ObjCBool = false

            if fm.fileExists(atPath: gitDir.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    return GitRepository(rootDir: current, gitDir: gitDir)
                }
                // Worktree: .git is a file containing "gitdir: <path>"
                if let content = try? String(contentsOf: gitDir, encoding: .utf8),
                   let range = content.range(of: "gitdir: ") {
                    let rawPath = String(content[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolved = URL(fileURLWithPath: rawPath, relativeTo: current).standardizedFileURL
                    return GitRepository(rootDir: current, gitDir: resolved)
                }
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                throw GitError.notARepository
            }
            current = parent
        }
    }

    // MARK: - Init

    public static func initRepo(at path: String, bare: Bool = false) throws -> GitRepository {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: path)
        let gitDir = bare ? rootURL : rootURL.appendingPathComponent(".git")

        try fm.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: gitDir.appendingPathComponent("objects"), withIntermediateDirectories: true)
        try fm.createDirectory(at: gitDir.appendingPathComponent("refs/heads"), withIntermediateDirectories: true)
        try fm.createDirectory(at: gitDir.appendingPathComponent("refs/tags"), withIntermediateDirectories: true)

        // HEAD -> refs/heads/main
        try Data("ref: refs/heads/main\n".utf8).write(to: gitDir.appendingPathComponent("HEAD"))

        // Minimal config
        let configContent = """
        [core]
        \trepositoryformatversion = 0
        \tfilemode = true
        \tbare = \(bare)

        """
        try Data(configContent.utf8).write(to: gitDir.appendingPathComponent("config"))

        return try GitRepository.open(at: path)
    }

    // MARK: - Status

    public func status() -> GitStatus {
        try? index.load()

        let branch = refs.currentBranch
        let headSHA = refs.headSHA
        let indexEntries = Dictionary(uniqueKeysWithValues: index.entries.map { ($0.path, $0) })

        // Get HEAD tree for staged diff
        var headTreeEntries: [String: GitObjectId] = [:]
        if let head = headSHA, let commit = objects.readCommit(id: head) {
            headTreeEntries = flattenTree(id: commit.treeId, prefix: "")
        }

        // Compute staged changes (index vs HEAD)
        var staged: [GitFileChange] = []
        for (path, entry) in indexEntries where entry.stage == 0 {
            if let headSHA = headTreeEntries[path] {
                if headSHA != entry.sha {
                    staged.append(GitFileChange(path: path, changeType: .modified))
                }
            } else {
                staged.append(GitFileChange(path: path, changeType: .added))
            }
        }
        for path in headTreeEntries.keys where indexEntries[path] == nil {
            staged.append(GitFileChange(path: path, changeType: .deleted))
        }

        // Compute working tree changes (working tree vs index)
        var modified: [GitFileChange] = []
        var untracked: [String] = []
        let workingFiles = listWorkingTree()

        for file in workingFiles {
            if let entry = indexEntries[file] {
                // Check if file has been modified since index
                let fullPath = rootDir.appendingPathComponent(file).path
                if let currentSHA = objects.hashFile(at: fullPath), currentSHA != entry.sha {
                    modified.append(GitFileChange(path: file, changeType: .modified))
                }
            } else {
                untracked.append(file)
            }
        }

        // Check for deleted files (in index but not in working tree)
        for path in indexEntries.keys {
            if !workingFiles.contains(path) {
                modified.append(GitFileChange(path: path, changeType: .deleted))
            }
        }

        // Conflicts
        let conflicted = index.conflictedPaths

        // Ahead/behind
        var ab: (Int, Int)?
        if let branch, let localSHA = headSHA {
            // Find upstream tracking branch
            let trackingRef = config.value(section: "branch", subsection: branch, key: "merge")
            let trackingRemote = config.value(section: "branch", subsection: branch, key: "remote") ?? "origin"
            if let trackingRef {
                let remoteBranch = trackingRef.replacingOccurrences(of: "refs/heads/", with: "")
                let remoteRef = "refs/remotes/\(trackingRemote)/\(remoteBranch)"
                if let remoteSHA = refs.resolveRef(remoteRef) {
                    ab = refs.aheadBehind(local: localSHA, remote: remoteSHA, store: objects)
                }
            }
        }

        return GitStatus(
            branch: branch,
            headSHA: headSHA,
            staged: staged.sorted { $0.path < $1.path },
            modified: modified.sorted { $0.path < $1.path },
            untracked: untracked.sorted(),
            conflicted: conflicted.sorted(),
            aheadBehind: ab
        )
    }

    // MARK: - Log

    public func log(limit: Int = 20, from: GitObjectId? = nil) -> [GitLogEntry] {
        guard let startSHA = from ?? refs.headSHA else { return [] }

        // Build ref map
        var refMap: [GitObjectId: [String]] = [:]
        for ref in refs.listAllRefs() {
            refMap[ref.target, default: []].append(ref.shortName)
        }

        var entries: [GitLogEntry] = []
        var visited = Set<GitObjectId>()
        var queue = [startSHA]

        while let sha = queue.first, entries.count < limit {
            queue.removeFirst()
            guard !visited.contains(sha) else { continue }
            visited.insert(sha)

            guard let commit = objects.readCommit(id: sha) else { continue }
            entries.append(GitLogEntry(commit: commit, refs: refMap[sha] ?? []))

            // Add parents (first parent first for linear history)
            queue.append(contentsOf: commit.parentIds)
            // Sort by timestamp (newest first) for merge commit ordering
            queue.sort { a, b in
                let aCommit = objects.readCommit(id: a)
                let bCommit = objects.readCommit(id: b)
                return (aCommit?.committer.timestamp ?? .distantPast) > (bCommit?.committer.timestamp ?? .distantPast)
            }
        }

        return entries
    }

    // MARK: - Diff

    public func diffStaged() -> GitDiffResult {
        try? index.load()
        guard let headSHA = refs.headSHA,
              let commit = objects.readCommit(id: headSHA) else {
            return GitDiffResult(files: [])
        }

        let headTree = objects.readTree(id: commit.treeId)
        let indexTree = buildTreeFromIndex()
        let diffs = GitTreeDiff.diff(oldTree: headTree, newTree: indexTree, store: objects)
        return GitDiffResult(files: diffs)
    }

    public func diffWorkingTree(paths: [String]? = nil) -> [FileDiff] {
        try? index.load()
        var diffs: [FileDiff] = []
        let indexEntries = Dictionary(uniqueKeysWithValues: index.entries.map { ($0.path, $0) })
        let filterPaths = paths.map(Set.init)

        for (path, entry) in indexEntries where entry.stage == 0 {
            if let filter = filterPaths, !filter.contains(path) { continue }

            let fullPath = rootDir.appendingPathComponent(path).path
            guard let currentContent = try? String(contentsOfFile: fullPath, encoding: .utf8) else {
                // File deleted
                diffs.append(FileDiff(path: path, oldPath: nil, changeType: .deleted, hunks: [], oldMode: entry.modeString, newMode: nil))
                continue
            }

            guard let currentSHA = objects.hashFile(at: fullPath), currentSHA != entry.sha else { continue }

            // File modified — compute diff
            let oldContent = objects.readBlob(id: entry.sha)?.text ?? ""
            let oldLines = oldContent.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let newLines = currentContent.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let hunks = MyersDiff.diff(old: oldLines, new: newLines)

            diffs.append(FileDiff(path: path, oldPath: nil, changeType: .modified, hunks: hunks, oldMode: entry.modeString, newMode: entry.modeString))
        }

        return diffs.sorted { $0.path < $1.path }
    }

    // MARK: - Add (Stage)

    public func add(paths: [String]) throws {
        try index.load()

        for path in paths {
            let fullPath: String
            if path.hasPrefix("/") {
                fullPath = path
            } else {
                fullPath = rootDir.appendingPathComponent(path).path
            }

            let relativePath = makeRelative(fullPath)
            let fm = FileManager.default

            if fm.fileExists(atPath: fullPath) {
                // Read file and create blob
                guard let content = try? Data(contentsOf: URL(fileURLWithPath: fullPath)) else { continue }
                let blobSHA = objects.writeBlob(content: content)
                index.stage(path: relativePath, sha: blobSHA, rootDir: rootDir.path)
            } else {
                // File deleted — remove from index
                index.unstage(path: relativePath)
            }
        }

        try index.save()
    }

    // MARK: - Commit

    public func commit(message: String, author: GitSignature? = nil) throws -> GitCommit {
        try index.load()

        // Build tree from index
        let treeSHA = buildTreeSHAFromIndex()

        // Get parent
        var parents: [GitObjectId] = []
        if let headSHA = refs.headSHA {
            parents.append(headSHA)
        }

        // Author/committer
        let sig = author ?? defaultSignature()

        // Create commit object
        let commitSHA = objects.writeCommit(
            treeId: treeSHA,
            parentIds: parents,
            author: sig,
            committer: sig,
            message: message
        )

        // Update HEAD
        let (headRef, _) = refs.resolveHEAD()
        if let ref = headRef {
            try refs.updateRef(ref, to: commitSHA)
        } else {
            try refs.updateHEADDetached(to: commitSHA)
        }

        return objects.readCommit(id: commitSHA)!
    }

    // MARK: - Branch

    public func createBranch(name: String, at: GitObjectId? = nil) throws {
        let target = at ?? refs.headSHA
        guard let sha = target else { throw GitError.refNotFound("HEAD") }
        try refs.createBranch(name: name, target: sha)
    }

    public func deleteBranch(name: String) throws {
        try refs.deleteBranch(name: name)
    }

    public func checkout(branch: String) throws {
        let refName = "refs/heads/\(branch)"
        guard let sha = refs.resolveRef(refName) else {
            throw GitError.refNotFound(branch)
        }

        // Update HEAD to point to the branch
        try refs.updateHEAD(to: refName)

        // Update working tree (simplified: just update index)
        guard let commit = objects.readCommit(id: sha) else {
            throw GitError.objectNotFound(sha)
        }

        // Rebuild index from the commit's tree
        let treeEntries = flattenTree(id: commit.treeId, prefix: "")
        index.entries.removeAll()
        for (path, entrySHA) in treeEntries.sorted(by: { $0.key < $1.key }) {
            index.stage(path: path, sha: entrySHA, rootDir: rootDir.path)
        }
        try index.save()

        // Checkout files from the tree
        for (path, entrySHA) in treeEntries {
            let fullPath = rootDir.appendingPathComponent(path)
            if let blob = objects.readBlob(id: entrySHA) {
                let dir = fullPath.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try blob.content.write(to: fullPath, options: .atomic)
            }
        }
    }

    // MARK: - Merge (simplified three-way)

    public func merge(branch: String) throws -> GitCommit {
        let theirRef = "refs/heads/\(branch)"
        guard let theirSHA = refs.resolveRef(theirRef) else {
            throw GitError.refNotFound(branch)
        }
        guard let ourSHA = refs.headSHA else {
            throw GitError.refNotFound("HEAD")
        }

        // Fast-forward check
        let theirAncestors = ancestorSet(from: theirSHA, limit: 500)
        if theirAncestors.contains(ourSHA) {
            // Already up to date (their branch is behind or at our HEAD)
            // Actually check if we need to fast-forward
        }

        let ourAncestors = ancestorSet(from: ourSHA, limit: 500)
        if ourAncestors.contains(theirSHA) {
            // Their branch is an ancestor of ours — nothing to merge
            throw GitError.refNotFound("already up to date")
        }

        // Find merge base
        let mergeBase = ourAncestors.intersection(theirAncestors).first

        // If our HEAD is ancestor of theirs: fast-forward
        if mergeBase == ourSHA {
            guard let commit = objects.readCommit(id: theirSHA) else {
                throw GitError.objectNotFound(theirSHA)
            }
            let (headRef, _) = refs.resolveHEAD()
            if let ref = headRef {
                try refs.updateRef(ref, to: theirSHA)
            }
            try checkout(branch: refs.currentBranch ?? branch)
            return commit
        }

        // True merge — create merge commit
        guard let theirCommit = objects.readCommit(id: theirSHA) else {
            throw GitError.objectNotFound(theirSHA)
        }

        // For now: use their tree (simplified merge)
        // TODO: proper three-way tree merge with conflict detection
        let sig = defaultSignature()
        let currentBranch = refs.currentBranch ?? "HEAD"
        let mergeMessage = "Merge branch '\(branch)' into \(currentBranch)"
        let mergeSHA = objects.writeCommit(
            treeId: theirCommit.treeId,
            parentIds: [ourSHA, theirSHA],
            author: sig,
            committer: sig,
            message: mergeMessage
        )

        let (headRef, _) = refs.resolveHEAD()
        if let ref = headRef {
            try refs.updateRef(ref, to: mergeSHA)
        }

        return objects.readCommit(id: mergeSHA)!
    }

    // MARK: - Stash

    public func stash(message: String? = nil) throws -> GitObjectId {
        try index.load()
        let status = self.status()
        guard !status.isClean else { throw GitError.dirtyWorkingTree }

        // Create a commit that captures current state (not on any branch)
        let treeSHA = buildTreeSHAFromIndex()
        let sig = defaultSignature()
        let msg = message ?? "WIP on \(refs.currentBranch ?? "detached")"

        let stashSHA = objects.writeCommit(
            treeId: treeSHA,
            parentIds: refs.headSHA.map { [$0] } ?? [],
            author: sig,
            committer: sig,
            message: msg
        )

        // Append to stash reflog
        let stashFile = gitDir.appendingPathComponent("refs/stash")
        try? FileManager.default.createDirectory(at: stashFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((stashSHA.hex + "\n").utf8).write(to: stashFile, options: .atomic)

        // Reset working tree to HEAD
        if let headSHA = refs.headSHA, let commit = objects.readCommit(id: headSHA) {
            let treeEntries = flattenTree(id: commit.treeId, prefix: "")
            for (path, entrySHA) in treeEntries {
                let fullPath = rootDir.appendingPathComponent(path)
                if let blob = objects.readBlob(id: entrySHA) {
                    try blob.content.write(to: fullPath, options: .atomic)
                }
            }
        }

        return stashSHA
    }

    public func stashPop() throws {
        let stashFile = gitDir.appendingPathComponent("refs/stash")
        guard let content = try? String(contentsOf: stashFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw GitError.refNotFound("No stash entries")
        }

        let sha = GitObjectId(hex: content)
        guard let commit = objects.readCommit(id: sha) else {
            throw GitError.objectNotFound(sha)
        }

        // Apply stashed tree to working directory
        let treeEntries = flattenTree(id: commit.treeId, prefix: "")
        for (path, entrySHA) in treeEntries {
            let fullPath = rootDir.appendingPathComponent(path)
            if let blob = objects.readBlob(id: entrySHA) {
                let dir = fullPath.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try blob.content.write(to: fullPath, options: .atomic)
            }
        }

        // Remove stash ref
        try? FileManager.default.removeItem(at: stashFile)
    }

    // MARK: - Commit Graph (ASCII visualization)

    public func commitGraph(limit: Int = 20) -> String {
        let entries = log(limit: limit)
        guard !entries.isEmpty else { return "No commits.\n" }

        var lines: [String] = []
        var activeLanes: [GitObjectId] = []

        for entry in entries {
            let commit = entry.commit

            // Find or assign lane
            let lane: Int
            if let existing = activeLanes.firstIndex(of: commit.id) {
                lane = existing
            } else if let emptyLane = activeLanes.firstIndex(where: { id in !entries.contains(where: { $0.commit.parentIds.contains(id) }) }) {
                lane = emptyLane
                activeLanes[lane] = commit.id
            } else {
                lane = activeLanes.count
                activeLanes.append(commit.id)
            }

            // Build graph prefix
            var prefix = ""
            for i in 0..<activeLanes.count {
                if i == lane {
                    prefix += "* "
                } else {
                    prefix += "| "
                }
            }

            // Replace this commit's lane with first parent
            if let firstParent = commit.parentIds.first {
                if lane < activeLanes.count {
                    activeLanes[lane] = firstParent
                }
            } else {
                // Root commit — remove lane
                if lane < activeLanes.count {
                    activeLanes.remove(at: lane)
                }
            }

            // Format entry
            let refs = entry.refs.isEmpty ? "" : " (\(entry.refs.joined(separator: ", ")))"
            let date = formatRelativeDate(commit.committer.timestamp)
            lines.append("\(prefix)\u{001B}[33m\(commit.id.short)\u{001B}[0m\u{001B}[32m\(refs)\u{001B}[0m \(commit.summary)")
            lines.append("\(String(repeating: "| ", count: max(0, lane))) \u{001B}[2m\(commit.author.name), \(date)\u{001B}[0m")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Helpers

    public func defaultSignature() -> GitSignature {
        // Try repo config, then global config, then fallback
        let name = config.userName() ?? globalConfig()?.userName() ?? "dodexabash"
        let email = config.userEmail() ?? globalConfig()?.userEmail() ?? "user@dodexabash.local"

        // Calculate timezone offset
        let tz = TimeZone.current
        let seconds = tz.secondsFromGMT()
        let hours = abs(seconds) / 3600
        let mins = (abs(seconds) % 3600) / 60
        let sign = seconds >= 0 ? "+" : "-"
        let tzString = String(format: "%@%02d%02d", sign, hours, mins)

        return GitSignature(name: name, email: email, timestamp: Date(), tzOffset: tzString)
    }

    private func globalConfig() -> GitConfig? {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let url = URL(fileURLWithPath: home + "/.gitconfig")
        return GitConfig.parse(at: url)
    }

    func flattenTree(id: GitObjectId, prefix: String) -> [String: GitObjectId] {
        guard let tree = objects.readTree(id: id) else { return [:] }
        var result: [String: GitObjectId] = [:]

        for entry in tree.entries {
            let path = prefix.isEmpty ? entry.name : prefix + "/" + entry.name
            if entry.isDirectory {
                let sub = flattenTree(id: entry.sha, prefix: path)
                result.merge(sub) { _, new in new }
            } else {
                result[path] = entry.sha
            }
        }
        return result
    }

    private func buildTreeFromIndex() -> GitTree? {
        // Build a synthetic tree from index entries for comparison
        let entries = index.entries.filter { $0.stage == 0 }.map { entry in
            GitTreeEntry(mode: entry.modeString, name: entry.path, sha: entry.sha)
        }
        return GitTree(id: GitObjectId(hex: String(repeating: "0", count: 40)), entries: entries)
    }

    private func buildTreeSHAFromIndex() -> GitObjectId {
        // Build actual tree objects from index, respecting directory structure
        struct TreeNode {
            var entries: [GitTreeEntry] = []
            var children: [String: TreeNode] = [:]
        }

        var root = TreeNode()

        for entry in index.entries where entry.stage == 0 {
            let components = entry.path.split(separator: "/").map(String.init)
            var node = root

            for (i, component) in components.enumerated() {
                if i == components.count - 1 {
                    // Leaf — file entry
                    node.entries.append(GitTreeEntry(
                        mode: entry.modeString,
                        name: component,
                        sha: entry.sha
                    ))
                } else {
                    if node.children[component] == nil {
                        node.children[component] = TreeNode()
                    }
                }
            }
            // Rebuild root path (this simplified version handles flat files)
            // For nested dirs, we'd need recursive tree building
            if components.count == 1 {
                root.entries.append(GitTreeEntry(
                    mode: entry.modeString,
                    name: entry.path,
                    sha: entry.sha
                ))
            }
        }

        return objects.writeTree(entries: root.entries)
    }

    private func listWorkingTree() -> Set<String> {
        var files = Set<String>()
        let fm = FileManager.default
        let rootPath = rootDir.standardizedFileURL.path

        guard let enumerator = fm.enumerator(
            at: rootDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return files }

        while let url = enumerator.nextObject() as? URL {
            // Skip .git directory
            if url.path.contains("/.git/") || url.path.hasSuffix("/.git") {
                enumerator.skipDescendants()
                continue
            }
            // Skip common ignore patterns
            let name = url.lastPathComponent
            if name == ".DS_Store" || name == "node_modules" || name == ".build" || name == ".dodexabash" {
                if url.hasDirectoryPath { enumerator.skipDescendants() }
                continue
            }

            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            if !isDir.boolValue {
                let resolvedPath = url.standardizedFileURL.path
                guard resolvedPath.hasPrefix(rootPath + "/") else { continue }
                let relative = String(resolvedPath.dropFirst(rootPath.count + 1))
                files.insert(relative)
            }
        }

        return files
    }

    private func makeRelative(_ absolutePath: String) -> String {
        let root = rootDir.path
        if absolutePath.hasPrefix(root + "/") {
            return String(absolutePath.dropFirst(root.count + 1))
        }
        return absolutePath
    }

    private func ancestorSet(from start: GitObjectId, limit: Int) -> Set<GitObjectId> {
        var visited = Set<GitObjectId>()
        var queue = [start]
        while let current = queue.first, visited.count < limit {
            queue.removeFirst()
            guard !visited.contains(current) else { continue }
            visited.insert(current)
            if let commit = objects.readCommit(id: current) {
                queue.append(contentsOf: commit.parentIds)
            }
        }
        return visited
    }

    private func formatRelativeDate(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86400 { return "\(seconds / 3600) hours ago" }
        if seconds < 604800 { return "\(seconds / 86400) days ago" }
        if seconds < 2592000 { return "\(seconds / 604800) weeks ago" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
