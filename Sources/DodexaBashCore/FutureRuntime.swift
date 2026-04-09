import Foundation

// Type definitions are in Primitives/FutureTypes.swift

// MARK: - Runtime Snapshot (persistence model)

private struct RuntimeSnapshot: Codable, Sendable {
    var version: Int = 1
    var artifacts: [ArtifactEnvelope] = []
    var activeIntent: IntentContract? = nil
    var leases: [CapabilityLease] = []
    var simulations: [SimulationReport] = []
    var proofs: [ProofEnvelope] = []
    var entities: [EntityHandle] = []
    var attentionQueue: [AttentionEvent] = []
    var activePolicy: PolicyEnvelope? = nil
    var delegations: [DelegationTicket] = []
    var cognitivePackets: [CognitivePacket] = []
    var uncertainties: [UncertaintySurface] = []
    var worldNodes: [WorldNode] = []
    var repairPlans: [RepairPlan] = []
    var joins: [MultimodalJoin] = []
    var toolContracts: [ToolContract] = []
}

// MARK: - Runtime Store

public final class FutureRuntimeStore {
    private let persistenceURL: URL?

    public private(set) var artifacts: [ArtifactEnvelope] = [] { didSet { persist() } }
    public private(set) var activeIntent: IntentContract? = nil { didSet { persist() } }
    public private(set) var leases: [CapabilityLease] = [] { didSet { persist() } }
    public private(set) var simulations: [SimulationReport] = [] { didSet { persist() } }
    public private(set) var proofs: [ProofEnvelope] = [] { didSet { persist() } }
    public private(set) var entities: [EntityHandle] = [] { didSet { persist() } }
    public private(set) var attentionQueue: [AttentionEvent] = [] { didSet { persist() } }
    public private(set) var activePolicy: PolicyEnvelope? = nil { didSet { persist() } }
    public private(set) var delegations: [DelegationTicket] = [] { didSet { persist() } }
    public private(set) var cognitivePackets: [CognitivePacket] = [] { didSet { persist() } }
    public private(set) var uncertainties: [UncertaintySurface] = [] { didSet { persist() } }
    public private(set) var worldNodes: [WorldNode] = [] { didSet { persist() } }
    public private(set) var repairPlans: [RepairPlan] = [] { didSet { persist() } }
    public private(set) var joins: [MultimodalJoin] = [] { didSet { persist() } }
    public private(set) var toolContracts: [ToolContract] = [] { didSet { persist() } }

    public init(directory: URL? = nil) {
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.persistenceURL = directory.appendingPathComponent("runtime.json")
        } else {
            self.persistenceURL = nil
        }

