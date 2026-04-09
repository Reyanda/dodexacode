import Foundation

// MARK: - Roche Builtins: Shell integration for Rochestation framework

extension Builtins {
    static func rocheBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let rocheDir = rocheDirectory(runtime: runtime)
        let store = RocheStore(directory: rocheDir)

        let sub = args.first ?? ""
        let knownSubs: Set<String> = ["approve", "edit", "annotate", "implement", "fix",
                                       "status", "list", "resume", "abort", "revert", "help", ""]

        // If first arg is not a known subcommand, treat as new task
        if !knownSubs.contains(sub) {
            let task = args.joined(separator: " ")
            return rocheStart(task: task, store: store, runtime: runtime)
        }

        switch sub {
        case "help":
            if args.contains("--full") { return rocheHelpFull() }
            return rocheHelp()
        case "approve":
            return rocheApprove(store: store, runtime: runtime)
        case "edit":
            return rocheEdit(store: store, runtime: runtime)
        case "annotate":
            let notes = Array(args.dropFirst()).joined(separator: " ")
            return rocheAnnotate(notes: notes, store: store, runtime: runtime)
        case "implement":
            return rocheImplement(store: store, runtime: runtime)
        case "fix":
            let correction = Array(args.dropFirst()).joined(separator: " ")
            return rocheFix(correction: correction, store: store, runtime: runtime)
        case "status":
            return rocheStatus(store: store, runtime: runtime)
        case "list":
            return rocheList(store: store, runtime: runtime)
        case "resume":
            let id = args.dropFirst().first ?? ""
            return rocheResume(id: id, store: store, runtime: runtime)
        case "abort":
            return rocheAbort(store: store, runtime: runtime)
        default:
            return rocheHelp()
        }
    }

    // MARK: - Start New Session

    private static func rocheStart(task: String, store: RocheStore, runtime: BuiltinRuntime) -> CommandResult {
        // Write framework document on first use
        RocheFramework.ensureFrameworkFile(at: rocheDirectory(runtime: runtime))

        // Check if there's already an active session
        if let existing = store.activeSession() {
            if existing.currentPhase != .completed {
                return textResult(
                    "Active session exists: [\(existing.id)] \(existing.task)\n" +
                    "  Phase: \(existing.currentPhase.displayName)\n" +
                    "  Use 'roche abort' to cancel, or 'roche resume <id>' to switch.\n"
                )
            }
        }

        var session = store.createSession(task: task)

        var lines: [String] = []
        lines.append(phaseHeader(1, "RESEARCH"))
        lines.append("Task: \(task)")
        lines.append("")

        let research = RocheEngine.executeResearch(session: &session, store: store, runtime: runtime)
        lines.append(research)
        lines.append("")
        lines.append(phaseDivider())
        lines.append(session.currentPhase.prompt)

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Approve Current Phase

    private static func rocheApprove(store: RocheStore, runtime: BuiltinRuntime) -> CommandResult {
        guard var session = store.activeSession() else {
            return textResult("No active roche session. Start one with 'roche <task>'.\n")
        }

        var lines: [String] = []

        switch session.currentPhase {
        case .research:
            lines.append(phaseHeader(2, "PLAN"))
            let plan = RocheEngine.executePlan(session: &session, store: store, runtime: runtime)
            lines.append(plan)
            lines.append("")
            lines.append(phaseDivider())
            lines.append(session.currentPhase.prompt)

        case .plan, .annotate:
            lines.append(phaseHeader(4, "TODO"))
            let todo = RocheEngine.executeTodo(session: &session, store: store, runtime: runtime)
            lines.append(todo)
            lines.append("")
            lines.append(phaseDivider())
            lines.append(session.currentPhase.prompt)

        default:
            return textResult("Nothing to approve in phase '\(session.currentPhase.displayName)'.\n")
        }

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Edit Current Phase

    private static func rocheEdit(store: RocheStore, runtime: BuiltinRuntime) -> CommandResult {
        guard let session = store.activeSession() else {
            return textResult("No active roche session.\n")
        }

        let file: String
        switch session.currentPhase {
        case .research:
            file = store.phaseFilePath(sessionId: session.id, name: "research.md")
        case .plan, .annotate, .todo:
            file = store.phaseFilePath(sessionId: session.id, name: "plan.md")
        default:
            return textResult("Nothing to edit in phase '\(session.currentPhase.displayName)'.\n")
        }

        return textResult(
            "Edit the file directly, then 'roche approve' to continue:\n" +
            "  \(file)\n"
        )
    }

    // MARK: - Annotate Plan

    private static func rocheAnnotate(notes: String, store: RocheStore, runtime: BuiltinRuntime) -> CommandResult {
        guard var session = store.activeSession() else {
            return textResult("No active roche session.\n")
        }
        guard [.plan, .annotate].contains(session.currentPhase) else {
            return textResult("Can only annotate during PLAN or ANNOTATE phase (current: \(session.currentPhase.displayName)).\n")
        }
        guard !notes.isEmpty else {
            return textResult("Usage: roche annotate <your corrections and notes>\n")
        }

        var lines: [String] = []
        lines.append(phaseHeader(3, "ANNOTATE"))
        lines.append("Applying notes: \(notes)")
        lines.append("")

        let result = RocheEngine.executeAnnotate(session: &session, notes: notes, store: store, runtime: runtime)
        lines.append(result)
        lines.append("")
        lines.append(phaseDivider())
        lines.append(session.currentPhase.prompt)

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Implement

    private static func rocheImplement(store: RocheStore, runtime: BuiltinRuntime) -> CommandResult {
        guard var session = store.activeSession() else {
            return textResult("No active roche session.\n")
        }
        guard session.currentPhase == .todo else {
            return textResult("Can only implement from TODO phase (current: \(session.currentPhase.displayName)).\nFollow the pipeline: research → plan → annotate → todo → implement\n")
        }

        var lines: [String] = []
        lines.append(phaseHeader(5, "IMPLEMENT"))
        lines.append("Executing \(session.todoItems.count) tasks from the approved plan...")
        lines.append("")

        let result = RocheEngine.executeImplement(session: &session, store: store, runtime: runtime)
        lines.append(result)
        lines.append("")
        lines.append(phaseDivider())
        lines.append(session.currentPhase.prompt)

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Fix (Iterate)

    private static func rocheFix(correction: String, store: RocheStore, runtime: BuiltinRuntime) -> CommandResult {
        guard var session = store.activeSession() else {
            return textResult("No active roche session.\n")
        }
        guard [.completed, .iterate, .implement].contains(session.currentPhase) else {
            return textResult("Can only fix after implementation (current: \(session.currentPhase.displayName)).\n")
        }
        guard !correction.isEmpty else {
            return textResult("Usage: roche fix <correction>\n  Example: roche fix \"use httpOnly cookies instead of localStorage\"\n")
        }

        var lines: [String] = []
        lines.append(phaseHeader(6, "ITERATE"))
        lines.append("Applying: \(correction)")
        lines.append("")

        let result = RocheEngine.executeFix(session: &session, correction: correction, store: store, runtime: runtime)
        lines.append(result)
        lines.append("")
        lines.append(phaseDivider())
        lines.append(session.currentPhase.prompt)

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Status

    private static func rocheStatus(store: RocheStore, runtime: BuiltinRuntime) -> CommandResult {
        guard let session = store.activeSession() else {
            return textResult("No active roche session.\nStart one with: roche <task description>\n")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var lines: [String] = []
        lines.append("Roche Session: \(session.id)")
        lines.append("  Task: \(session.task)")
        lines.append("  Phase: \(session.currentPhase.displayName) (\(session.currentPhase.phaseNumber)/7)")
        lines.append("  Created: \(formatter.string(from: session.createdAt))")
        lines.append("  Updated: \(formatter.string(from: session.updatedAt))")

        // Phase progress bar
        let phases: [RochePhase] = [.research, .plan, .annotate, .todo, .implement, .completed]
        let currentIdx = phases.firstIndex(of: session.currentPhase) ?? 0
        var bar = "  Progress: "
        for (i, phase) in phases.enumerated() {
            if i < currentIdx {
                bar += "\u{001B}[32m\u{25CF}\u{001B}[0m" // green filled
            } else if i == currentIdx {
                bar += "\u{001B}[33m\u{25C9}\u{001B}[0m" // yellow current
            } else {
                bar += "\u{001B}[2m\u{25CB}\u{001B}[0m" // dim empty
            }
            if i < phases.count - 1 { bar += "\u{2500}" }
        }
        lines.append(bar)
        lines.append("            R\u{2500}P\u{2500}A\u{2500}T\u{2500}I\u{2500}C")

        // Artifacts
        if session.researchArtifactId != nil {
            lines.append("  Research: \(store.phaseFilePath(sessionId: session.id, name: "research.md"))")
        }
        if session.planArtifactId != nil {
            lines.append("  Plan: \(store.phaseFilePath(sessionId: session.id, name: "plan.md"))")
        }

        // Todo progress
        if !session.todoItems.isEmpty {
            let done = session.todoItems.filter(\.completed).count
            lines.append("  Todo: \(done)/\(session.todoItems.count) complete")
            for (i, item) in session.todoItems.enumerated() {
                let check = item.completed ? "\u{001B}[32m\u{2713}\u{001B}[0m" : "\u{001B}[2m\u{25CB}\u{001B}[0m"
                lines.append("    \(check) \(i + 1). \(item.description)")
            }
        }

        lines.append("")
        lines.append(session.currentPhase.prompt)

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - List Sessions

    private static func rocheList(store: RocheStore, runtime: BuiltinRuntime) -> CommandResult {
        let sessions = store.listSessions()
        guard !sessions.isEmpty else {
            return textResult("No roche sessions.\nStart one with: roche <task description>\n")
        }

        let activeId = store.activeSessionId()
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"

        var lines: [String] = ["Roche Sessions:"]
        for session in sessions {
            let active = session.id == activeId ? " \u{001B}[32m*\u{001B}[0m" : "  "
            let phase = session.currentPhase.displayName.padding(toLength: 10, withPad: " ", startingAt: 0)
            lines.append("\(active) [\(session.id)] \(phase) \(session.task.prefix(40))  \(formatter.string(from: session.updatedAt))")
        }

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Resume

    private static func rocheResume(id: String, store: RocheStore, runtime: BuiltinRuntime) -> CommandResult {
        guard !id.isEmpty else {
            return textResult("Usage: roche resume <session-id>\n")
        }
        guard store.loadSession(id: id) != nil else {
            return textResult("Session '\(id)' not found.\n")
        }
        store.setActiveSession(id: id)
        return rocheStatus(store: store, runtime: runtime)
    }

    // MARK: - Abort

    private static func rocheAbort(store: RocheStore, runtime: BuiltinRuntime) -> CommandResult {
        guard let session = store.activeSession() else {
            return textResult("No active roche session.\n")
        }
        runtime.runtimeStore.failIntent()
        store.setActiveSession(id: nil)
        return textResult("Aborted session [\(session.id)] \(session.task)\n")
    }

    // MARK: - Help

    private static func rocheHelp() -> CommandResult {
        textResult("""
        Rochestation — Universal Task Execution Framework v2.0

        CORE PRINCIPLE: No code is written until a plan is researched,
        drafted, and explicitly approved by a human.

        PIPELINE: RESEARCH → PLAN → ANNOTATE → TODO → IMPLEMENT → ITERATE

        Commands:
          roche <task>              Start new session (Phase 1: Research)
          roche approve             Approve current phase, advance to next
          roche edit                Show path to edit current phase file
          roche annotate <notes>    Add corrections to plan (Phase 3)
          roche implement           Execute the approved plan (Phase 5)
          roche fix <correction>    Apply targeted fix (Phase 6)
          roche status              Show current session + progress bar
          roche list                Show all sessions
          roche resume <id>         Resume a paused session
          roche abort               Abandon current session
          roche help --full         Show the complete framework document

        Phase Discipline:
          - Each phase STOPS and waits for your approval
          - Artifacts (research.md, plan.md) are user-editable files
          - Implementation is lease-gated (time-limited permission)
          - Every phase creates intent + proof chain
          - "roche annotate" loops until you're satisfied

        Quality Standards:
          - Type safety, no dead code, pattern consistency
          - Continuous verification during implementation
          - No improvisation — only what's in the plan
          - Stop and revise if plan is insufficient

        """)
    }

    private static func rocheHelpFull() -> CommandResult {
        textResult(RocheFramework.fullDocument + "\n")
    }

    // MARK: - Formatting

    private static func phaseHeader(_ number: Int, _ name: String) -> String {
        let bar = String(repeating: "\u{2550}", count: 40)
        return "\u{001B}[1m\u{2554}\(bar)\u{2557}\u{001B}[0m\n" +
               "\u{001B}[1m\u{2551}  PHASE \(number): \(name)\(String(repeating: " ", count: max(0, 31 - name.count)))\u{2551}\u{001B}[0m\n" +
               "\u{001B}[1m\u{255A}\(bar)\u{255D}\u{001B}[0m"
    }

    private static func phaseDivider() -> String {
        "\u{001B}[2m" + String(repeating: "\u{2500}", count: 42) + "\u{001B}[0m"
    }

    private static func rocheDirectory(runtime: BuiltinRuntime) -> URL {
        let home: String
        if let override = runtime.context.environment["DODEXABASH_HOME"], !override.isEmpty {
            home = override
        } else {
            home = runtime.context.currentDirectory + "/.dodexabash"
        }
        return URL(fileURLWithPath: home).appendingPathComponent("roche", isDirectory: true)
    }
}
