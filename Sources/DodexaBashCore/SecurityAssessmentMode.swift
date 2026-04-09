import Foundation

enum SecurityAssessmentMode: String, Codable, Sendable, CaseIterable {
    case passive
    case active
    case lab

    var rank: Int {
        switch self {
        case .passive: return 0
        case .active: return 1
        case .lab: return 2
        }
    }

    func satisfies(_ minimum: SecurityAssessmentMode) -> Bool {
        rank >= minimum.rank
    }

    var summary: String {
        switch self {
        case .passive:
            return "Passive inspection only: DNS, TLS, headers, catalog lookup, and single-request review."
        case .active:
            return "Authorized active assessment: scoped scanning, method checks, and controlled crawl."
        case .lab:
            return "Disposable lab only: high-impact validation and resilience tests against private/test targets."
        }
    }
}

extension Builtins {
    static func currentSecurityAssessmentMode(runtime: BuiltinRuntime) -> SecurityAssessmentMode {
        guard let policy = runtime.runtimeStore.activePolicy else {
            return .passive
        }

        for rule in policy.rules.reversed() {
            let domain = rule.domain.lowercased()
            let constraint = rule.constraint.lowercased()
            guard domain.contains("security") || domain.contains("assessment") || constraint.contains("mode") else {
                continue
            }

            if constraint.contains("mode:lab") || constraint.contains("mode=lab") || constraint.contains("lab-only") || constraint == "lab" {
                return .lab
            }
            if constraint.contains("mode:active") || constraint.contains("mode=active") || constraint == "active" {
                return .active
            }
            if constraint.contains("mode:passive") || constraint.contains("mode=passive") || constraint == "passive" {
                return .passive
            }
        }

        return .passive
    }

    static func requireSecurityAssessmentMode(
        runtime: BuiltinRuntime,
        minimum: SecurityAssessmentMode,
        command: String,
        rationale: String
    ) -> CommandResult? {
        let current = currentSecurityAssessmentMode(runtime: runtime)
        guard current.satisfies(minimum) else {
            return textError("""
            Security assessment mode '\(current.rawValue)' blocks `\(command)`.
            Required mode: \(minimum.rawValue)
            Reason: \(rationale)

            Set an explicit policy first:
              policy set security mode:\(minimum.rawValue) hard

            Current mode guidance:
              \(current.summary)
            Required mode guidance:
              \(minimum.summary)

            """, status: 1)
        }
        return nil
    }

    static func rejectDeprecatedStealthFlag(args: [String], command: String) -> CommandResult? {
        guard args.contains("--stealth") else { return nil }
        return textError("""
        `--stealth` is not supported for `\(command)`.
        Use explicit assessment controls instead:
          policy set security mode:passive hard
          policy set security mode:active hard
          policy set security mode:lab hard

        The shell preserves scope and auditability instead of masking attribution.
        """, status: 1)
    }

    static func requireLabTarget(resource: String, command: String) -> CommandResult? {
        guard isLabTarget(resource) else {
            return textError("""
            `\(command)` is restricted to private or test-only lab targets.
            Accepted examples: localhost, 127.0.0.1, 10.0.0.0/8, 192.168.0.0/16, *.local, *.test, *.example
            Received: \(resource)
            """, status: 1)
        }
        return nil
    }

    static func securityAssessmentBanner(runtime: BuiltinRuntime) -> String {
        "Assessment mode: \(currentSecurityAssessmentMode(runtime: runtime).rawValue.uppercased())"
    }

    private static func isLabTarget(_ resource: String) -> Bool {
        let normalized = normalizedAssessmentHost(resource)

        if normalized == "localhost" || normalized == "::1" {
            return true
        }
        if normalized.hasSuffix(".local") || normalized.hasSuffix(".test") || normalized.hasSuffix(".example") || normalized.hasSuffix(".invalid") {
            return true
        }
        if normalized.hasPrefix("127.") || normalized.hasPrefix("10.") || normalized.hasPrefix("192.168.") {
            return true
        }
        if normalized.hasPrefix("172."),
           let secondOctet = normalized.split(separator: ".").dropFirst().first,
           let octet = Int(secondOctet),
           (16...31).contains(octet) {
            return true
        }
        if normalized.hasPrefix("fd") || normalized.hasPrefix("fc") {
            return true
        }

        return false
    }

    private static func normalizedAssessmentHost(_ resource: String) -> String {
        var candidate = resource.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.contains("://"), candidate.contains("/") {
            candidate = String(candidate.split(separator: "/").first ?? Substring(candidate))
        }
        if !candidate.contains("://") {
            candidate = "https://\(candidate)"
        }

        if let url = URL(string: candidate), let host = url.host {
            return host.lowercased()
        }

        let hostPart = candidate.split(separator: "/").first.map(String.init) ?? candidate
        return hostPart.split(separator: ":").first.map(String.init)?.lowercased() ?? candidate.lowercased()
    }
}