        let snapshot = Self.loadSnapshot(from: persistenceURL)
        self.artifacts = snapshot.artifacts
        self.activeIntent = snapshot.activeIntent
        self.leases = snapshot.leases
        self.simulations = snapshot.simulations
        self.proofs = snapshot.proofs
        self.entities = snapshot.entities
        self.attentionQueue = snapshot.attentionQueue
        self.activePolicy = snapshot.activePolicy
        self.delegations = snapshot.delegations
        self.cognitivePackets = snapshot.cognitivePackets
        self.uncertainties = snapshot.uncertainties
        self.worldNodes = snapshot.worldNodes
        self.repairPlans = snapshot.repairPlans
        self.joins = snapshot.joins
        self.toolContracts = snapshot.toolContracts
    }

    // MARK: - Artifacts

    @discardableResult
    public func createArtifact(
        kind: ArtifactKind,
        label: String,
        content: String,
        sourceCommand: String? = nil,
        sourceFile: String? = nil,
        tags: [String] = [],
        policyTags: [String] = []
    ) -> ArtifactEnvelope {
        let artifact = ArtifactEnvelope(
            id: shortId(),
            kind: kind,
            label: label,
            content: content,
            contentHash: fnvHash(content),
            provenance: Provenance(
                sourceCommand: sourceCommand,
                sourceFile: sourceFile,
                traceId: nil,
                timestamp: Date(),
                confidence: 1.0,
                method: sourceCommand != nil ? "direct" : "manual"
            ),
            createdAt: Date(),
            tags: tags,
            policyTags: policyTags
        )
        artifacts.append(artifact)
        if artifacts.count > 200 { artifacts.removeFirst(artifacts.count - 200) }
        return artifact
    }

    public func artifact(id: String) -> ArtifactEnvelope? {
        artifacts.first { $0.id == id }
    }

    // MARK: - Intent

    @discardableResult
    public func setIntent(
        statement: String,
        reason: String? = nil,
        mutations: [String] = [],
        successCriteria: String? = nil,
        riskLevel: RiskLevel = .medium,
        verification: String? = nil
    ) -> IntentContract {
        let intent = IntentContract(
            id: shortId(),
            statement: statement,
            reason: reason,
            mutations: mutations,
            successCriteria: successCriteria,
            riskLevel: riskLevel,
            verification: verification,
            createdAt: Date(),
            status: .active
        )
        activeIntent = intent
        return intent
    }

    public func clearIntent() {
        activeIntent = nil
    }

    public func satisfyIntent() {
        activeIntent?.status = .satisfied
        pushAttention(
            priority: .normal,
            source: "intent",
            summary: "Intent satisfied: \(activeIntent?.statement ?? "unknown")"
        )
    }

    public func failIntent() {
        activeIntent?.status = .failed
        pushAttention(
            priority: .important,
            source: "intent",
            summary: "Intent failed: \(activeIntent?.statement ?? "unknown")"
        )
    }

    // MARK: - Leases

    @discardableResult
    public func grantLease(
        capability: String,
        resource: String,
        grantee: String = "shell",
        actions: [String] = ["read"],
        ttlSeconds: Int = 300
    ) -> CapabilityLease {
        let lease = CapabilityLease(
            id: shortId(),
            capability: capability,
            resource: resource,
            grantee: grantee,
            actions: actions,
            grantedAt: Date(),
            expiresAt: Date().addingTimeInterval(Double(ttlSeconds)),
            revoked: false
        )
        leases.append(lease)
        return lease
    }

    public func revokeExpiredLeases() -> Int {
        let now = Date()
        var count = 0
        for i in leases.indices {
            if !leases[i].revoked && leases[i].expiresAt < now {
                leases[i].revoked = true
                count += 1
            }
        }
        return count
    }

    public func revokeLease(id: String) -> Bool {
        guard let index = leases.firstIndex(where: { $0.id == id }) else { return false }
        leases[index].revoked = true
        return true
    }

    public func activeLeases() -> [CapabilityLease] {
        let now = Date()
        return leases.filter { !$0.revoked && $0.expiresAt > now }
    }

    public func checkLease(capability: String, resource: String) -> CapabilityLease? {
        let now = Date()
        return leases.first { !$0.revoked && $0.expiresAt > now && $0.capability == capability && $0.resource == resource }
    }

    // MARK: - Simulation

    @discardableResult
    public func simulateCommand(_ command: String, cwd: String? = nil) -> SimulationReport {
        simulate(command: command)
    }

    public func simulate(command: String) -> SimulationReport {
        let analysis = analyzeCommand(command)
        let report = SimulationReport(
            id: shortId(),
            command: command,
            predictedStatus: analysis.predictedStatus,
            predictedStdout: analysis.predictedStdout,
            predictedEffects: analysis.effects,
            riskAssessment: analysis.risk,
            rollbackPath: analysis.rollbackPath,
            confidence: analysis.confidence,
            alternatives: analysis.alternatives,
            simulatedAt: Date()
        )
        simulations.append(report)
        if simulations.count > 50 { simulations.removeFirst() }
        return report
    }

    // MARK: - Proofs

    @discardableResult
    public func proveExecution(
        command: String,
        status: Int32,
        stdout: String,
        stderr: String,
        durationMs: Int,
        cwd: String
    ) -> ProofEnvelope {
        var evidence: [EvidenceItem] = []
        evidence.append(EvidenceItem(kind: "exit_status", source: command, value: String(status), verified: true))
        evidence.append(EvidenceItem(kind: "timestamp", source: "system", value: ISO8601DateFormatter().string(from: Date()), verified: true))
        evidence.append(EvidenceItem(kind: "duration_ms", source: "system", value: String(durationMs), verified: true))
        evidence.append(EvidenceItem(kind: "working_directory", source: "system", value: cwd, verified: true))

        if !stdout.isEmpty {
            let preview = stdout.count > 200 ? String(stdout.prefix(200)) + "..." : stdout
            evidence.append(EvidenceItem(kind: "command_output", source: "stdout", value: preview, verified: true))
        }
        if !stderr.isEmpty {
            let preview = stderr.count > 200 ? String(stderr.prefix(200)) + "..." : stderr
            evidence.append(EvidenceItem(kind: "command_output", source: "stderr", value: preview, verified: true))
        }

        let claim: String
        if status == 0 {
            claim = "Command '\(command)' succeeded with exit status 0"
        } else {
            claim = "Command '\(command)' failed with exit status \(status)"
        }

        let confidence = status == 0 ? 0.95 : 0.90
        let proof = ProofEnvelope(
            id: shortId(),
            claim: claim,
            evidence: evidence,
            confidence: confidence,
            validatedAt: Date(),
            traceId: activeIntent?.id,
            replayToken: encodeReplayToken(command: command, cwd: cwd, env: [:])
        )
        proofs.append(proof)
        if proofs.count > 100 { proofs.removeFirst() }
        return proof
    }

    public func lastProof() -> ProofEnvelope? {
        proofs.last
    }

    // MARK: - Entities

    @discardableResult
    public func createEntity(
        label: String,
        kind: String,
        views: [EntityView] = []
    ) -> EntityHandle {
        let entity = EntityHandle(
            id: shortId(),
            label: label,
            kind: kind,
            views: views,
            createdAt: Date(),
            lastAccessed: Date()
        )
        entities.append(entity)
        if entities.count > 200 { entities.removeFirst() }
        return entity
    }

    public func entity(id: String) -> EntityHandle? {
        entities.first { $0.id == id }
    }

    public func resolveEntity(label: String) -> EntityHandle? {
        entities.first { $0.label.lowercased() == label.lowercased() }
    }

    // MARK: - Attention

    @discardableResult
    public func pushAttention(
        priority: AttentionPriority,
        source: String,
        summary: String,
        detail: String? = nil,
        ttlSeconds: Int? = nil
    ) -> AttentionEvent {
        let event = AttentionEvent(
            id: shortId(),
            priority: priority,
            source: source,
            summary: summary,
            detail: detail,
            createdAt: Date(),
            expiresAt: ttlSeconds.map { Date().addingTimeInterval(Double($0)) },
            acknowledged: false
        )
        attentionQueue.append(event)
        if attentionQueue.count > 100 { attentionQueue.removeFirst() }
        return event
    }

    public func acknowledgeAttention(id: String) -> Bool {
        guard let index = attentionQueue.firstIndex(where: { $0.id == id }) else { return false }
        attentionQueue[index].acknowledged = true
        return true
    }

    public func pendingAttention() -> [AttentionEvent] {
        let now = Date()
        return attentionQueue
            .filter { !$0.acknowledged && ($0.expiresAt == nil || $0.expiresAt! > now) }
            .sorted { $0.priority > $1.priority }
    }

    public func clearAttention() {
        attentionQueue.removeAll()
    }

    // MARK: - Policy

    @discardableResult
    public func setPolicy(rules: [PolicyRule]) -> PolicyEnvelope {
        let policy = PolicyEnvelope(id: shortId(), rules: rules, activeSince: Date())
        activePolicy = policy
        return policy
    }

    public func addPolicyRule(domain: String, constraint: String, enforcement: String = "soft") {
        var rules = activePolicy?.rules ?? []
        rules.append(PolicyRule(domain: domain, constraint: constraint, enforcement: enforcement))
        setPolicy(rules: rules)
    }

    public func clearPolicy() {
        activePolicy = nil
    }

    public func checkPolicy(action: String) -> [PolicyRule] {
        guard let policy = activePolicy else { return [] }
        let lowered = action.lowercased()
        return policy.rules.filter { rule in
            lowered.contains(rule.domain.lowercased()) || lowered.contains(rule.constraint.lowercased())
        }
    }

    // MARK: - World Graph

    public func buildWorldSnapshot(workspace: String) -> [WorldNode] {
        var nodes: [WorldNode] = []
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: workspace)
        let ignore: Set<String> = [
            ".git", ".build", ".swiftpm", "node_modules", "__pycache__", "DerivedData",
            "dump_ground", "vendor", "Pods", "build", "dist", ".cache", ".next", ".nuxt", "coverage", "tmp",
            "Library", "Movies", "Music", "Pictures", "Public", "Applications",
            "Desktop", "Downloads", "Receipts", "Zotero", "Archives",
            ".Trash", ".local", ".npm", ".cargo", ".rustup", ".gem",
            "OneDrive", ".docker", ".kube", ".ssh", ".gnupg", ".config", ".ollama",
            "Documents", "Projects", "Benovolence", "reyanda", "outlook-mcp"
        ]

        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nodes
        }

        var fileCount = 0
        while let fileURL = enumerator.nextObject() as? URL, fileCount < 500 {
            if fileURL.pathComponents.contains(where: { ignore.contains($0) }) {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]) else {
                continue
            }

            let relative = fileURL.path.hasPrefix(rootURL.path + "/")
                ? String(fileURL.path.dropFirst(rootURL.path.count + 1))
                : fileURL.lastPathComponent

            if values.isDirectory == true {
                nodes.append(WorldNode(
                    id: "dir:" + relative,
                    kind: "directory",
                    label: relative,
                    properties: [:],
                    edges: []
                ))
            } else if values.isRegularFile == true {
                fileCount += 1
                let ext = fileURL.pathExtension.lowercased()
                var edges: [WorldEdge] = []
                if let parent = relative.split(separator: "/").dropLast().last {
                    edges.append(WorldEdge(relation: "child_of", targetId: "dir:" + String(parent), weight: 1.0))
                }
                nodes.append(WorldNode(
                    id: "file:" + relative,
                    kind: "file",
                    label: relative,
                    properties: ["extension": ext],
                    edges: edges
                ))
            }
        }

        worldNodes = nodes
        return nodes
    }

    // MARK: - Delegations

    @discardableResult
    public func spawnDelegation(
        delegatee: String,
        task: String,
        ownership: String = "shared",
        mergeRule: String = "append"
    ) -> DelegationTicket {
        var leaseIds: [String] = []
        let lease = grantLease(
            capability: "task_execution",
            resource: task,
            grantee: delegatee,
            actions: ["read", "execute"],
            ttlSeconds: 600
        )
        leaseIds.append(lease.id)

        let ticket = DelegationTicket(
            id: shortId(),
            delegatee: delegatee,
            task: task,
            ownership: ownership,
            mergeRule: mergeRule,
            leaseIds: leaseIds,
            createdAt: Date(),
            status: .pending
        )
        delegations.append(ticket)
        return ticket
    }

    public func updateDelegation(id: String, status: DelegationStatus) -> Bool {
        guard let index = delegations.firstIndex(where: { $0.id == id }) else { return false }
        delegations[index].status = status
        return true
    }

    // MARK: - Cognitive Packets

    @discardableResult
    public func compressCognition(
        format: String = "brief",
        decisions: [String] = [],
        invariants: [String] = []
    ) -> CognitivePacket {
        var state: [String: String] = [:]
        state["artifactCount"] = String(artifacts.count)
        state["activeIntent"] = activeIntent?.statement ?? "none"
        state["activeLeases"] = String(activeLeases().count)
        state["pendingAttention"] = String(pendingAttention().count)
        state["proofCount"] = String(proofs.count)
        if let lastProof = proofs.last {
            state["lastProofClaim"] = lastProof.claim
        }
        if let policy = activePolicy {
            state["policyRules"] = String(policy.rules.count)
        }

        let eventCount = artifacts.count + proofs.count + simulations.count + attentionQueue.count
        let packet = CognitivePacket(
            id: shortId(),
            format: format,
            state: state,
            decisions: decisions,
            invariants: invariants,
            createdAt: Date(),
            compressedFrom: eventCount
        )
        cognitivePackets.append(packet)
        if cognitivePackets.count > 50 { cognitivePackets.removeFirst() }
        return packet
    }

    public func lastCognitivePacket() -> CognitivePacket? {
        cognitivePackets.last
    }

    // MARK: - Uncertainty

    @discardableResult
    public func assessUncertainty(
        subject: String,
        entries: [UncertaintyEntry]
    ) -> UncertaintySurface {
        let surface = UncertaintySurface(
            id: shortId(),
            subject: subject,
            entries: entries,
            createdAt: Date()
        )
        uncertainties.append(surface)
        if uncertainties.count > 50 { uncertainties.removeFirst() }
        return surface
    }

    public func autoAssessUncertainty() -> UncertaintySurface {
        var entries: [UncertaintyEntry] = []

        if let intent = activeIntent {
            entries.append(UncertaintyEntry(
                claim: "Active intent: \(intent.statement)",
                status: intent.status == .active ? .inferred : .known,
                confidence: intent.status == .satisfied ? 0.95 : 0.6,
                basis: "intent contract",
                lastVerified: intent.createdAt
            ))
        }

        let active = activeLeases()
        if !active.isEmpty {
            entries.append(UncertaintyEntry(
                claim: "\(active.count) active lease(s)",
                status: .known,
                confidence: 0.99,
                basis: "lease store",
                lastVerified: Date()
            ))
        }

        if let lastProof = proofs.last {
            let age = Date().timeIntervalSince(lastProof.validatedAt)
            let status: EpistemicStatus = age < 60 ? .known : (age < 300 ? .inferred : .stale)
            entries.append(UncertaintyEntry(
                claim: lastProof.claim,
                status: status,
                confidence: max(0.3, lastProof.confidence - age / 600.0),
                basis: "proof envelope",
                lastVerified: lastProof.validatedAt
            ))
        }

        if entries.isEmpty {
            entries.append(UncertaintyEntry(
                claim: "No runtime state observed",
                status: .guessed,
                confidence: 0.5,
                basis: "empty runtime store",
                lastVerified: nil
            ))
        }

        return assessUncertainty(subject: "runtime_state", entries: entries)
    }

    // MARK: - Repair

    @discardableResult
    public func suggestRepair(command: String, exitStatus: Int32, stderr: String) -> RepairPlan {
        var rootCauses: [String] = []
        var options: [RepairOption] = []
        let lowered = stderr.lowercased()

        if lowered.contains("command not found") || lowered.contains("no such file") {
            let program = command.split(separator: " ").first.map(String.init) ?? command
            rootCauses.append("Program '\(program)' not found in PATH")
            options.append(RepairOption(action: "Check PATH or install the program", rationale: "The binary may not be installed", risk: .low, command: "which \(program)"))
            options.append(RepairOption(action: "Search for similar commands", rationale: "Possible typo in command name", risk: .low, command: nil))
        }

        if lowered.contains("permission denied") {
            rootCauses.append("Insufficient permissions for this operation")
            options.append(RepairOption(action: "Check file permissions", rationale: "The target may not be executable or writable", risk: .low, command: "ls -la"))
        }

        if lowered.contains("compilation error") || lowered.contains("build error") || lowered.contains("cannot find") {
            rootCauses.append("Build or compilation failure")
            options.append(RepairOption(action: "Review build errors in detail", rationale: "Fix the compilation errors before retrying", risk: .low, command: nil))
            options.append(RepairOption(action: "Clean build artifacts and rebuild", rationale: "Stale build artifacts may cause false failures", risk: .medium, command: "swift build 2>&1 | head -30"))
        }

        if lowered.contains("connection refused") || lowered.contains("timeout") || lowered.contains("network") {
            rootCauses.append("Network connectivity issue")
            options.append(RepairOption(action: "Check network connectivity", rationale: "The target service may be down or unreachable", risk: .low, command: nil))
        }

        if lowered.contains("merge conflict") || lowered.contains("conflict") {
            rootCauses.append("Merge conflict in version control")
            options.append(RepairOption(action: "Resolve merge conflicts manually", rationale: "Conflicts must be resolved before proceeding", risk: .medium, command: "git status"))
        }

        if rootCauses.isEmpty {
            rootCauses.append("Unknown failure (exit status \(exitStatus))")
            options.append(RepairOption(action: "Review stderr output carefully", rationale: "The error message may contain clues", risk: .low, command: nil))
            options.append(RepairOption(action: "Check recent history for context", rationale: "Previous commands may explain the failure", risk: .low, command: "history 5"))
        }

        let errorSummary = stderr.count > 300 ? String(stderr.prefix(300)) + "..." : stderr
        let plan = RepairPlan(
            id: shortId(),
            failedCommand: command,
            exitStatus: exitStatus,
            errorSummary: errorSummary.trimmingCharacters(in: .whitespacesAndNewlines),
            rootCauses: rootCauses,
            repairOptions: options,
            safeRetryPlan: exitStatus == 127 ? nil : "Retry after applying the first repair option",
            createdAt: Date()
        )
        repairPlans.append(plan)
        if repairPlans.count > 30 { repairPlans.removeFirst() }
        return plan
    }

    public func repairPlan(byId id: String) -> RepairPlan? {
        repairPlans.first { $0.id == id }
    }

    public func lastRepairPlan() -> RepairPlan? {
        repairPlans.last
    }

    // MARK: - Semantic Diff

    @discardableResult
    public func createSemanticDiff(
        kind: String,
        summary: String,
        before: String,
        after: String,
        preservesBehavior: Bool?,
        breakingChanges: [String] = []
    ) -> SemanticDiff {
        SemanticDiff(
            id: shortId(),
            kind: kind,
            summary: summary,
            before: before,
            after: after,
            preservesBehavior: preservesBehavior,
            breakingChanges: breakingChanges,
            createdAt: Date()
        )
    }

    // MARK: - Tool Contracts

    public func registerToolContract(_ contract: ToolContract) {
        toolContracts.append(contract)
    }

    public func negotiateTools() -> [ToolContract] {
        toolContracts
    }

    // MARK: - Multimodal Joins

    @discardableResult
    public func createJoin(anchor: String, views: [JoinView]) -> MultimodalJoin {
        let join = MultimodalJoin(id: shortId(), anchor: anchor, views: views, createdAt: Date())
        joins.append(join)
        if joins.count > 50 { joins.removeFirst() }
        return join
    }

    // MARK: - Private Helpers

    private var snapshot: RuntimeSnapshot {
        RuntimeSnapshot(
            artifacts: artifacts,
            activeIntent: activeIntent,
            leases: leases,
            simulations: simulations,
            proofs: proofs,
            entities: entities,
            attentionQueue: attentionQueue,
            activePolicy: activePolicy,
            delegations: delegations,
            cognitivePackets: cognitivePackets,
            uncertainties: uncertainties,
            worldNodes: worldNodes,
            repairPlans: repairPlans,
            joins: joins,
            toolContracts: toolContracts
        )
    }

    private func persist() {
        guard let persistenceURL else {
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else {
            return
        }
        try? data.write(to: persistenceURL, options: .atomic)
    }

    private static func loadSnapshot(from persistenceURL: URL?) -> RuntimeSnapshot {
        guard
            let persistenceURL,
            let data = try? Data(contentsOf: persistenceURL),
            let snapshot = try? JSONDecoder().decode(RuntimeSnapshot.self, from: data)
        else {
            return RuntimeSnapshot()
        }
        return snapshot
    }

    private func shortId() -> String {
        let bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func fnvHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private func encodeReplayToken(command: String, cwd: String, env: [String: String]) -> String {
        let compact = "cmd=\(command);cwd=\(cwd)"
        return Data(compact.utf8).base64EncodedString()
    }

    // MARK: - Command Analysis (for simulate)

    private struct CommandAnalysis {
        let predictedStatus: Int32
        let predictedStdout: String
        let effects: [PredictedEffect]
        let risk: RiskLevel
        let rollbackPath: String?
        let confidence: Double
        let alternatives: [String]
    }

    private func analyzeCommand(_ command: String) -> CommandAnalysis {
        let parts = command.split(separator: " ").map(String.init)
        let program = parts.first ?? ""
        let args = Array(parts.dropFirst())

        // Read-only commands
        let readOnly: Set<String> = [
            "echo", "pwd", "env", "set", "brief", "history", "predict", "workflow", "help",
            "cat", "head", "tail", "less", "more", "wc", "ls", "find", "grep", "rg", "which",
            "whoami", "date", "uname", "hostname", "df", "du", "file", "otool", "nm",
            "swift", "python3", "node" // when not writing
        ]

        let destructive: Set<String> = [
            "rm", "rmdir", "mv", "git push", "git reset", "git clean", "docker rm",
            "kill", "killall", "pkill", "launchctl"
        ]

        let mutating: Set<String> = [
            "cp", "mkdir", "touch", "chmod", "chown", "ln", "sed", "awk",
            "git add", "git commit", "git checkout", "git merge", "git rebase",
            "npm install", "pip install", "brew install", "swift build"
        ]

        var effects: [PredictedEffect] = []
        var risk: RiskLevel = .low
        let predictedStatus: Int32 = 0
        var predictedStdout = ""
        var rollback: String? = nil
        var alternatives: [String] = []
        var confidence = 0.7

        if program == "echo" {
            predictedStdout = args.joined(separator: " ") + "\n"
            confidence = 0.99
        } else if program == "pwd" {
            predictedStdout = FileManager.default.currentDirectoryPath + "\n"
            confidence = 0.99
        } else if readOnly.contains(program) {
            confidence = 0.75
            predictedStdout = "(read-only output expected)"
        } else if destructive.contains(program) || destructive.contains(parts.prefix(2).joined(separator: " ")) {
            risk = .high
            confidence = 0.5
            effects.append(PredictedEffect(kind: "mutation", target: args.first ?? "unknown", reversible: false, description: "Destructive operation: \(program)"))
            rollback = "Manual recovery may be needed"
            alternatives.append("Consider a dry-run or backup first")

            if program == "rm" {
                effects.append(PredictedEffect(kind: "file_delete", target: args.last ?? "unknown", reversible: false, description: "File deletion"))
                if args.contains("-rf") || args.contains("-r") {
                    risk = .critical
                    rollback = "No automatic rollback for recursive delete"
                }
            }
        } else if mutating.contains(program) || mutating.contains(parts.prefix(2).joined(separator: " ")) {
            risk = .medium
            confidence = 0.6
            effects.append(PredictedEffect(kind: "mutation", target: args.first ?? "unknown", reversible: true, description: "State mutation: \(program)"))

            if program == "swift" && args.first == "build" {
                effects.append(PredictedEffect(kind: "file_write", target: ".build/", reversible: true, description: "Build artifacts created"))
                predictedStdout = "(build output)"
                alternatives.append("swift build --dry-run")
            }
        } else if program == "cd" {
            effects.append(PredictedEffect(kind: "env_change", target: "PWD", reversible: true, description: "Working directory change"))
            rollback = "cd -"
        } else if program == "export" {
            effects.append(PredictedEffect(kind: "env_change", target: args.first ?? "VAR", reversible: true, description: "Environment variable set"))
            let varName = args.first?.split(separator: "=").first.map(String.init) ?? "VAR"
            rollback = "unset \(varName)"
        } else {
            confidence = 0.4
            effects.append(PredictedEffect(kind: "unknown", target: "system", reversible: false, description: "Unknown command behavior"))
        }

        // Check active policy for violations
        if let policy = activePolicy {
            for rule in policy.rules {
                if rule.domain == "airGap" && (program == "curl" || program == "wget" || program == "ssh") {
                    risk = .critical
                    effects.append(PredictedEffect(kind: "policy_violation", target: rule.domain, reversible: true, description: "Violates air-gap policy"))
                }
                if rule.domain == "budget" && (program == "docker" || program == "terraform") {
                    effects.append(PredictedEffect(kind: "policy_warning", target: rule.domain, reversible: true, description: "May incur costs (budget policy active)"))
                }
            }
        }

        return CommandAnalysis(
            predictedStatus: predictedStatus,
            predictedStdout: predictedStdout,
            effects: effects,
            risk: risk,
            rollbackPath: rollback,
            confidence: confidence,
            alternatives: alternatives
        )
    }
}
