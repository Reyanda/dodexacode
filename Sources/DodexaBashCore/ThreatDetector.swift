import Foundation

// MARK: - Threat Detection Engine
// Detects attack patterns in logs, headers, requests, and agent behavior.
// Defensive tooling for security teams.

public struct ThreatSignal: Codable, Sendable {
    public let id: String
    public let category: ThreatCategory
    public let severity: ThreatSeverity
    public let description: String
    public let indicator: String       // what was detected
    public let recommendation: String
    public let detectedAt: Date

    public enum ThreatCategory: String, Codable, Sendable {
        case injection       // SQLi, XSS, command injection
        case headerAnomaly   // suspicious headers, bot signatures
        case pathTraversal   // directory traversal attempts
        case bruteForce      // rapid auth attempts
        case dataExfil       // unusual outbound data patterns
        case agentAnomaly    // AI agent behavioral anomalies
        case cryptoWeakness  // weak TLS, expired certs
        case configExposure  // exposed .env, .git, configs
        case protocolAbuse   // poisoned agent cards, unsafe registrations
        case sessionIsolation // cross-domain cookie/token bleed
        case identityFabric  // long-lived credentials, over-broad leases
        case provenanceLoss  // trace/context taint or suppression
        case browserIntegrity // UI deception and browser-control drift
    }

    public enum ThreatSeverity: String, Codable, Sendable {
        case critical, high, medium, low, info
    }
}

public struct ThreatReport: Codable, Sendable {
    public let target: String
    public let analyzedAt: Date
    public let signals: [ThreatSignal]
    public let riskScore: Double  // 0-100

    public var criticalCount: Int { signals.filter { $0.severity == .critical }.count }
    public var highCount: Int { signals.filter { $0.severity == .high }.count }
}

// MARK: - Detector Engine

public enum ThreatDetector {

