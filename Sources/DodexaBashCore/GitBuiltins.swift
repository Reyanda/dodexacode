import Foundation

// MARK: - Git Builtins: Shell commands for native git operations
// Separate file from Builtins.swift to keep the codebase modular.

extension Builtins {
    static func gitBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let sub = args.first ?? "status"
        let subArgs = Array(args.dropFirst())
        let cwd = runtime.context.currentDirectory

        // Commands that don't require a repository
        switch sub {
        case "init":
            return gitInit(args: subArgs, runtime: runtime)
        case "auth":
            return gitAuth(args: subArgs, runtime: runtime)
        default:
            break
        }

        let repo: GitRepository
        do {
            repo = try GitRepository.open(at: cwd)
        } catch {
            return CommandResult(status: 1, io: ShellIO(stderr: Data("fatal: \(error)\n".utf8)))
        }

        switch sub {
        case "status", "st":
            return gitStatus(repo: repo)
        case "log":
            return gitLog(repo: repo, args: subArgs)
        case "diff":
            return gitDiffCmd(repo: repo, args: subArgs)
        case "branch", "br":
            return gitBranch(repo: repo, args: subArgs)
        case "add":
            return gitAdd(repo: repo, args: subArgs)
        case "commit":
            return gitCommitCmd(repo: repo, args: subArgs, runtime: runtime)
        case "checkout", "switch", "co":
            return gitCheckout(repo: repo, args: subArgs)
        case "merge":
            return gitMerge(repo: repo, args: subArgs)
        case "stash":
            return gitStash(repo: repo, args: subArgs)
        case "remote":
            return gitRemote(repo: repo, args: subArgs)
        case "tree", "graph":
            return gitTree(repo: repo, args: subArgs)
        case "auth":
            return gitAuth(args: subArgs, runtime: runtime)
        case "init":
            return gitInit(args: subArgs, runtime: runtime)
        case "tag":
            return gitTag(repo: repo, args: subArgs)
        default:
            return textResult("git: '\(sub)' is not a dodexabash git command.\nSupported: status, log, diff, branch, add, commit, checkout, merge, stash, remote, tree, auth, init, tag\n")
        }
    }

    // MARK: - Status

    private static func gitStatus(repo: GitRepository) -> CommandResult {
        let status = repo.status()
        var lines: [String] = []

        if let branch = status.branch {
            var branchLine = "On branch \u{001B}[32m\(branch)\u{001B}[0m"
            if let ab = status.aheadBehind {
                if ab.ahead > 0 && ab.behind > 0 {
                    branchLine += " [\u{001B}[32m+\(ab.ahead)\u{001B}[0m/\u{001B}[31m-\(ab.behind)\u{001B}[0m]"
                } else if ab.ahead > 0 {
                    branchLine += " [\u{001B}[32mahead \(ab.ahead)\u{001B}[0m]"
                } else if ab.behind > 0 {
                    branchLine += " [\u{001B}[31mbehind \(ab.behind)\u{001B}[0m]"
                }
            }
            lines.append(branchLine)
        } else if let sha = status.headSHA {
            lines.append("HEAD detached at \u{001B}[33m\(sha.short)\u{001B}[0m")
        }

        if !status.staged.isEmpty {
            lines.append("")
            lines.append("Changes to be committed:")
            for change in status.staged {
                let tag: String
                switch change.changeType {
                case .added: tag = "new file"
                case .modified: tag = "modified"
                case .deleted: tag = "deleted"
                case .renamed: tag = "renamed"
                }
                lines.append("  \u{001B}[32m\(tag):   \(change.path)\u{001B}[0m")
            }
        }

        if !status.modified.isEmpty {
            lines.append("")
            lines.append("Changes not staged for commit:")
            for change in status.modified {
                lines.append("  \u{001B}[31m\(change.changeType.rawValue):   \(change.path)\u{001B}[0m")
            }
        }

        if !status.untracked.isEmpty {
            lines.append("")
            lines.append("Untracked files:")
            for path in status.untracked.prefix(20) {
                lines.append("  \u{001B}[31m\(path)\u{001B}[0m")
            }
            if status.untracked.count > 20 {
                lines.append("  ... and \(status.untracked.count - 20) more")
            }
        }

        if !status.conflicted.isEmpty {
            lines.append("")
            lines.append("\u{001B}[31mUnmerged paths:\u{001B}[0m")
            for path in status.conflicted {
                lines.append("  \u{001B}[31mboth modified:   \(path)\u{001B}[0m")
            }
        }

        if status.isClean { lines.append("nothing to commit, working tree clean") }

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Log

    private static func gitLog(repo: GitRepository, args: [String]) -> CommandResult {
        let isGraph = args.contains("--graph")
        let limit = args.compactMap { arg -> Int? in
            if arg.hasPrefix("-n") { return Int(arg.dropFirst(2)) }
            if arg.hasPrefix("-") && arg.dropFirst().allSatisfy(\.isNumber) { return Int(arg.dropFirst()) }
            return nil
        }.first ?? 10

        if isGraph { return textResult(repo.commitGraph(limit: limit)) }

        let entries = repo.log(limit: limit)
        if entries.isEmpty { return textResult("No commits yet.\n") }

        var lines: [String] = []
        for entry in entries {
            let c = entry.commit
            let refs = entry.refs.isEmpty ? "" : " \u{001B}[32m(\(entry.refs.joined(separator: ", ")))\u{001B}[0m"
            lines.append("\u{001B}[33mcommit \(c.id.hex)\u{001B}[0m\(refs)")
            if c.parentIds.count > 1 {
                lines.append("Merge: \(c.parentIds.map(\.short).joined(separator: " "))")
            }
            lines.append("Author: \(c.author.name) <\(c.author.email)>")
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy Z"
            lines.append("Date:   \(formatter.string(from: c.committer.timestamp))")
            lines.append("")
            for msgLine in c.message.split(separator: "\n") {
                lines.append("    \(msgLine)")
            }
            lines.append("")
        }
        return textResult(lines.joined(separator: "\n"))
    }

    // MARK: - Diff

    private static func gitDiffCmd(repo: GitRepository, args: [String]) -> CommandResult {
        let staged = args.contains("--staged") || args.contains("--cached")
        let paths = args.filter { !$0.hasPrefix("-") }

        let diffs: [FileDiff]
        if staged {
            diffs = repo.diffStaged().files
        } else {
            diffs = repo.diffWorkingTree(paths: paths.isEmpty ? nil : paths)
        }

        if diffs.isEmpty { return textResult("") }

        var output = ""
        for file in diffs {
            output += "\u{001B}[1mdiff --git a/\(file.path) b/\(file.path)\u{001B}[0m\n"
            if file.changeType == .added {
                output += "new file mode \(file.newMode ?? "100644")\n"
            } else if file.changeType == .deleted {
                output += "deleted file mode \(file.oldMode ?? "100644")\n"
            }
            output += "--- a/\(file.oldPath ?? file.path)\n"
            output += "+++ b/\(file.path)\n"
            for hunk in file.hunks {
                output += hunk.unifiedText(color: true)
            }
        }

        let result = GitDiffResult(files: diffs)
        output += "\n\(result.stat)\n"
        return textResult(output)
    }

    // MARK: - Branch

    private static func gitBranch(repo: GitRepository, args: [String]) -> CommandResult {
        let showAll = args.contains("-a") || args.contains("--all")
        let deleteIdx = args.firstIndex(of: "-d") ?? args.firstIndex(of: "-D") ?? args.firstIndex(of: "--delete")

        if let idx = deleteIdx, idx + 1 < args.count {
            let name = args[idx + 1]
            do {
                try repo.deleteBranch(name: name)
                return textResult("Deleted branch \(name).\n")
            } catch {
                return CommandResult(status: 1, io: ShellIO(stderr: Data("error: \(error)\n".utf8)))
            }
        }

        let nonFlagArgs = args.filter { !$0.hasPrefix("-") }
        if let name = nonFlagArgs.first {
            do {
                try repo.createBranch(name: name)
                return textResult("Created branch '\(name)'.\n")
            } catch {
                return CommandResult(status: 1, io: ShellIO(stderr: Data("error: \(error)\n".utf8)))
            }
        }

        var branches = repo.refs.listBranches()
        if showAll { branches.append(contentsOf: repo.refs.listRemoteBranches()) }

        let current = repo.refs.currentBranch
        var lines: [String] = []
        for branch in branches {
            let name = branch.shortName
            if name == current {
                lines.append("* \u{001B}[32m\(name)\u{001B}[0m")
            } else if branch.isRemote {
                lines.append("  \u{001B}[31m\(name)\u{001B}[0m")
            } else {
                lines.append("  \(name)")
            }
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Add

    private static func gitAdd(repo: GitRepository, args: [String]) -> CommandResult {
        let paths = args.filter { !$0.hasPrefix("-") }
        guard !paths.isEmpty else { return textResult("Usage: git add <file>...\n") }

        do {
            try repo.add(paths: paths)
            return textResult("")
        } catch {
            return CommandResult(status: 1, io: ShellIO(stderr: Data("error: \(error)\n".utf8)))
        }
    }

    // MARK: - Commit

    private static func gitCommitCmd(repo: GitRepository, args: [String], runtime: BuiltinRuntime) -> CommandResult {
        var message: String?
        if let mIdx = args.firstIndex(of: "-m"), mIdx + 1 < args.count {
            message = args[mIdx + 1]
        }
        guard let msg = message else {
            return CommandResult(status: 1, io: ShellIO(stderr: Data("error: use 'git commit -m \"message\"'\n".utf8)))
        }

        do {
            let commit = try repo.commit(message: msg)

            // Generate proof for the commit (future-shell integration)
            runtime.runtimeStore.proveExecution(
                command: "git commit",
                status: 0,
                stdout: "[\(repo.refs.currentBranch ?? "detached") \(commit.id.short)] \(msg)",
                stderr: "",
                durationMs: 0,
                cwd: runtime.context.currentDirectory
            )

            let branch = repo.refs.currentBranch ?? "detached HEAD"
            return textResult("[\(branch) \u{001B}[33m\(commit.id.short)\u{001B}[0m] \(msg)\n")
        } catch {
            return CommandResult(status: 1, io: ShellIO(stderr: Data("error: \(error)\n".utf8)))
        }
    }

    // MARK: - Checkout

    private static func gitCheckout(repo: GitRepository, args: [String]) -> CommandResult {
        guard let branch = args.first(where: { !$0.hasPrefix("-") }) else {
            return textResult("Usage: git checkout <branch>\n")
        }
        do {
            try repo.checkout(branch: branch)
            return textResult("Switched to branch '\(branch)'\n")
        } catch {
            return CommandResult(status: 1, io: ShellIO(stderr: Data("error: \(error)\n".utf8)))
        }
    }

    // MARK: - Merge

    private static func gitMerge(repo: GitRepository, args: [String]) -> CommandResult {
        guard let branch = args.first(where: { !$0.hasPrefix("-") }) else {
            return textResult("Usage: git merge <branch>\n")
        }
        do {
            let commit = try repo.merge(branch: branch)
            return textResult("Merge: [\(repo.refs.currentBranch ?? "HEAD") \u{001B}[33m\(commit.id.short)\u{001B}[0m] \(commit.summary)\n")
        } catch {
            return CommandResult(status: 1, io: ShellIO(stderr: Data("error: \(error)\n".utf8)))
        }
    }

    // MARK: - Stash

    private static func gitStash(repo: GitRepository, args: [String]) -> CommandResult {
        let sub = args.first ?? "push"

        switch sub {
        case "push", "save":
            let message = args.dropFirst().joined(separator: " ")
            do {
                let sha = try repo.stash(message: message.isEmpty ? nil : message)
                return textResult("Saved working directory to stash \u{001B}[33m\(sha.short)\u{001B}[0m\n")
            } catch {
                return CommandResult(status: 1, io: ShellIO(stderr: Data("error: \(error)\n".utf8)))
            }
        case "pop":
            do {
                try repo.stashPop()
                return textResult("Applied stash and removed it.\n")
            } catch {
                return CommandResult(status: 1, io: ShellIO(stderr: Data("error: \(error)\n".utf8)))
            }
        case "list":
            let stashFile = repo.gitDir.appendingPathComponent("refs/stash")
            if let content = try? String(contentsOf: stashFile, encoding: .utf8),
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let sha = GitObjectId(hex: content.trimmingCharacters(in: .whitespacesAndNewlines))
                if let commit = repo.objects.readCommit(id: sha) {
                    return textResult("stash@{0}: \(commit.summary)\n")
                }
            }
            return textResult("No stash entries.\n")
        case "drop":
            let stashFile = repo.gitDir.appendingPathComponent("refs/stash")
            try? FileManager.default.removeItem(at: stashFile)
            return textResult("Dropped stash.\n")
        default:
            return textResult("Usage: git stash [push|pop|list|drop]\n")
        }
    }

    // MARK: - Remote

    private static func gitRemote(repo: GitRepository, args: [String]) -> CommandResult {
        let verbose = args.contains("-v") || args.contains("--verbose")
        let remotes = repo.config.remotes()
        if remotes.isEmpty { return textResult("No remotes configured.\n") }

        var lines: [String] = []
        for remote in remotes {
            if verbose {
                lines.append("\(remote.name)\t\(remote.url) (fetch)")
                lines.append("\(remote.name)\t\(remote.url) (push)")
            } else {
                lines.append(remote.name)
            }
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Tree (commit graph)

    private static func gitTree(repo: GitRepository, args: [String]) -> CommandResult {
        let limit = args.compactMap { Int($0) }.first ?? 20
        return textResult(repo.commitGraph(limit: limit))
    }

    // MARK: - Tag

    private static func gitTag(repo: GitRepository, args: [String]) -> CommandResult {
        let tags = repo.refs.listTags()
        if args.isEmpty {
            if tags.isEmpty { return textResult("No tags.\n") }
            return textResult(tags.map(\.shortName).joined(separator: "\n") + "\n")
        }

        let name = args[0]
        do {
            let sha = repo.refs.headSHA ?? GitObjectId(hex: String(repeating: "0", count: 40))
            try repo.refs.updateRef("refs/tags/\(name)", to: sha)
            return textResult("Created tag '\(name)' at \(sha.short)\n")
        } catch {
            return CommandResult(status: 1, io: ShellIO(stderr: Data("error: \(error)\n".utf8)))
        }
    }

    // MARK: - Auth

    private static func gitAuth(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let configDir: URL
        if let home = runtime.context.environment["DODEXABASH_HOME"] {
            configDir = URL(fileURLWithPath: home)
        } else {
            configDir = URL(fileURLWithPath: runtime.context.currentDirectory + "/.dodexabash")
        }
        let auth = GitAuthManager(configDir: configDir)
        let sub = args.first ?? "status"

        switch sub {
        case "status":
            let status = auth.authStatus()
            var lines: [String] = ["Git Authentication:"]
            lines.append("  SSH keys: \(status.sshKeys.isEmpty ? "none" : status.sshKeys.joined(separator: ", "))")
            lines.append("  SSH agent: \(status.sshAgentRunning ? "\u{001B}[32mrunning\u{001B}[0m" : "\u{001B}[31mnot running\u{001B}[0m")")
            if let helper = status.credentialHelper {
                lines.append("  Credential helper: \(helper)")
            }
            if !status.storedHosts.isEmpty {
                lines.append("  Stored: \(status.storedHosts.joined(separator: ", "))")
            }
            return textResult(lines.joined(separator: "\n") + "\n")

        case "add":
            guard args.count >= 4 else {
                return textResult("Usage: git auth add <host> <username> <token>\n")
            }
            if auth.saveToKeychain(host: args[1], username: args[2], token: args[3]) {
                return textResult("Saved to Keychain for \(args[1]).\n")
            }
            auth.saveCredential(host: args[1], username: args[2], token: args[3])
            return textResult("Saved to .dodexabash/credentials.json for \(args[1]).\n")

        case "remove":
            guard args.count >= 2 else { return textResult("Usage: git auth remove <host>\n") }
            let removed = auth.removeFromKeychain(host: args[1])
            auth.removeCredential(host: args[1])
            return textResult("Removed credentials for \(args[1])\(removed ? " (Keychain)" : "").\n")

        default:
            return textResult("Usage: git auth [status|add|remove]\n")
        }
    }

    // MARK: - Init

    private static func gitInit(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let path = args.first(where: { !$0.hasPrefix("-") }) ?? runtime.context.currentDirectory
        let bare = args.contains("--bare")

        do {
            _ = try GitRepository.initRepo(at: path, bare: bare)
            return textResult("Initialized empty Git repository in \(path)/.git/\n")
        } catch {
            return CommandResult(status: 1, io: ShellIO(stderr: Data("error: \(error)\n".utf8)))
        }
    }
}
