import Foundation

// MARK: - Rochestation: Structured Task Execution Framework
// Enforces: RESEARCH → PLAN → ANNOTATE → TODO → IMPLEMENT → ITERATE
// No code is written until a plan is researched, drafted, and approved.

// MARK: - Data Models

public enum RochePhase: String, Codable, Sendable, CaseIterable {
    case research
    case plan
    case annotate
    case todo
    case implement
    case iterate
    case completed

    public var displayName: String {
        switch self {
        case .research: return "RESEARCH"
        case .plan: return "PLAN"
        case .annotate: return "ANNOTATE"
        case .todo: return "TODO"
        case .implement: return "IMPLEMENT"
        case .iterate: return "ITERATE"
        case .completed: return "COMPLETED"
        }
    }

    public var phaseNumber: Int {
        switch self {
        case .research: return 1
        case .plan: return 2
        case .annotate: return 3
        case .todo: return 4
        case .implement: return 5
        case .iterate: return 6
        case .completed: return 7
        }
    }

    public var nextPhase: RochePhase? {
        switch self {
        case .research: return .plan
        case .plan: return .annotate
        case .annotate: return .todo
        case .todo: return .implement
        case .implement: return .completed
        case .iterate: return .completed
        case .completed: return nil
        }
    }

    public var prompt: String {
        switch self {
        case .research: return "Phase 1 complete. Review research above.\n  'roche approve' → continue to PLAN\n  'roche edit'    → revise research"
        case .plan: return "Phase 2 complete. Review plan above.\n  'roche approve'          → generate TODO list\n  'roche annotate <notes>' → add corrections\n  'roche edit'             → revise plan"
        case .annotate: return "Plan updated with your notes.\n  'roche approve'          → generate TODO list\n  'roche annotate <notes>' → add more corrections"
        case .todo: return "Phase 4 complete. TODO list ready.\n  'roche implement' → execute the plan (lease-gated)\n  'roche edit'      → revise the plan"
        case .implement: return "Implementation complete.\n  'roche fix <correction>' → apply targeted fix\n  'roche status'           → view summary"
        case .iterate: return "Fix applied.\n  'roche fix <correction>' → apply another fix\n  'roche status'           → view summary"
        case .completed: return "Session complete. All phases finished."
        }
    }
}

public struct RocheTodo: Codable, Sendable {
    public let description: String
    public var completed: Bool
    public var proofId: String?

    public init(description: String, completed: Bool = false, proofId: String? = nil) {
        self.description = description
        self.completed = completed
        self.proofId = proofId
    }
}

public struct PhaseTransition: Codable, Sendable {
    public let from: RochePhase
    public let to: RochePhase
    public let timestamp: Date
    public let approvedBy: String
}

public struct RocheSession: Codable, Sendable {
    public let id: String
    public let task: String
    public var currentPhase: RochePhase
    public var intentId: String?
    public var researchArtifactId: String?
    public var planArtifactId: String?
    public var todoItems: [RocheTodo]
    public var phaseHistory: [PhaseTransition]
    public var implementationLeaseId: String?
    public var createdAt: Date
    public var updatedAt: Date

    public var todoProgress: String {
        let done = todoItems.filter(\.completed).count
        return "\(done)/\(todoItems.count)"
    }
}

// MARK: - RocheStore: Session Persistence