    /// Analyze HTTP request/response for attack patterns
    public static func analyzeHTTP(url: String, headers: [String: String], body: String) -> [ThreatSignal] {
        var signals: [ThreatSignal] = []

        // Injection detection
        let injectionPatterns: [(String, String, String)] = [
            ("SQLi", "(?i)(union\\s+select|or\\s+1=1|drop\\s+table|;\\s*--)", "SQL injection attempt detected"),
            ("XSS", "(?i)(<script|javascript:|on\\w+=|<img\\s+src=)", "Cross-site scripting payload detected"),
            ("CMDi", "(?i)(;\\s*cat\\s|\\|\\s*ls|`.*`|\\$\\(.*\\))", "Command injection attempt detected"),
            ("LFI", "(\\.\\./|%2e%2e/|/etc/passwd|/proc/self)", "Local file inclusion attempt detected"),
            ("SSRF", "(?i)(169\\.254\\.169\\.254|localhost|127\\.0\\.0\\.1|0\\.0\\.0\\.0)", "SSRF attempt targeting internal services"),
            ("XXE", "(?i)(<!ENTITY|SYSTEM\\s+\"file:|<!DOCTYPE.*\\[)", "XML external entity injection detected"),
            ("SSTI", "(\\{\\{.*\\}\\}|\\$\\{.*\\}|<%.*%>)", "Server-side template injection pattern"),
            ("Log4Shell", "(?i)(\\$\\{jndi:|\\$\\{lower:|\\$\\{env:)", "Log4j exploitation attempt (CVE-2021-44228)"),
        ]

        let fullText = url + " " + headers.values.joined(separator: " ") + " " + body
        for (name, pattern, desc) in injectionPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: fullText, range: NSRange(fullText.startIndex..., in: fullText)) != nil {
                signals.append(ThreatSignal(
                    id: "INJ-\(name)", category: .injection, severity: .high,
                    description: desc, indicator: "Pattern: \(pattern)",
                    recommendation: "Block request. Investigate source IP. Review WAF rules.",
                    detectedAt: Date()
                ))
            }
        }

        // Header anomaly detection
        if let ua = headers["User-Agent"]?.lowercased() {
            let botSignatures = ["sqlmap", "nikto", "nmap", "masscan", "burp", "zap", "dirbuster",
                                 "gobuster", "ffuf", "nuclei", "wfuzz", "hydra", "metasploit"]
            for sig in botSignatures where ua.contains(sig) {
                signals.append(ThreatSignal(
                    id: "BOT-\(sig)", category: .headerAnomaly, severity: .medium,
                    description: "Known attack tool signature in User-Agent: \(sig)",
                    indicator: "User-Agent contains '\(sig)'",
                    recommendation: "Block or rate-limit. Likely automated scanning.",
                    detectedAt: Date()
                ))
            }

            if ua.isEmpty || ua.count < 5 {
                signals.append(ThreatSignal(
                    id: "HDR-EMPTY-UA", category: .headerAnomaly, severity: .low,
                    description: "Missing or very short User-Agent header",
                    indicator: "UA: '\(ua)'",
                    recommendation: "Flag for monitoring. May be automated traffic.",
                    detectedAt: Date()
                ))
            }
        }

        // Path traversal detection
        let pathTraversalPatterns = ["../", "..\\", "%2e%2e", "%252e%252e", "/etc/", "/proc/", "\\windows\\"]
        for pattern in pathTraversalPatterns where url.lowercased().contains(pattern) {
            signals.append(ThreatSignal(
                id: "PATH-TRAV", category: .pathTraversal, severity: .high,
                description: "Directory traversal attempt in URL",
                indicator: "URL contains '\(pattern)'",
                recommendation: "Block request. Sanitize path inputs. Restrict file access to webroot.",
                detectedAt: Date()
            ))
        }

        let loweredText = fullText.lowercased()

        let protocolMarkers = ["agent card", "navigator.modelcontext", "registertool", "modelcontext", "mcp manifest", "a2a"]
        let protocolControlTerms = ["ignore previous", "delegate", "grant access", "system prompt", "credential", "secret", "tool call"]
        if protocolMarkers.contains(where: loweredText.contains) && protocolControlTerms.contains(where: loweredText.contains) {
            signals.append(ThreatSignal(
                id: "PROTO-METADATA",
                category: .protocolAbuse,
                severity: .high,
                description: "Protocol metadata appears to carry instruction-bearing or credential-oriented content",
                indicator: "Agent-card / MCP / A2A terms mixed with imperative control phrases",
                recommendation: "Strip metadata from model context, validate against signed schemas, and inspect discovery sources.",
                detectedAt: Date()
            ))
        }

        let sessionStorageTerms = ["document.cookie", "localstorage", "sessionstorage", "authorization", "bearer "]
        if sessionStorageTerms.contains(where: loweredText.contains) &&
            (loweredText.contains("token") || loweredText.contains("session")) {
            signals.append(ThreatSignal(
                id: "SESSION-BLEED",
                category: .sessionIsolation,
                severity: .high,
                description: "Session material appears exposed to client-side or mixed-context handling",
                indicator: "Cookie/token storage terms present in browsed content",
                recommendation: "Split browser contexts by domain, harden storage handling, and review session inheritance.",
                detectedAt: Date()
            ))
        }

        let overlayTerms = ["opacity:0", "pointer-events:none", "z-index:9999", "position:fixed"]
        let approvalTerms = ["approve", "confirm", "continue", "allow"]
        if overlayTerms.contains(where: loweredText.contains) && approvalTerms.contains(where: loweredText.contains) {
            signals.append(ThreatSignal(
                id: "BROWSER-DECEPTION",
                category: .browserIntegrity,
                severity: .medium,
                description: "Potential UI deception markers detected around an approval or confirmation flow",
                indicator: "Overlay and approval language co-located in page content",
                recommendation: "Require structured action previews and inspect the DOM for click interception.",
                detectedAt: Date()
            ))
        }

        return signals
    }

    /// Analyze response headers for security posture
    public static func analyzeResponseHeaders(_ headers: [String: String]) -> [ThreatSignal] {
        var signals: [ThreatSignal] = []

        // Server info leakage
        if let server = headers.first(where: { $0.key.lowercased() == "server" })?.value {
            if server.contains("/") { // version number exposed
                signals.append(ThreatSignal(
                    id: "LEAK-SERVER", category: .configExposure, severity: .low,
                    description: "Server version exposed: \(server)",
                    indicator: "Server header with version",
                    recommendation: "Remove version from Server header.",
                    detectedAt: Date()
                ))
            }
        }

        // Debug headers
        let debugHeaders = ["X-Debug", "X-Debug-Token", "X-Powered-By", "X-Runtime",
                            "X-Request-Id", "X-AspNet-Version", "X-AspNetMvc-Version"]
        for dh in debugHeaders {
            if let val = headers.first(where: { $0.key.lowercased() == dh.lowercased() })?.value {
                signals.append(ThreatSignal(
                    id: "LEAK-DEBUG", category: .configExposure, severity: .medium,
                    description: "Debug/technology header exposed: \(dh): \(val)",
                    indicator: "\(dh) header present",
                    recommendation: "Remove \(dh) header in production.",
                    detectedAt: Date()
                ))
            }
        }

        return signals
    }

    /// Detect agent behavioral anomalies (for AI agent security)
    public static func analyzeAgentBehavior(
        recentCommands: [String],
        activeLeases: Int,
        intentStatement: String?,
        escalationAttempts: Int
    ) -> [ThreatSignal] {
        var signals: [ThreatSignal] = []

        // Privilege escalation pattern
        let escalationKeywords = ["sudo", "chmod 777", "chown root", "su -", "/etc/shadow", "/etc/passwd"]
        let escalationCount = recentCommands.filter { cmd in
            escalationKeywords.contains(where: { cmd.lowercased().contains($0) })
        }.count

        if escalationCount >= 2 {
            signals.append(ThreatSignal(
                id: "AGENT-ESCALATION", category: .agentAnomaly, severity: .high,
                description: "Agent attempting privilege escalation (\(escalationCount) attempts)",
                indicator: "Multiple sudo/chmod/chown commands",
                recommendation: "Revoke agent leases. Review intent declaration. Restrict capabilities.",
                detectedAt: Date()
            ))
        }

        if escalationAttempts >= 3 {
            signals.append(ThreatSignal(
                id: "AGENT-ESCALATION-PERSISTENT", category: .agentAnomaly, severity: .critical,
                description: "Repeated escalation attempts persisted across recent history",
                indicator: "\(escalationAttempts) escalation-oriented commands in recent history",
                recommendation: "Pause the agent, revoke leases, and inspect the full command chain for manipulation.",
                detectedAt: Date()
            ))
        }

        // Data exfiltration pattern
        let exfilKeywords = ["curl -d", "wget --post", "base64", "tar czf", "zip -r", "scp ", "rsync "]
        let exfilCount = recentCommands.filter { cmd in
            exfilKeywords.contains(where: { cmd.lowercased().contains($0) })
        }.count

        if exfilCount >= 2 {
            signals.append(ThreatSignal(
                id: "AGENT-EXFIL", category: .dataExfil, severity: .critical,
                description: "Possible data exfiltration pattern (\(exfilCount) suspicious commands)",
                indicator: "Archive + upload commands in sequence",
                recommendation: "Immediately revoke all leases. Audit recent file access. Check network logs.",
                detectedAt: Date()
            ))
        }

        // Intent mismatch
        if let intent = intentStatement {
            let destructiveWithoutIntent = recentCommands.filter { cmd in
                let lc = cmd.lowercased()
                return (lc.contains("rm ") || lc.contains("drop ") || lc.contains("delete ")) &&
                       !intent.lowercased().contains("delete") && !intent.lowercased().contains("remove")
            }
            if !destructiveWithoutIntent.isEmpty {
                signals.append(ThreatSignal(
                    id: "AGENT-INTENT-MISMATCH", category: .agentAnomaly, severity: .high,
                    description: "Destructive commands executed outside declared intent",
                    indicator: "Intent: '\(intent)' but ran: \(destructiveWithoutIntent.first ?? "")",
                    recommendation: "Agent is acting outside declared scope. Revoke leases and audit.",
                    detectedAt: Date()
                ))
            }
        }

        // No lease but acting
        if activeLeases == 0 && recentCommands.count > 5 {
            signals.append(ThreatSignal(
                id: "AGENT-NO-LEASE", category: .agentAnomaly, severity: .medium,
                description: "Agent executing commands without any active capability lease",
                indicator: "\(recentCommands.count) commands, 0 leases",
                recommendation: "Require lease grants before agent operations.",
                detectedAt: Date()
            ))
        }

        let loweredCommands = recentCommands.map { $0.lowercased() }

        let protocolCommands = loweredCommands.filter { cmd in
            let protocolTerms = ["agent card", "mcp", "a2a", "modelcontext", "registertool", "tool contract"]
            let controlTerms = ["grant", "delegate", "register", "curl", "post", "inject"]
            return protocolTerms.contains(where: cmd.contains) && controlTerms.contains(where: cmd.contains)
        }
        if !protocolCommands.isEmpty {
            signals.append(ThreatSignal(
                id: "AGENT-PROTOCOL-ABUSE",
                category: .protocolAbuse,
                severity: .high,
                description: "Recent commands suggest unsafely mutating agent protocol registrations or discovery surfaces",
                indicator: protocolCommands.first ?? "",
                recommendation: "Freeze protocol registration, validate manifests, and review downstream trust boundaries.",
                detectedAt: Date()
            ))
        }

        let sessionCommands = loweredCommands.filter { cmd in
            ["cookie", "session", "token", "localstorage", "sessionstorage", "browser profile"].contains(where: cmd.contains)
        }
        let sensitiveRealms = Set(sessionCommands.flatMap { cmd in
            ["mail", "gmail", "bank", "payment", "admin", "github", "slack", "drive"].filter(cmd.contains)
        })
        if sessionCommands.count >= 2 && sensitiveRealms.count >= 2 {
            signals.append(ThreatSignal(
                id: "AGENT-SESSION-BLEED",
                category: .sessionIsolation,
                severity: .critical,
                description: "Session-oriented commands span multiple sensitive realms in one runtime window",
                indicator: "Realms: \(sensitiveRealms.sorted().joined(separator: ", "))",
                recommendation: "Split the workflow into isolated contexts and revoke inherited session state.",
                detectedAt: Date()
            ))
        }

        let credentialCommands = loweredCommands.filter { cmd in
            ["aws_access_key_id", "aws_secret_access_key", "google_application_credentials", "azure_client_secret", ".env", "id_rsa", "lease grant"].contains(where: cmd.contains)
        }
        let wildcardLease = loweredCommands.contains { $0.contains("lease grant") && ($0.contains(" * ") || $0.hasSuffix(" *") || $0.contains(" all ")) }
        if wildcardLease || activeLeases > 8 || credentialCommands.count >= 2 {
            signals.append(ThreatSignal(
                id: "IDENTITY-FABRIC",
                category: .identityFabric,
                severity: wildcardLease ? .critical : .high,
                description: "Identity scope appears broader or longer-lived than an accountable agent runtime should allow",
                indicator: wildcardLease ? "Wildcard or broadly scoped lease activity" : "Credential-bearing commands or excessive active leases",
                recommendation: "Move to pass-through auth, shrink lease scope, and revoke long-lived credentials.",
                detectedAt: Date()
            ))
        }

        let provenanceCommands = loweredCommands.filter { cmd in
            ["history -c", "unset histfile", "truncate", "rm ", "clear context", "wipe memory", "scrub trace", "delete log"].contains(where: cmd.contains)
        }
        if provenanceCommands.count >= 2 {
            signals.append(ThreatSignal(
                id: "PROVENANCE-LOSS",
                category: .provenanceLoss,
                severity: .high,
                description: "Recent commands suggest audit, trace, or context provenance suppression",
                indicator: provenanceCommands.first ?? "",
                recommendation: "Preserve immutable traces, rebuild context from trusted checkpoints, and review the full session.",
                detectedAt: Date()
            ))
        }

        return signals
    }

    // MARK: - Rendering

    public static func renderTerminal(_ report: ThreatReport) -> String {
        var lines: [String] = []
        lines.append("Threat Detection: \(report.target)")
        lines.append("Risk Score: \(String(format: "%.0f", report.riskScore))/100")
        lines.append("\(report.signals.count) signals (\(report.criticalCount) critical, \(report.highCount) high)")
        lines.append(String(repeating: "=", count: 50))

        for signal in report.signals {
            let icon: String
            switch signal.severity {
            case .critical: icon = "\u{1F534}"
            case .high: icon = "\u{1F7E0}"
            case .medium: icon = "\u{1F7E1}"
            case .low: icon = "\u{1F7E2}"
            case .info: icon = "\u{2139}\u{FE0F}"
            }
            lines.append("")
            lines.append("\(icon) [\(signal.severity.rawValue.uppercased())] \(signal.description)")
            lines.append("   Indicator: \(signal.indicator)")
            lines.append("   Action: \(signal.recommendation)")
        }

        return lines.joined(separator: "\n")
    }
}
