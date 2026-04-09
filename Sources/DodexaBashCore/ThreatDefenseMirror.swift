import Foundation

public struct ThreatPatternSearchResult: Codable, Sendable {
    public let pattern: AttackPattern
    public let score: Double
    public let rationale: [String]
}

public struct DefenseControl: Codable, Sendable {
    public let phase: DefensePhase
    public let title: String
    public let actions: [String]
    public let priority: Int

    public enum DefensePhase: String, Codable, Sendable, CaseIterable {
        case prevent
        case detect
        case contain
        case recover
        case validate
    }
}

public struct ThreatMirrorProfile: Codable, Sendable {
    public let pattern: AttackPattern
    public let confidence: Double
    public let rationale: [String]
    public let matchedSignals: [ThreatSignal]
    public let controls: [DefenseControl]
    public let telemetry: [String]
    public let huntQueries: [String]
}

public struct ThreatMirrorReport: Codable, Sendable {
    public let target: String
    public let generatedAt: Date
    public let observedSignals: [ThreatSignal]
    public let profiles: [ThreatMirrorProfile]
    public let riskScore: Double
    public let summary: String
}

public enum ThreatDefenseMirror {
    public static func search(_ query: String, limit: Int = 5) -> [ThreatPatternSearchResult] {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return [] }

