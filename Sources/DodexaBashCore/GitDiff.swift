import Foundation

// MARK: - Git Diff: Myers Algorithm + Tree Diff
// Pure Swift implementation of the Myers diff algorithm for computing
// line-level diffs, plus tree-level diff for comparing git tree objects.

// MARK: - Diff Types

public enum DiffLineType: String, Codable, Sendable {
    case context    // unchanged line
    case addition   // added in new
    case deletion   // removed from old
}

public struct DiffLine: Sendable {
    public let type: DiffLineType
    public let content: String
    public let oldLineNum: Int?
    public let newLineNum: Int?
}

public struct DiffHunk: Sendable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let lines: [DiffLine]
}

public enum FileChangeType: String, Codable, Sendable {
    case added
    case deleted
    case modified
    case renamed
}

public struct FileDiff: Sendable {
    public let path: String
    public let oldPath: String?    // for renames
    public let changeType: FileChangeType
    public let hunks: [DiffHunk]
    public let oldMode: String?
    public let newMode: String?

    public var addedLines: Int { hunks.flatMap(\.lines).filter { $0.type == .addition }.count }
    public var deletedLines: Int { hunks.flatMap(\.lines).filter { $0.type == .deletion }.count }
}

public struct GitDiffResult: Sendable {
    public let files: [FileDiff]

    public var totalAdded: Int { files.reduce(0) { $0 + $1.addedLines } }
    public var totalDeleted: Int { files.reduce(0) { $0 + $1.deletedLines } }
    public var filesChanged: Int { files.count }

    public var stat: String {
        "\(filesChanged) file(s) changed, \(totalAdded) insertion(s)(+), \(totalDeleted) deletion(s)(-)"
    }
}

// MARK: - Myers Diff Algorithm

public enum MyersDiff {
    /// Compute the shortest edit script between two sequences of lines.
    public static func diff(old: [String], new: [String], contextLines: Int = 3) -> [DiffHunk] {
        let n = old.count
        let m = new.count
        let max = n + m

        guard max > 0 else { return [] }

        // Myers algorithm: find shortest edit script
        var trace: [[Int: Int]] = []
        var v: [Int: Int] = [1: 0]  // V[1] = 0

        var found = false
        for d in 0...max {
            trace.append(v)
            var newV = v

            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && (v[k - 1] ?? 0) < (v[k + 1] ?? 0)) {
                    x = v[k + 1] ?? 0  // move down
                } else {
                    x = (v[k - 1] ?? 0) + 1  // move right
                }
                var y = x - k

                // Follow diagonal (matching lines)
                while x < n && y < m && old[x] == new[y] {
                    x += 1
                    y += 1
                }

                newV[k] = x

                if x >= n && y >= m {
                    trace.append(newV)
                    found = true
                    break
                }
            }

            v = newV
            if found { break }
        }

        // Backtrack to find the edit sequence
        let edits = backtrack(trace: trace, n: n, m: m)

        // Convert edits to hunks with context
        return buildHunks(edits: edits, old: old, new: new, contextLines: contextLines)
    }

    private enum EditType {
        case equal
        case insert
        case delete
    }

    private struct Edit {
        let type: EditType
        let oldIdx: Int?
        let newIdx: Int?
    }

    private static func backtrack(trace: [[Int: Int]], n: Int, m: Int) -> [Edit] {
        var edits: [Edit] = []
        var x = n
        var y = m

        for d in stride(from: trace.count - 2, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y

            let prevK: Int
            if k == -d || (k != d && (v[k - 1] ?? 0) < (v[k + 1] ?? 0)) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }

            let prevX = v[prevK] ?? 0
            let prevY = prevX - prevK

            // Diagonal (equal lines)
            while x > prevX && y > prevY {
                x -= 1
                y -= 1
                edits.append(Edit(type: .equal, oldIdx: x, newIdx: y))
            }

            if d > 0 {
                if x == prevX {
                    // Insert
                    y -= 1
                    edits.append(Edit(type: .insert, oldIdx: nil, newIdx: y))
                } else {
                    // Delete
                    x -= 1
                    edits.append(Edit(type: .delete, oldIdx: x, newIdx: nil))
                }
            }
        }

        return edits.reversed()
    }

    private static func buildHunks(edits: [Edit], old: [String], new: [String], contextLines: Int) -> [DiffHunk] {
        guard !edits.isEmpty else { return [] }

        // Find change regions and group with context
        var changes: [(index: Int, edit: Edit)] = []
        for (i, edit) in edits.enumerated() where edit.type != .equal {
            changes.append((i, edit))
        }

        guard !changes.isEmpty else { return [] }

        var hunks: [DiffHunk] = []
        var hunkEdits: [Edit] = []
        var lastChangeEnd = 0

        for (ci, change) in changes.enumerated() {
            let contextStart = max(0, change.index - contextLines)
            let isNewHunk = ci == 0 || contextStart > lastChangeEnd + contextLines

            if isNewHunk && !hunkEdits.isEmpty {
                // Emit previous hunk
                hunks.append(makeHunk(edits: hunkEdits, old: old, new: new))
                hunkEdits = []
            }

            if hunkEdits.isEmpty {
                // Add leading context
                let start = max(0, change.index - contextLines)
                for i in start..<change.index {
                    hunkEdits.append(edits[i])
                }
            } else {
                // Add context between changes
                let prevEnd = lastChangeEnd
                for i in (prevEnd + 1)..<change.index {
                    if i < edits.count {
                        hunkEdits.append(edits[i])
                    }
                }
            }

            hunkEdits.append(change.edit)
            lastChangeEnd = change.index

            // Add trailing context if last change
            if ci == changes.count - 1 {
                let trailEnd = min(edits.count, change.index + contextLines + 1)
                for i in (change.index + 1)..<trailEnd {
                    hunkEdits.append(edits[i])
                }
            }
        }

        if !hunkEdits.isEmpty {
            hunks.append(makeHunk(edits: hunkEdits, old: old, new: new))
        }

        return hunks
    }

    private static func makeHunk(edits: [Edit], old: [String], new: [String]) -> DiffHunk {
        var lines: [DiffLine] = []
        var oldStart = Int.max
        var newStart = Int.max
        var oldCount = 0
        var newCount = 0

        for edit in edits {
            switch edit.type {
            case .equal:
                if let oi = edit.oldIdx, let ni = edit.newIdx {
                    oldStart = min(oldStart, oi + 1)
                    newStart = min(newStart, ni + 1)
                    lines.append(DiffLine(type: .context, content: old[oi], oldLineNum: oi + 1, newLineNum: ni + 1))
                    oldCount += 1
                    newCount += 1
                }
            case .delete:
                if let oi = edit.oldIdx {
                    oldStart = min(oldStart, oi + 1)
                    lines.append(DiffLine(type: .deletion, content: old[oi], oldLineNum: oi + 1, newLineNum: nil))
                    oldCount += 1
                }
            case .insert:
                if let ni = edit.newIdx {
                    newStart = min(newStart, ni + 1)
                    lines.append(DiffLine(type: .addition, content: new[ni], oldLineNum: nil, newLineNum: ni + 1))
                    newCount += 1
                }
            }
        }

        return DiffHunk(
            oldStart: oldStart == Int.max ? 1 : oldStart,
            oldCount: oldCount,
            newStart: newStart == Int.max ? 1 : newStart,
            newCount: newCount,
            lines: lines
        )
    }
}

