import Foundation

public struct WorkflowCard: Codable, Sendable {
    public let slug: String
    public let name: String
    public let domain: String
    public let summary: String
    public let whenToUse: String
    public let keyInputs: [String]
    public let workflow: [String]
    public let outputs: [String]
    public let redFlags: [String]
}

public struct WorkflowMatch: Codable, Sendable {
    public let card: WorkflowCard
    public let score: Double
    public let reason: String
}

public struct WorkflowLibrary {
    private let cards: [WorkflowCard]

    public static func defaultLibrary() -> WorkflowLibrary {
        WorkflowLibrary(cards: [
            WorkflowCard(
                slug: "repo-context-refresh",
                name: "Repo Context Refresh",
                domain: "generalist",
                summary: "Capture the working set, key files, and recent edits before broad reasoning.",
                whenToUse: "Use at the start of coding, review, or debugging work when branch-local state matters.",
                keyInputs: ["workspace", "recent files", "key manifests", "active directory"],
                workflow: [
                    "Start from a compact repo brief instead of a broad file dump.",
                    "Identify only the files and manifests that constrain the current task.",
                    "Keep the working set narrow until evidence says otherwise."
                ],
                outputs: ["workspace brief", "working-set shortlist", "recent-edit summary"],
                redFlags: [
                    "The repo is reread broadly before a compact brief exists.",
                    "Recent local changes are ignored.",
                    "The active file set keeps expanding without evidence."
                ]
            ),
            WorkflowCard(
                slug: "bug-triage-and-repro",
                name: "Bug Triage and Repro",
                domain: "software-engineering",
                summary: "Make failures reproducible and bounded before patching.",
                whenToUse: "Use for failing builds, broken tests, regressions, and runtime errors.",
                keyInputs: ["failure signal", "recent commands", "logs", "expected behavior"],
                workflow: [
                    "Reduce the failure to the smallest stable reproduction.",
                    "Separate symptom, suspected cause, and confirmed cause.",
                    "Verify the fix against the repro and the nearest regression surface."
                ],
                outputs: ["repro note", "root-cause brief", "fix validation"],
                redFlags: [
                    "A patch is attempted before the failure is reproduced.",
                    "Logs are replayed in bulk without extracting the decisive error.",
                    "No regression check follows the fix."
                ]
            ),
            WorkflowCard(
                slug: "implementation-verification-loop",
                name: "Implementation Verification Loop",
                domain: "software-engineering",
                summary: "Keep edits, execution, verification, and memory in one disciplined loop.",
                whenToUse: "Use for implementation work where the shell should both act and learn from outcomes.",
                keyInputs: ["task", "repo brief", "candidate commands", "verification target"],
                workflow: [
                    "Constrain the active context first.",
                    "Execute the minimum safe command set that moves the task forward.",
                    "Persist the result so the next session can reuse the successful path."
                ],
                outputs: ["execution trace", "verification result", "session memory"],
                redFlags: [
                    "Commands run without later verification.",
                    "Successful paths are not persisted.",
                    "The plan grows faster than the current task requires."
                ]
            ),
            WorkflowCard(
                slug: "release-and-ci-hardening",
                name: "Release and CI Hardening",
                domain: "software-engineering",
                summary: "Stabilize build, test, and delivery surfaces before shipping.",
                whenToUse: "Use when packaging, releasing, or unblocking CI is part of the job.",
                keyInputs: ["release target", "build status", "test surface", "rollback path"],
                workflow: [
                    "Separate build failures, test failures, and environment failures.",
                    "Fix the narrowest delivery blocker first.",
                    "Name residual risks and rollback path before calling the release ready."
                ],
                outputs: ["delivery blocker list", "ci fix plan", "release readiness note"],
                redFlags: [
                    "Build and environment issues are conflated.",
                    "Release proceeds with unnamed blockers.",
                    "Rollback thinking is absent."
                ]
            ),
            WorkflowCard(
                slug: "openai-submission-readiness",
                name: "OpenAI Submission Readiness",
                domain: "developer-tooling",
                summary: "Package the product for fast external evaluation with evidence, docs, and explicit review commands.",
                whenToUse: "Use when handing the tool to OpenAI or any third-party evaluator who needs to verify safety, utility, and install surface quickly.",
                keyInputs: ["public repo", "plugin manifest", "reviewer commands", "safety posture"],
                workflow: [
                    "Generate a current readiness snapshot before writing any evaluation summary.",
                    "Export a submission bundle that ties claims to evidence and docs already present in the repo.",
                    "Make the reviewer path explicit: build, smoke test, doctor, catalog, MCP startup."
                ],
                outputs: ["submission bundle", "evidence map", "reviewer walkthrough"],
                redFlags: [
                    "Claims are made without direct evidence from the runtime or repo.",
                    "Reviewer commands are scattered across multiple documents.",
                    "Safety posture is implied instead of stated explicitly."
                ]
            )
        ])
    }

    public func listCards() -> [WorkflowCard] {
        cards
    }

    public func card(slug: String) -> WorkflowCard? {
        cards.first { $0.slug == slug }
    }

    public func match(query: String, limit: Int) -> [WorkflowMatch] {
        let queryTokens = tokenize(query)
        guard !queryTokens.isEmpty else {
            return []
        }

        return cards.compactMap { card in
            let cardTokens = tokenize(
                [
                    card.slug,
                    card.name,
                    card.domain,
                    card.summary,
                    card.whenToUse,
                    card.keyInputs.joined(separator: " "),
                    card.workflow.joined(separator: " "),
                    card.outputs.joined(separator: " "),
                    card.redFlags.joined(separator: " ")
                ].joined(separator: " ")
            )

            let overlap = queryTokens.intersection(cardTokens)
            guard !overlap.isEmpty else {
                return nil
            }

            let score = Double(overlap.count) / Double(max(queryTokens.count, 1))
            let reason = "overlap on: " + overlap.sorted().prefix(4).joined(separator: ", ")
            return WorkflowMatch(card: card, score: score, reason: reason)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.card.slug < rhs.card.slug
            }
            return lhs.score > rhs.score
        }
        .prefix(limit)
        .map { $0 }
    }

    private func tokenize(_ text: String) -> Set<String> {
        let scalars = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        let normalized = String(scalars)
        return Set(normalized.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.count > 2 })
    }
}