        return ThreatIntelligence.patterns.compactMap { pattern in
            let score = patternScore(pattern: pattern, queryTokens: tokens, signalCategories: [], signalText: query)
            guard score > 0 else { return nil }
            return ThreatPatternSearchResult(
                pattern: pattern,
                score: score,
                rationale: matchRationale(pattern: pattern, queryTokens: tokens, signalText: query)
            )
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.pattern.id < rhs.pattern.id }
            return lhs.score > rhs.score
        }
        .prefix(limit)
        .map { $0 }
    }

    public static func profile(
        pattern: AttackPattern,
        matchedSignals: [ThreatSignal] = [],
        confidence: Double = 1.0,
        rationale: [String] = []
    ) -> ThreatMirrorProfile {
        let baseRationale = rationale.isEmpty ? defaultRationale(for: pattern, matchedSignals: matchedSignals) : rationale
        return ThreatMirrorProfile(
            pattern: pattern,
            confidence: confidence,
            rationale: baseRationale,
            matchedSignals: matchedSignals,
            controls: controls(for: pattern),
            telemetry: telemetry(for: pattern, matchedSignals: matchedSignals),
            huntQueries: huntQueries(for: pattern, matchedSignals: matchedSignals)
        )
    }

    public static func correlate(
        target: String,
        signals: [ThreatSignal],
        contextText: String = "",
        limit: Int = 5
    ) -> ThreatMirrorReport {
        let combinedText = (signals.map { "\($0.description) \($0.indicator)" } + [contextText]).joined(separator: " ")
        let categories = Array(Set(signals.map(\.category)))

        let matches = ThreatIntelligence.patterns.compactMap { pattern -> ThreatMirrorProfile? in
            let score = patternScore(
                pattern: pattern,
                queryTokens: tokenize(combinedText),
                signalCategories: categories,
                signalText: combinedText
            )
            guard score > 0.14 else { return nil }

            let relatedSignals = signals.filter { signal in
                signalRelatedness(signal: signal, to: pattern) > 0.12
            }

            return profile(
                pattern: pattern,
                matchedSignals: relatedSignals,
                confidence: min(1.0, score),
                rationale: matchRationale(pattern: pattern, queryTokens: tokenize(combinedText), signalText: combinedText)
            )
        }
        .sorted { lhs, rhs in
            if lhs.confidence == rhs.confidence { return lhs.pattern.id < rhs.pattern.id }
            return lhs.confidence > rhs.confidence
        }

        let topProfiles = Array(matches.prefix(limit))
        let riskScore = computeRiskScore(signals: signals, profiles: topProfiles)
        let summary = "\(signals.count) observed signals correlated to \(topProfiles.count) defensive mirror profiles."

        return ThreatMirrorReport(
            target: target,
            generatedAt: Date(),
            observedSignals: signals,
            profiles: topProfiles,
            riskScore: riskScore,
            summary: summary
        )
    }

    public static func analyzeHTTP(
        target: String,
        url: String,
        headers: [String: String],
        body: String,
        responseHeaders: [String: String]
    ) -> ThreatMirrorReport {
        let requestSignals = ThreatDetector.analyzeHTTP(url: url, headers: headers, body: body)
        let responseSignals = ThreatDetector.analyzeResponseHeaders(responseHeaders)
        let contextText = url + " " + headers.map { "\($0.key) \($0.value)" }.joined(separator: " ")
            + " " + responseHeaders.map { "\($0.key) \($0.value)" }.joined(separator: " ")
            + " " + body
        return correlate(target: target, signals: requestSignals + responseSignals, contextText: contextText)
    }

    public static func analyzeRuntime(
        target: String,
        recentCommands: [String],
        activeLeases: Int,
        intentStatement: String?
    ) -> ThreatMirrorReport {
        let escalationAttempts = recentCommands.filter {
            let lower = $0.lowercased()
            return lower.contains("sudo") || lower.contains("su -") || lower.contains("chmod 777") || lower.contains("chown root")
        }.count

        let signals = ThreatDetector.analyzeAgentBehavior(
            recentCommands: recentCommands,
            activeLeases: activeLeases,
            intentStatement: intentStatement,
            escalationAttempts: escalationAttempts
        )
        let contextText = recentCommands.joined(separator: " ") + " " + (intentStatement ?? "")
        return correlate(target: target, signals: signals, contextText: contextText)
    }

    public static func renderSearch(_ results: [ThreatPatternSearchResult]) -> String {
        guard !results.isEmpty else { return "No threat intelligence patterns matched.\n" }

        var lines = ["Threat Intelligence Search", String(repeating: "=", count: 40), ""]
        for result in results {
            lines.append("[\(result.pattern.id)] \(result.pattern.name)")
            lines.append("  Score: \(String(format: "%.2f", result.score))  Category: \(result.pattern.category)  Severity: \(result.pattern.severity)")
            for reason in result.rationale.prefix(2) {
                lines.append("  - \(reason)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func renderProfile(_ profile: ThreatMirrorProfile) -> String {
        var lines = ["Mirror Defense: \(profile.pattern.name) [\(profile.pattern.id)]", String(repeating: "=", count: 60)]
        lines.append("Confidence: \(String(format: "%.0f%%", profile.confidence * 100))")
        lines.append("Category: \(profile.pattern.category)  MITRE: \(profile.pattern.mitreTechnique)  Severity: \(profile.pattern.severity)")
        lines.append("")

        if !profile.rationale.isEmpty {
            lines.append("Why this matters:")
            for reason in profile.rationale {
                lines.append("  - \(reason)")
            }
            lines.append("")
        }

        if !profile.matchedSignals.isEmpty {
            lines.append("Observed Signals:")
            for signal in profile.matchedSignals.prefix(6) {
                lines.append("  - [\(signal.severity.rawValue)] \(signal.description)")
            }
            lines.append("")
        }

        for control in profile.controls {
            lines.append("\(control.phase.rawValue.capitalized): \(control.title) [P\(control.priority)]")
            for action in control.actions {
                lines.append("  - \(action)")
            }
            lines.append("")
        }

        lines.append("Telemetry:")
        for item in profile.telemetry {
            lines.append("  - \(item)")
        }
        lines.append("")

        lines.append("Hunt Queries:")
        for query in profile.huntQueries {
            lines.append("  - \(query)")
        }

        return lines.joined(separator: "\n")
    }

    public static func renderReport(_ report: ThreatMirrorReport) -> String {
        var lines = ["Threat Intelligence Mirror: \(report.target)", String(repeating: "=", count: 60)]
        lines.append("Risk Score: \(String(format: "%.0f", report.riskScore))/100")
        lines.append(report.summary)
        lines.append("")

        if report.observedSignals.isEmpty {
            lines.append("No signals observed.")
        } else {
            lines.append("Observed Signals:")
            for signal in report.observedSignals.prefix(10) {
                lines.append("  - [\(signal.severity.rawValue.uppercased())] \(signal.description)")
            }
            lines.append("")
        }

        if report.profiles.isEmpty {
            lines.append("No correlated mirror-defense profiles.")
        } else {
            lines.append("Correlated Defensive Profiles:")
            for profile in report.profiles {
                lines.append("")
                lines.append("[\(profile.pattern.id)] \(profile.pattern.name)  confidence=\(String(format: "%.0f%%", profile.confidence * 100))")
                if let prevent = profile.controls.first(where: { $0.phase == .prevent }) {
                    lines.append("  Prevent: \(prevent.actions.prefix(2).joined(separator: " | "))")
                }
                if let detect = profile.controls.first(where: { $0.phase == .detect }) {
                    lines.append("  Detect: \(detect.actions.prefix(2).joined(separator: " | "))")
                }
                if let contain = profile.controls.first(where: { $0.phase == .contain }) {
                    lines.append("  Contain: \(contain.actions.prefix(2).joined(separator: " | "))")
                }
                if let recover = profile.controls.first(where: { $0.phase == .recover }) {
                    lines.append("  Recover: \(recover.actions.prefix(2).joined(separator: " | "))")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func controls(for pattern: AttackPattern) -> [DefenseControl] {
        [
            DefenseControl(
                phase: .prevent,
                title: "Preventive Hardening",
                actions: Array(pattern.mitigations.prefix(4)),
                priority: priority(for: pattern.severity)
            ),
            DefenseControl(
                phase: .detect,
                title: "Detection and Telemetry",
                actions: Array(pattern.detectionRules.prefix(5)),
                priority: max(1, priority(for: pattern.severity) - 1)
            ),
            DefenseControl(
                phase: .contain,
                title: "Containment",
                actions: containmentActions(for: pattern),
                priority: priority(for: pattern.severity)
            ),
            DefenseControl(
                phase: .recover,
                title: "Recovery",
                actions: recoveryActions(for: pattern),
                priority: max(1, priority(for: pattern.severity) - 1)
            ),
            DefenseControl(
                phase: .validate,
                title: "Safe Validation",
                actions: validationChecks(for: pattern),
                priority: 3
            ),
        ]
    }

    private static func containmentActions(for pattern: AttackPattern) -> [String] {
        switch pattern.category {
        case "memory-corruption":
            return [
                "Disable the affected parser, renderer, or remote font/JIT surface behind a feature flag.",
                "Isolate crashing processes and collect crash dumps, faulting inputs, and version metadata.",
                "Block untrusted content sources that are triggering the malformed input path."
            ]
        case "code-execution":
            return [
                "Quarantine the impacted service or host and stop outbound traffic except to approved responders.",
                "Rotate application secrets, session keys, and deployment credentials touched by the process.",
                "Preserve request/response traces and child-process telemetry before restart."
            ]
        case "privilege-escalation":
            return [
                "Freeze the affected workload, container, or VM and capture namespace/capability state.",
                "Revoke elevated tokens, disable exposed control sockets, and remove unnecessary capabilities.",
                "Confirm whether the compromise crossed isolation boundaries into the host or peer workloads."
            ]
        case "agent-manipulation":
            return [
                "Revoke active leases, pause autonomous actions, and require explicit human review.",
                "Snapshot the agent context, fetched content, prompts, and tool outputs for forensic review.",
                "Block further access to secrets, policy files, and self-modifying surfaces until triage completes."
            ]
        case "protocol-abuse":
            return [
                "Freeze MCP/A2A registrations, revoke affected client certificates, and stop new delegation flows.",
                "Treat agent cards, tool contracts, and discovery documents as tainted until reissued from a trusted source.",
                "Separate the control plane from runtime data paths and disable dynamic registration until triage completes."
            ]
        case "session-isolation":
            return [
                "Clear inherited browser state, revoke active cookies/tokens, and force per-domain session re-authentication.",
                "Split sensitive workflows into separate browser contexts or VPC-isolated workers immediately.",
                "Disable cross-tab memory sharing and shared session stores while investigating possible contamination."
            ]
        case "browser-control":
            return [
                "Pause probabilistic browser actions and fall back to deterministic observe/extract/act primitives.",
                "Capture DOM, screenshot, and tool-call evidence for any suspicious approval or click path.",
                "Block untrusted overlays, injected prompts, and mixed-origin UI content until the surface is reviewed."
            ]
        case "identity-fabric":
            return [
                "Revoke long-lived credentials, temporary tokens, and over-broad leases associated with the session.",
                "Isolate the workload inside its scoped VPC boundary and confirm pass-through authentication is intact.",
                "Block direct operator access to runtime state until signed forensic capture is complete."
            ]
        case "context-provenance":
            return [
                "Purge tainted context windows, caches, and long-term memory entries sourced from untrusted content.",
                "Require provenance labels and signatures on any tool output reintroduced into the reasoning loop.",
                "Disable autonomous continuation until the agent state is rebuilt from trusted checkpoints."
            ]
        case "data-exfiltration":
            return [
                "Block non-essential egress immediately and capture destination inventory from recent flows.",
                "Revoke credentials that could have been read or staged for export.",
                "Compare recently accessed sensitive paths against outbound volume and archive creation events."
            ]
        default:
            return [
                "Constrain the impacted surface to the minimum trusted perimeter while investigation runs.",
                "Collect high-signal artifacts and freeze relevant logs before cleanup actions.",
                "Apply temporary traffic shaping or feature disablement to reduce further exposure."
            ]
        }
    }

    private static func recoveryActions(for pattern: AttackPattern) -> [String] {
        switch pattern.category {
        case "memory-corruption":
            return [
                "Patch the vulnerable parser or engine and redeploy with canary crash monitoring.",
                "Add corpus regression tests for the malformed samples observed in the incident.",
                "Backfill sandboxing or process isolation where parsing previously ran in-process."
            ]
        case "code-execution":
            return [
                "Rebuild from known-good artifacts, rotate infrastructure credentials, and redeploy clean instances.",
                "Review command execution paths, templating, and deserialization boundaries implicated by the signal.",
                "Validate that outbound callback infrastructure and persistence mechanisms were removed."
            ]
        case "privilege-escalation":
            return [
                "Recreate the workload from a hardened baseline with reduced capabilities and stronger isolation.",
                "Review host, container, and kernel patch levels against the implicated escape path.",
                "Audit adjacent workloads for cross-boundary access or copied credentials."
            ]
        case "agent-manipulation":
            return [
                "Patch intent checks, lease scopes, and approval surfaces that allowed drift.",
                "Retrain or reconfigure content sanitization and tool-routing policies.",
                "Replay the session in dry-run mode to confirm the same manipulation path is blocked."
            ]
        case "protocol-abuse":
            return [
                "Reissue agent cards and MCP/A2A metadata from signed, versioned sources only.",
                "Add schema validation, mTLS, and network allowlists around discovery and registration endpoints.",
                "Regression-test metadata ingestion so instruction payloads are stripped before tool routing."
            ]
        case "session-isolation":
            return [
                "Rebuild the browser automation surface around per-domain contexts and explicit consent boundaries.",
                "Adopt WebMCP-style domain isolation or equivalent tool contracts for state-changing actions.",
                "Replay mixed-domain workflows in a lab to verify credentials cannot bleed across tabs or agents."
            ]
        case "browser-control":
            return [
                "Replace free-form UI driving with schema-validated extraction and deterministic act primitives.",
                "Cache successful selectors or tool contracts so repeated flows avoid raw LLM control loops.",
                "Add UI deception tests around overlays, hidden prompts, and approval mismatches before redeploying."
            ]
        case "identity-fabric":
            return [
                "Move to pass-through authentication, least-privilege leases, and short-lived scoped tokens only.",
                "Verify the runtime executes under zero-operator-access controls with immutable trace capture.",
                "Audit every privileged action against user identity, approval source, and signed runtime evidence."
            ]
        case "context-provenance":
            return [
                "Add provenance labels, trust tiers, and taint clearing to every context artifact entering the agent.",
                "Shorten context retention and rotate reasoning windows to prevent persistent poisoned state.",
                "Verify trace exports scrub hidden reasoning artifacts and retain only signed, reviewable evidence."
            ]
        case "data-exfiltration":
            return [
                "Rotate exposed secrets, invalidate active sessions, and notify data owners.",
                "Add egress allowlists, DLP checks, and artifact labeling for sensitive stores.",
                "Run retrospective hunts for the same tunneling or staging pattern across recent history."
            ]
        default:
            return [
                "Patch the affected component and verify the defensive control now fires at the expected boundary.",
                "Update runbooks, logging coverage, and regression tests to make recurrence noisier and shorter-lived.",
                "Share the pattern, detections, and mitigations with your research or response team."
            ]
        }
    }

    private static func validationChecks(for pattern: AttackPattern) -> [String] {
        [
            "Replay sanitized indicators in a private test environment only and confirm the detection path fires.",
            "Verify that at least one preventive and one containment control produce observable evidence.",
            "Record the expected log fields, alert IDs, and rollback steps before closing the gap."
        ]
    }

    private static func telemetry(for pattern: AttackPattern, matchedSignals: [ThreatSignal]) -> [String] {
        var items = Array(pattern.indicators.prefix(5))
        if !matchedSignals.isEmpty {
            items.append(contentsOf: matchedSignals.map { "Observed signal: \($0.id) \($0.indicator)" })
        }
        return Array(items.prefix(8))
    }

    private static func huntQueries(for pattern: AttackPattern, matchedSignals: [ThreatSignal]) -> [String] {
        var queries = [
            "mitre:\(pattern.mitreTechnique) AND category:\(pattern.category)",
            "\"\(pattern.name)\" AND severity:\(pattern.severity)",
            pattern.detectionRules.first?.replacingOccurrences(of: "DETECT: ", with: "") ?? "hunt \(pattern.category) indicators"
        ]

        if let signal = matchedSignals.first {
            queries.append("signal:\(signal.id) AND \"\(signal.indicator)\"")
        }

        return queries
    }

    private static func computeRiskScore(signals: [ThreatSignal], profiles: [ThreatMirrorProfile]) -> Double {
        let signalWeight = signals.reduce(0.0) { partial, signal in
            partial + severityWeight(signal.severity)
        }
        let profileWeight = profiles.reduce(0.0) { partial, profile in
            partial + profile.confidence * Double(priority(for: profile.pattern.severity))
        }
        return min(100.0, signalWeight * 8.0 + profileWeight * 6.0)
    }

    private static func priority(for severity: String) -> Int {
        switch severity.lowercased() {
        case "critical": return 1
        case "high": return 2
        case "medium": return 3
        case "low": return 4
        default: return 5
        }
    }

    private static func severityWeight(_ severity: ThreatSignal.ThreatSeverity) -> Double {
        switch severity {
        case .critical: return 4.0
        case .high: return 3.0
        case .medium: return 2.0
        case .low: return 1.0
        case .info: return 0.5
        }
    }

    private static func defaultRationale(for pattern: AttackPattern, matchedSignals: [ThreatSignal]) -> [String] {
        var reasons = [
            "Pattern category '\(pattern.category)' maps to observed defensive priorities and mitigations.",
            "MITRE technique \(pattern.mitreTechnique) gives a stable hunt and reporting anchor."
        ]
        if let signal = matchedSignals.first {
            reasons.append("Observed signal '\(signal.id)' aligns with this pattern's indicators or detections.")
        }
        return reasons
    }

    private static func matchRationale(pattern: AttackPattern, queryTokens: Set<String>, signalText: String) -> [String] {
        let patternTokens = tokenize(patternCorpus(pattern))
        let overlap = Array(queryTokens.intersection(patternTokens)).sorted()
        var reasons: [String] = []
        if !overlap.isEmpty {
            reasons.append("Keyword overlap: \(overlap.prefix(5).joined(separator: ", "))")
        }
        if signalText.lowercased().contains(pattern.category.lowercased()) || pattern.description.lowercased().contains(signalText.lowercased()) {
            reasons.append("Signal text aligns with pattern category or description.")
        }
        if reasons.isEmpty {
            reasons.append("Matched through defensive keyword similarity across indicators and rules.")
        }
        return reasons
    }

    private static func signalRelatedness(signal: ThreatSignal, to pattern: AttackPattern) -> Double {
        let signalTokens = tokenize(signal.description + " " + signal.indicator)
        return patternScore(
            pattern: pattern,
            queryTokens: signalTokens,
            signalCategories: [signal.category],
            signalText: signal.description + " " + signal.indicator
        )
    }

    private static func patternScore(
        pattern: AttackPattern,
        queryTokens: Set<String>,
        signalCategories: [ThreatSignal.ThreatCategory],
        signalText: String
    ) -> Double {
        guard !queryTokens.isEmpty else { return 0 }

        let corpus = patternCorpus(pattern)
        let patternTokens = tokenize(corpus)
        let overlap = Double(queryTokens.intersection(patternTokens).count)
        guard overlap > 0 else {
            let loweredText = signalText.lowercased()
            return signalCategories.contains(where: { categoryKeywords($0).contains(where: loweredText.contains) }) ? 0.18 : 0
        }

        let normalizedOverlap = overlap / Double(max(queryTokens.count, 1))
        let exactNameBoost = queryTokens.contains(where: { pattern.name.lowercased().contains($0) }) ? 0.15 : 0
        let categoryBoost = signalCategories.contains { category in
            categoryKeywords(category).contains { keyword in corpus.lowercased().contains(keyword) }
        } ? 0.18 : 0

        return min(1.0, normalizedOverlap + exactNameBoost + categoryBoost)
    }

    private static func patternCorpus(_ pattern: AttackPattern) -> String {
        [
            pattern.id,
            pattern.name,
            pattern.category,
            pattern.mitreTechnique,
            pattern.description,
            pattern.indicators.joined(separator: " "),
            pattern.detectionRules.joined(separator: " "),
            pattern.mitigations.joined(separator: " "),
            pattern.references.joined(separator: " "),
        ].joined(separator: " ")
    }

    private static func categoryKeywords(_ category: ThreatSignal.ThreatCategory) -> [String] {
        switch category {
        case .injection: return ["injection", "rce", "xss", "sqli", "ssti", "xxe", "log4shell"]
        case .headerAnomaly: return ["header", "bot", "scanner", "fingerprint", "proxy"]
        case .pathTraversal: return ["path", "traversal", "lfi", "directory", "config"]
        case .bruteForce: return ["brute", "auth", "credential", "fatigue"]
        case .dataExfil: return ["exfil", "tunnel", "archive", "dns", "outbound"]
        case .agentAnomaly: return ["agent", "intent", "hijack", "approval", "lease", "autonomy"]
        case .cryptoWeakness: return ["tls", "cipher", "crypto", "spectre", "side-channel"]
        case .configExposure: return ["config", "debug", "server", "metadata", "source", "exposure"]
        case .protocolAbuse: return ["agent card", "mcp", "a2a", "protocol", "manifest", "tool contract"]
        case .sessionIsolation: return ["session", "cookie", "token", "domain", "inheritance", "bleed"]
        case .identityFabric: return ["identity", "lease", "credential", "pass-through", "vpc", "operator"]
        case .provenanceLoss: return ["provenance", "taint", "context", "trace", "scrub", "memory"]
        case .browserIntegrity: return ["browser", "overlay", "approval", "click", "deterministic", "ui deception"]
        }
    }

    private static func tokenize(_ text: String) -> Set<String> {
        let scalars = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        let normalized = String(scalars)
        return Set(
            normalized
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .filter { $0.count > 2 }
        )
    }
}
