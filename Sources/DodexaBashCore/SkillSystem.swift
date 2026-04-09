import Foundation

// MARK: - Skill Definition

public struct DiscoveredSkill {
    public let name: String
    public let source: String
    public let format: Format
    public let content: String

    public enum Format { case markdown, json }
}

public struct Skill: Codable, Sendable {
    public let name: String
    public let description: String
    public let steps: [String]
    public let tags: [String]
}

// MARK: - Skill Store

public final class SkillStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory.appendingPathComponent("skills", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        seedDefaultSkills()
    }

    public func list() -> [Skill] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return files.filter { $0.hasSuffix(".json") }.compactMap { file in
            let url = directory.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url),
                  let skill = try? JSONDecoder().decode(Skill.self, from: data) else { return nil }
            return skill
        }.sorted { $0.name < $1.name }
    }

    public func get(name: String) -> Skill? {
        let url = directory.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Skill.self, from: data)
    }

    public func save(_ skill: Skill) {
        let url = directory.appendingPathComponent("\(skill.name).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(skill) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public func delete(name: String) -> Bool {
        let url = directory.appendingPathComponent("\(name).json")
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    // MARK: - System-wide Skill Discovery

    /// Scan known locations for skills from Claude Code, Codex, InferenceOS, and user config
    public func discoverSystemSkills() -> [DiscoveredSkill] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        var discovered: [DiscoveredSkill] = []

        // Scan paths where skills might live
        // Only scan well-known, portable paths — no hardcoded project paths
        let searchPaths = [
            home + "/.claude/skills",
            home + "/.claude/commands",
            home + "/.codex/skills",
            home + "/.inference_os/skills",
            home + "/.dodexabash/skills",
            home + "/.config/dodexabash/skills",
        ]

        for path in searchPaths {
            guard fm.fileExists(atPath: path) else { continue }
            guard let entries = try? fm.contentsOfDirectory(atPath: path) else { continue }

            for entry in entries {
                let fullPath = path + "/" + entry
                var isDir: ObjCBool = false
                fm.fileExists(atPath: fullPath, isDirectory: &isDir)

                if isDir.boolValue {
                    // Skill directory — look for SKILL.md or skill.json
                    let skillMd = fullPath + "/SKILL.md"
                    let skillJson = fullPath + "/skill.json"
                    if fm.fileExists(atPath: skillMd) {
                        if let content = try? String(contentsOfFile: skillMd, encoding: .utf8) {
                            discovered.append(DiscoveredSkill(
                                name: entry,
                                source: path,
                                format: .markdown,
                                content: content
                            ))
                        }
                    } else if fm.fileExists(atPath: skillJson) {
                        if let content = try? String(contentsOfFile: skillJson, encoding: .utf8) {
                            discovered.append(DiscoveredSkill(
                                name: entry,
                                source: path,
                                format: .json,
                                content: content
                            ))
                        }
                    }
                } else if entry.hasSuffix(".md") || entry.hasSuffix(".json") {
                    // Standalone skill file
                    if let content = try? String(contentsOfFile: fullPath, encoding: .utf8) {
                        let name = (entry as NSString).deletingPathExtension
                        let format: DiscoveredSkill.Format = entry.hasSuffix(".json") ? .json : .markdown
                        discovered.append(DiscoveredSkill(
                            name: name,
                            source: path,
                            format: format,
                            content: content
                        ))
                    }
                }
            }
        }

        return discovered
    }

    /// Import a discovered skill into the local skill store
    public func importSkill(_ discovered: DiscoveredSkill) -> Skill {
        let steps: [String]
        if discovered.format == .json, let data = discovered.content.data(using: .utf8),
           let skill = try? JSONDecoder().decode(Skill.self, from: data) {
            return skill
        }

        // Parse markdown: extract steps from numbered/bulleted lists
        steps = discovered.content
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                line.hasPrefix("- ") || line.hasPrefix("* ") ||
                (line.first?.isNumber == true && line.contains(". "))
            }
            .map { line in
                var step = line
                if step.hasPrefix("- ") || step.hasPrefix("* ") { step = String(step.dropFirst(2)) }
                if let dotIdx = step.firstIndex(of: "."), step[step.startIndex..<dotIdx].allSatisfy(\.isNumber) {
                    step = String(step[step.index(after: dotIdx)...]).trimmingCharacters(in: .whitespaces)
                }
                return step
            }

        let description = discovered.content
            .split(separator: "\n")
            .first(where: { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init) ?? discovered.name

        let skill = Skill(
            name: discovered.name,
            description: description,
            steps: steps.isEmpty ? ["Follow instructions in \(discovered.name)"] : steps,
            tags: [discovered.name, "imported", discovered.source.components(separatedBy: "/").last ?? "system"]
        )
        save(skill)
        return skill
    }

    private func seedDefaultSkills() {
        let defaults: [Skill] = [
            Skill(
                name: "project-setup",
                description: "Initialize a new project with standard structure",
                steps: [
                    "Create project directory structure",
                    "Initialize git repository",
                    "Create README.md with project name and description",
                    "Create .gitignore appropriate for the language",
                    "Run brief to verify setup"
                ],
                tags: ["setup", "init", "project"]
            ),
            Skill(
                name: "code-review",
                description: "Review code changes for quality and correctness",
                steps: [
                    "Run git diff to see changes",
                    "Check for obvious bugs or security issues",
                    "Verify naming conventions and code style",
                    "Check for missing error handling",
                    "Summarize findings"
                ],
                tags: ["review", "quality", "git"]
            ),
            Skill(
                name: "debug-loop",
                description: "Systematic debugging workflow",
                steps: [
                    "Reproduce the failure with the smallest possible test case",
                    "Check recent command history for clues",
                    "Read error messages and stack traces carefully",
                    "Form a hypothesis about the root cause",
                    "Apply the fix and verify",
                    "Run the full test suite to check for regressions"
                ],
                tags: ["debug", "fix", "triage"]
            ),
            Skill(
                name: "deploy-check",
                description: "Pre-deployment verification checklist",
                steps: [
                    "Run all tests and verify they pass",
                    "Check for uncommitted changes",
                    "Review the diff against main/master",
                    "Verify build succeeds in clean state",
                    "Check for hardcoded secrets or debug flags",
                    "Confirm rollback plan exists"
                ],
                tags: ["deploy", "release", "ci"]
            ),
            Skill(
                name: "explore-repo",
                description: "Understand an unfamiliar codebase",
                steps: [
                    "Run brief for workspace overview",
                    "Run tree -L2 for directory structure",
                    "Read README.md for project purpose",
                    "Check Package.swift / package.json for dependencies",
                    "Identify entry points and main modules",
                    "Summarize architecture and key patterns"
                ],
                tags: ["explore", "understand", "onboard"]
            )
        ]

        for skill in defaults {
            let url = directory.appendingPathComponent("\(skill.name).json")
            if !FileManager.default.fileExists(atPath: url.path) {
                save(skill)
            }
        }
    }
}