// MARK: - Unified Diff Formatting

public extension DiffHunk {
    var unifiedHeader: String {
        "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
    }

    func unifiedText(color: Bool = false) -> String {
        var result = unifiedHeader + "\n"
        for line in lines {
            switch line.type {
            case .context:
                result += " \(line.content)\n"
            case .addition:
                if color {
                    result += "\u{001B}[32m+\(line.content)\u{001B}[0m\n"
                } else {
                    result += "+\(line.content)\n"
                }
            case .deletion:
                if color {
                    result += "\u{001B}[31m-\(line.content)\u{001B}[0m\n"
                } else {
                    result += "-\(line.content)\n"
                }
            }
        }
        return result
    }
}

// MARK: - Tree Diff (comparing two git trees)

public enum GitTreeDiff {
    public static func diff(
        oldTree: GitTree?,
        newTree: GitTree?,
        store: GitObjectStore,
        prefix: String = ""
    ) -> [FileDiff] {
        let oldEntries = Dictionary(uniqueKeysWithValues: (oldTree?.entries ?? []).map { ($0.name, $0) })
        let newEntries = Dictionary(uniqueKeysWithValues: (newTree?.entries ?? []).map { ($0.name, $0) })
        let allNames = Set(oldEntries.keys).union(newEntries.keys).sorted()

        var diffs: [FileDiff] = []

        for name in allNames {
            let path = prefix.isEmpty ? name : prefix + "/" + name
            let oldEntry = oldEntries[name]
            let newEntry = newEntries[name]

            if let old = oldEntry, let new = newEntry {
                if old.sha == new.sha { continue }  // identical

                if old.isDirectory && new.isDirectory {
                    // Recurse into subdirectories
                    let oldSubTree = store.readTree(id: old.sha)
                    let newSubTree = store.readTree(id: new.sha)
                    diffs.append(contentsOf: diff(oldTree: oldSubTree, newTree: newSubTree, store: store, prefix: path))
                } else if !old.isDirectory && !new.isDirectory {
                    // Modified file — compute line diff
                    let oldBlob = store.readBlob(id: old.sha)
                    let newBlob = store.readBlob(id: new.sha)
                    let oldLines = (oldBlob?.text ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                    let newLines = (newBlob?.text ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                    let hunks = MyersDiff.diff(old: oldLines, new: newLines)
                    diffs.append(FileDiff(
                        path: path,
                        oldPath: nil,
                        changeType: .modified,
                        hunks: hunks,
                        oldMode: old.mode,
                        newMode: new.mode
                    ))
                }
            } else if let old = oldEntry, newEntry == nil {
                // Deleted
                diffs.append(FileDiff(
                    path: path,
                    oldPath: nil,
                    changeType: .deleted,
                    hunks: [],
                    oldMode: old.mode,
                    newMode: nil
                ))
            } else if oldEntry == nil, let new = newEntry {
                // Added
                diffs.append(FileDiff(
                    path: path,
                    oldPath: nil,
                    changeType: .added,
                    hunks: [],
                    oldMode: nil,
                    newMode: new.mode
                ))
            }
        }

        return diffs
    }
}