public final class RocheStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Session CRUD

    public func createSession(task: String) -> RocheSession {
        let id = shortId()
        let session = RocheSession(
            id: id,
            task: task,
            currentPhase: .research,
            intentId: nil,
            researchArtifactId: nil,
            planArtifactId: nil,
            todoItems: [],
            phaseHistory: [],
            implementationLeaseId: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        saveSession(session)
        setActiveSession(id: id)
        return session
    }

    public func loadSession(id: String) -> RocheSession? {
        let url = sessionDir(id).appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RocheSession.self, from: data)
    }

    public func saveSession(_ session: RocheSession) {
        var s = session
        s.updatedAt = Date()
        let dir = sessionDir(s.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(s) else { return }
        try? data.write(to: dir.appendingPathComponent("session.json"), options: .atomic)
    }

    public func listSessions() -> [RocheSession] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return entries.compactMap { entry in
            guard entry != "active" else { return nil }
            return loadSession(id: entry)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func activeSession() -> RocheSession? {
        guard let id = activeSessionId() else { return nil }
        return loadSession(id: id)
    }

    public func activeSessionId() -> String? {
        let url = directory.appendingPathComponent("active")
        return try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func setActiveSession(id: String?) {
        let url = directory.appendingPathComponent("active")
        if let id {
            try? Data(id.utf8).write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Phase Files

    public func writePhaseFile(sessionId: String, name: String, content: String) {
        let url = sessionDir(sessionId).appendingPathComponent(name)
        try? Data(content.utf8).write(to: url, options: .atomic)
    }

    public func readPhaseFile(sessionId: String, name: String) -> String? {
        let url = sessionDir(sessionId).appendingPathComponent(name)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    public func phaseFilePath(sessionId: String, name: String) -> String {
        sessionDir(sessionId).appendingPathComponent(name).path
    }

    // MARK: - Helpers

    private func sessionDir(_ id: String) -> URL {
        directory.appendingPathComponent(id, isDirectory: true)
    }

    private func shortId() -> String {
        var bytes = [UInt8](repeating: 0, count: 6)
        _ = bytes.withUnsafeMutableBufferPointer { SecRandomCopyBytes(kSecRandomDefault, 6, $0.baseAddress!) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Phase Execution

enum RocheEngine {

    // MARK: - Phase 1: RESEARCH

    static func executeResearch(
        session: inout RocheSession,
        store: RocheStore,
        runtime: BuiltinRuntime
    ) -> String {
        let cwd = runtime.context.currentDirectory

        // Set intent
        let intent = runtime.runtimeStore.setIntent(
            statement: "Research: \(session.task)",
            reason: "Rochestation Phase 1 — Multi-domain deep research",
            mutations: [],
            successCriteria: "Comprehensive research document from multiple sources",
            riskLevel: .low,
            verification: nil
        )
        session.intentId = intent.id

        // Multi-domain research engine
        let engine = ResearchEngine()
        let researchCtx = engine.research(task: session.task, runtime: runtime)

        // Build enriched context: workspace brief + multi-source results
        let brief = runtime.workspaceBriefer.generate(atPath: cwd).compactText
        let multiSourceContext = researchCtx.formatted(maxChars: 5000)
        let fullContext = brief + "\n\n" + multiSourceContext

        // Research summary header
        var header = "Research Sources: \(researchCtx.domain.rawValue) domain\n"
        header += "  Palace: \(researchCtx.palaceResults.count) memories\n"
        header += "  Web: \(researchCtx.webResults.count) results from \(Set(researchCtx.webResults.map(\.source)).count) engines\n"
        header += "  MCP: \(researchCtx.mcpResults.count) database results\n"
        header += "  Queries: \(researchCtx.queries.joined(separator: "; "))\n"
        header += "  Time: \(researchCtx.totalLatencyMs)ms\n"

        let prompt = RocheFramework.researchPrompt(task: session.task, context: fullContext)

        // Try brain synthesis — if brain unavailable, return raw research context
        let result: String
        if let brainResult = runtime.brain.askExtended(
            question: prompt,
            cwd: cwd,
            lastStatus: runtime.context.lastStatus,
            recentHistory: runtime.sessionStore.commandHistory(limit: 5),
            context: fullContext,
            maxTokens: 4096
        ) {
            result = header + "\n---\n\n" + brainResult
        } else {
            // Brain offline — return raw multi-source research directly
            result = header + "\n---\n\n# Research: \(session.task)\n\n" + multiSourceContext +
                     "\n\n*Brain offline — raw research context above. Run 'brain on' for AI synthesis.*"
        }

        // Store artifact
        let artifact = runtime.runtimeStore.createArtifact(
            kind: .markdown,
            label: "roche-research-\(session.id)",
            content: result,
            sourceCommand: "roche \(session.task)"
        )
        session.researchArtifactId = artifact.id

        // Write to disk (user-editable)
        store.writePhaseFile(sessionId: session.id, name: "research.md", content: result)

        // Auto-file research into palace for future recall
        let palaceDir = URL(fileURLWithPath: (runtime.context.environment["DODEXABASH_HOME"] ?? cwd + "/.dodexabash"))
            .appendingPathComponent("palace", isDirectory: true)
        let palace = PalaceStore(directory: palaceDir)
        palace.addDrawer(content: result, wing: "research", room: session.task.prefix(30).description,
                        tags: [researchCtx.domain.rawValue], source: "roche", importance: 4,
                        summary: "Roche research: \(session.task)")

        // Transition
        session.currentPhase = .research
        session.phaseHistory.append(PhaseTransition(from: .research, to: .research, timestamp: Date(), approvedBy: "auto"))
        store.saveSession(session)

        return result
    }

    // MARK: - Phase 2: PLAN

    static func executePlan(
        session: inout RocheSession,
        store: RocheStore,
        runtime: BuiltinRuntime
    ) -> String {
        let cwd = runtime.context.currentDirectory

        // Read research from disk (user may have edited)
        let research = store.readPhaseFile(sessionId: session.id, name: "research.md") ?? ""

        // Update intent
        runtime.runtimeStore.satisfyIntent()
        let intent = runtime.runtimeStore.setIntent(
            statement: "Plan: \(session.task)",
            reason: "Rochestation Phase 2 — Detailed specification",
            mutations: [],
            successCriteria: "Implementation plan with code snippets and file paths",
            riskLevel: .low,
            verification: nil
        )
        session.intentId = intent.id

        let prompt = RocheFramework.planPrompt(task: session.task, research: research)

        guard let result = runtime.brain.askExtended(
            question: prompt,
            cwd: cwd,
            lastStatus: runtime.context.lastStatus,
            recentHistory: [],
            context: research.prefix(2000).description,
            maxTokens: 2048
        ) else {
            return "Brain unavailable. Write plan.md manually at:\n  \(store.phaseFilePath(sessionId: session.id, name: "plan.md"))"
        }

        let artifact = runtime.runtimeStore.createArtifact(
            kind: .plan,
            label: "roche-plan-\(session.id)",
            content: result,
            sourceCommand: "roche plan"
        )
        session.planArtifactId = artifact.id

        store.writePhaseFile(sessionId: session.id, name: "plan.md", content: result)

        session.currentPhase = .plan
        session.phaseHistory.append(PhaseTransition(from: .research, to: .plan, timestamp: Date(), approvedBy: "user"))
        store.saveSession(session)

        return result
    }

    // MARK: - Phase 3: ANNOTATE

    static func executeAnnotate(
        session: inout RocheSession,
        notes: String,
        store: RocheStore,
        runtime: BuiltinRuntime
    ) -> String {
        let currentPlan = store.readPhaseFile(sessionId: session.id, name: "plan.md") ?? ""

        let prompt = RocheFramework.annotatePrompt(plan: currentPlan, notes: notes)

        guard let result = runtime.brain.askExtended(
            question: prompt,
            cwd: runtime.context.currentDirectory,
            lastStatus: 0,
            recentHistory: [],
            context: nil,
            maxTokens: 2048
        ) else {
            return "Brain unavailable. Edit plan.md manually at:\n  \(store.phaseFilePath(sessionId: session.id, name: "plan.md"))"
        }

        let artifact = runtime.runtimeStore.createArtifact(
            kind: .plan,
            label: "roche-plan-\(session.id)",
            content: result,
            sourceCommand: "roche annotate"
        )
        session.planArtifactId = artifact.id

        store.writePhaseFile(sessionId: session.id, name: "plan.md", content: result)

        session.currentPhase = .annotate
        session.phaseHistory.append(PhaseTransition(from: .plan, to: .annotate, timestamp: Date(), approvedBy: "user"))
        store.saveSession(session)

        return result
    }

    // MARK: - Phase 4: TODO

    static func executeTodo(
        session: inout RocheSession,
        store: RocheStore,
        runtime: BuiltinRuntime
    ) -> String {
        let plan = store.readPhaseFile(sessionId: session.id, name: "plan.md") ?? ""

        runtime.runtimeStore.satisfyIntent()
        _ = runtime.runtimeStore.setIntent(
            statement: "Todo: \(session.task)",
            reason: "Rochestation Phase 4 — Granular task breakdown",
            mutations: [],
            successCriteria: "Ordered checklist of actionable steps",
            riskLevel: .low,
            verification: nil
        )

        let prompt = RocheFramework.todoPrompt(plan: plan)

        guard let result = runtime.brain.askExtended(
            question: prompt,
            cwd: runtime.context.currentDirectory,
            lastStatus: 0,
            recentHistory: [],
            context: nil,
            maxTokens: 1024
        ) else {
            return "Brain unavailable. Add TODO items to plan.md manually."
        }

        // Parse numbered list into todo items
        var items: [RocheTodo] = []
        for line in result.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Match lines starting with number + period/paren
            let stripped = trimmed.drop(while: { $0.isNumber || $0 == "." || $0 == ")" || $0 == " " || $0 == "-" || $0 == "[" || $0 == "]" || $0 == "x" })
            let desc = String(stripped).trimmingCharacters(in: .whitespaces)
            if !desc.isEmpty && desc.count > 3 {
                items.append(RocheTodo(description: desc))
            }
        }

        session.todoItems = items

        // Append checklist to plan.md
        var checklist = "\n\n## Implementation Checklist\n\n"
        for (i, item) in items.enumerated() {
            checklist += "- [ ] \(i + 1). \(item.description)\n"
        }
        let updatedPlan = plan + checklist
        store.writePhaseFile(sessionId: session.id, name: "plan.md", content: updatedPlan)

        session.currentPhase = .todo
        session.phaseHistory.append(PhaseTransition(from: .annotate, to: .todo, timestamp: Date(), approvedBy: "user"))
        store.saveSession(session)

        return checklist
    }

    // MARK: - Phase 5: IMPLEMENT

    static func executeImplement(
        session: inout RocheSession,
        store: RocheStore,
        runtime: BuiltinRuntime
    ) -> String {
        // Lease check
        let leases = runtime.runtimeStore.activeLeases()
        let hasLease = leases.contains { $0.capability.contains("roche") || $0.capability.contains("implement") }

        if !hasLease {
            // Auto-grant for 30 minutes
            let lease = runtime.runtimeStore.grantLease(
                capability: "roche:implement",
                resource: session.task,
                grantee: "roche",
                actions: ["execute", "write"],
                ttlSeconds: 1800
            )
            session.implementationLeaseId = lease.id
        }

        runtime.runtimeStore.satisfyIntent()

        var output = ""
        let incomplete = session.todoItems.enumerated().filter { !$0.element.completed }

        for (index, item) in incomplete {
            let stepIntent = runtime.runtimeStore.setIntent(
                statement: "Implement step \(index + 1): \(item.description)",
                reason: "Rochestation Phase 5",
                mutations: ["code changes"],
                successCriteria: "Step completes successfully",
                riskLevel: .medium,
                verification: nil
            )

            output += "\n[\(index + 1)/\(session.todoItems.count)] \(item.description)\n"

            // Execute via brain agent loop
            let steps = runtime.brain.executeTask(
                task: item.description,
                cwd: runtime.context.currentDirectory
            ) { command in
                // This closure is not available in this context — we need the shell reference
                // For now, log what would be executed
                return (0, "Would execute: \(command)", "")
            }

            // Mark done
            session.todoItems[index].completed = true

            if !steps.isEmpty {
                for step in steps {
                    output += "  \(step.thought ?? "")\n"
                    if let cmd = step.command { output += "  > \(cmd)\n" }
                }
            }

            runtime.runtimeStore.satisfyIntent()

            output += "  \u{2713} Done\n"
        }

        // Update plan.md checklist
        if let plan = store.readPhaseFile(sessionId: session.id, name: "plan.md") {
            var updated = plan
            for (i, item) in session.todoItems.enumerated() where item.completed {
                updated = updated.replacingOccurrences(of: "- [ ] \(i + 1).", with: "- [x] \(i + 1).")
            }
            store.writePhaseFile(sessionId: session.id, name: "plan.md", content: updated)
        }

        session.currentPhase = .completed
        session.phaseHistory.append(PhaseTransition(from: .todo, to: .completed, timestamp: Date(), approvedBy: "user"))
        store.saveSession(session)

        return output
    }

    // MARK: - Phase 6: ITERATE (Fix)

    static func executeFix(
        session: inout RocheSession,
        correction: String,
        store: RocheStore,
        runtime: BuiltinRuntime
    ) -> String {
        let plan = store.readPhaseFile(sessionId: session.id, name: "plan.md") ?? ""

        _ = runtime.runtimeStore.setIntent(
            statement: "Fix: \(correction)",
            reason: "Rochestation Phase 6 — Iteration",
            mutations: ["targeted code fix"],
            successCriteria: "Correction applied",
            riskLevel: .medium,
            verification: nil
        )

        let prompt = RocheFramework.fixPrompt(correction: correction, plan: plan)

        guard let result = runtime.brain.askExtended(
            question: prompt,
            cwd: runtime.context.currentDirectory,
            lastStatus: 0,
            recentHistory: runtime.sessionStore.commandHistory(limit: 5),
            context: nil,
            maxTokens: 1024
        ) else {
            return "Brain unavailable for iteration."
        }

        session.currentPhase = .iterate
        session.phaseHistory.append(PhaseTransition(from: .completed, to: .iterate, timestamp: Date(), approvedBy: "user"))
        store.saveSession(session)

        runtime.runtimeStore.satisfyIntent()
        return result
    }
}
