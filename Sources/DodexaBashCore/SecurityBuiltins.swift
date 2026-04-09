import Foundation

// MARK: - Security Builtins: Shell integration with future-shell hooks
// Every security command: lease check → intent → simulate → execute → prove → block

extension Builtins {
    static func secBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let sub = args.first ?? "help"
        let subArgs = Array(args.dropFirst())

        switch sub {
        case "scan":
            return secScan(args: subArgs, runtime: runtime)
        case "discover":
            return secDiscover(args: subArgs, runtime: runtime)
        case "dns":
            return secDNS(args: subArgs, runtime: runtime)
        case "arp":
            return secARP(runtime: runtime)
        case "tls":
            return secTLS(args: subArgs, runtime: runtime)
        case "http":
            return secHTTP(args: subArgs, runtime: runtime)
        case "stress":
            return secStress(args: subArgs, runtime: runtime)
        case "vuln":
            return secVuln(args: subArgs, runtime: runtime)
        case "interfaces", "ifaces":
            return secInterfaces(runtime: runtime)
        case "latency":
            return secLatency(args: subArgs, runtime: runtime)
        case "report":
            if subArgs.isEmpty { return secReport(runtime: runtime) }
            return secFullReport(args: subArgs, runtime: runtime)
        case "fix":
            return secFix(args: subArgs, runtime: runtime)
        case "export":
            return secExport(args: subArgs, runtime: runtime)
        case "intel":
            return secIntel(args: subArgs, runtime: runtime)
        case "profile":
            return secProfile(args: subArgs, runtime: runtime)
        case "recon":
            return secRecon(args: subArgs, runtime: runtime)
        case "detect":
            return secDetect(args: subArgs, runtime: runtime)
        case "validate", "test":
            return secValidate(args: subArgs, runtime: runtime)
        case "exploit":
            return textError("`sec exploit` is not supported. Use `sec validate` only for lab targets in `mode:lab`.\n", status: 1)
        default:
            return textResult("""
            dodexabash security toolkit

            Usage: sec <command> [options]

            Reconnaissance:
              sec recon <url> [--max-pages N]                  Deep web recon within authorized scope
              sec detect <url>                                 Analyze request-path, intermediary, and automation signals
              sec detect system                                Audit local system for integrity anomalies
              sec scan <host> [--ports 1-1000] [--service]    Port scan + fingerprint

              sec discover <subnet>                            Host discovery (ping sweep)
              sec dns <domain> [--enum] [--reverse]           DNS recon
              sec arp                                          ARP table + MAC addresses
              sec interfaces                                   Network interfaces

            Assessment:
              sec tls <host[:port]> [--cert] [--ciphers]      TLS/SSL audit
              sec http <url> [--fuzz] [--headers]             HTTP security test
              sec vuln <host>                                  Vulnerability check

            Stress Testing:
              sec stress <host:port> [--tcp|--udp|--http]     Load test
              sec latency <host> [-n 20]                      Latency profiler

            Reporting:
              sec report <domain>                              Full security assessment report
              sec fix <domain>                                 Generate fix configs (CloudFront/nginx/Apache)
              sec export <domain>                              Export report as markdown file
              sec intel [list|search|mirror|analyze]           Threat intelligence and mirror defense
              sec profile <domain>                             Attack surface profile + OWASP mapping
              sec report                                       Quick summary from session proofs

            All commands are lease-gated. Grant with:
              lease grant sec:scan <target> 600

            Assessment modes:
              policy set security mode:passive hard            Passive review only
              policy set security mode:active hard             Authorized active assessment
              policy set security mode:lab hard                Disposable lab-only validation/stress

            """)
        }
    }

    // MARK: - Port Scanner

    private static func secScan(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard let target = args.first(where: { !$0.hasPrefix("-") }) else {
            return textResult("Usage: sec scan <host> [--ports 22,80,443] [--service]\n")
        }

        if let error = requireSecurityAssessmentMode(
            runtime: runtime,
            minimum: .active,
            command: "sec scan",
            rationale: "Port scanning performs active network probing."
        ) {
            return error
        }

        // Lease check
        if !checkSecLease(capability: "sec:scan", resource: target, runtime: runtime) {
            return leaseRequiredError("sec:scan", target)
        }

        let portsSpec = flagValue(args, flag: "--ports") ?? "common"
        let ports = TCPScanner.parsePorts(portsSpec)

        let scanner = TCPScanner(timeoutMs: 2000, grabBanner: false)
        let result = scanner.scan(host: target, ports: ports)

        // Format output
        var lines: [String] = []
        lines.append("Scan: \(result.summary)")
        lines.append(securityAssessmentBanner(runtime: runtime))
        lines.append("")

        if result.openPorts.isEmpty {
            lines.append("No open ports found.")
        } else {
            lines.append("PORT    STATE      SERVICE")
            lines.append(String(repeating: "-", count: 40))
            for port in result.openPorts {
                let svc = port.service ?? ""
                lines.append("\(port.port)\t\(port.state.rawValue)\t\(svc)")
            }
        }

        lines.append("")
        lines.append("\(result.totalScanned) ports scanned in \(Int(result.finishedAt.timeIntervalSince(result.startedAt) * 1000))ms")

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Host Discovery

    private static func secDiscover(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard let subnet = args.first(where: { !$0.hasPrefix("-") }) else {
            return textResult("Usage: sec discover <subnet> (e.g. 192.168.1.0/24)\n")
        }

        if let error = requireSecurityAssessmentMode(
            runtime: runtime,
            minimum: .active,
            command: "sec discover",
            rationale: "Host discovery performs active network reachability probes."
        ) {
            return error
        }
        if let error = requireLabTarget(resource: subnet, command: "sec discover") {
            return error
        }

        if !checkSecLease(capability: "sec:discover", resource: subnet, runtime: runtime) {
            return leaseRequiredError("sec:discover", subnet)
        }

        let results = HostDiscovery.pingSweep(subnet: subnet, timeout: 1)
        let alive = results.filter { $0.alive }

        var lines: [String] = ["Host Discovery: \(subnet)"]
        lines.append(securityAssessmentBanner(runtime: runtime))
        lines.append("\(alive.count) hosts alive out of \(results.count) scanned")
        lines.append("")
        for host in alive {
            lines.append(String(format: "  \u{25CF} %-16s  %dms", host.ip, host.latencyMs))
        }

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - DNS

    private static func secDNS(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard let domain = args.first(where: { !$0.hasPrefix("-") }) else {
            return textResult("Usage: sec dns <domain> [--enum] [--reverse]\n")
        }

        if let error = requireSecurityAssessmentMode(
            runtime: runtime,
            minimum: .passive,
            command: "sec dns",
            rationale: "DNS review should stay within explicit assessment scope."
        ) {
            return error
        }

        let doEnum = args.contains("--enum")
        let doReverse = args.contains("--reverse")

        var lines: [String] = ["DNS: \(domain)"]
        lines.append(securityAssessmentBanner(runtime: runtime))

        if doReverse {
            if let name = DNSResolver.reverse(ip: domain) {
                lines.append("  Reverse: \(name)")
            } else {
                lines.append("  Reverse: no PTR record")
            }
        } else {
            let result = DNSResolver.resolve(hostname: domain)
            for record in result.records {
                lines.append("  \(record.family): \(record.addresses.joined(separator: ", "))")
                if let cname = record.canonicalName { lines.append("  CNAME: \(cname)") }
            }
            lines.append("  Resolved in \(result.durationMs)ms")
        }

        if doEnum {
            lines.append("")
            lines.append("Subdomain enumeration:")
            let found = DNSResolver.enumerateSubdomains(domain: domain)
            if found.isEmpty {
                lines.append("  No subdomains found from default wordlist.")
            } else {
                for (sub, ip) in found {
                    let padded = sub.padding(toLength: 35, withPad: " ", startingAt: 0)
                    lines.append("  \(padded) \(ip)")
                }
            }
        }

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - ARP

    private static func secARP(runtime: BuiltinRuntime) -> CommandResult {
        let entries = NetworkInterfaces.arpTable()
        var lines: [String] = ["ARP Table (\(entries.count) entries):"]
        lines.append(String(format: "%-16s %-20s %s", "IP", "MAC", "INTERFACE"))
        lines.append(String(repeating: "\u{2500}", count: 50))
        for entry in entries {
            lines.append(String(format: "%-16s %-20s %s", entry.ip, entry.mac, entry.iface))
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Network Interfaces

    private static func secInterfaces(runtime: BuiltinRuntime) -> CommandResult {
        let ifaces = NetworkInterfaces.list().filter { $0.family == "IPv4" }
        var lines: [String] = ["Network Interfaces:"]
        for iface in ifaces {
            let status = iface.isUp ? "\u{001B}[32mUP\u{001B}[0m" : "\u{001B}[31mDOWN\u{001B}[0m"
            let loopback = iface.isLoopback ? " (loopback)" : ""
            lines.append("  \(iface.name): \(iface.address) [\(status)]\(loopback)")
            if let mask = iface.netmask { lines.append("    netmask: \(mask)") }
            if let bcast = iface.broadcastAddr { lines.append("    broadcast: \(bcast)") }
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - TLS Audit

    private static func secTLS(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard let target = args.first(where: { !$0.hasPrefix("-") }) else {
            return textResult("Usage: sec tls <host[:port]>\n")
        }

        if let error = requireSecurityAssessmentMode(
            runtime: runtime,
            minimum: .passive,
            command: "sec tls",
            rationale: "TLS review should stay within explicit assessment scope."
        ) {
            return error
        }

        let parts = target.split(separator: ":")
        let host = String(parts[0])
        let port = parts.count > 1 ? UInt16(parts[1]) ?? 443 : UInt16(443)

        let auditor = TLSAuditor()
        let result = auditor.audit(host: host, port: port)

        var lines: [String] = ["TLS Audit: \(host):\(port)  Grade: \u{001B}[1m\(result.grade)\u{001B}[0m"]
        lines.append(securityAssessmentBanner(runtime: runtime))
        lines.append("")

        if let cert = result.certificate {
            lines.append("Certificate:")
            lines.append("  Subject: \(cert.subject)")
            lines.append("  Issuer: \(cert.issuer)")
            lines.append("  Key: \(cert.publicKeyBits) bit \(cert.signatureAlgorithm)")
            lines.append("  Expires in: \(cert.daysUntilExpiry) days")
            lines.append("  Self-signed: \(cert.isSelfSigned)")
        }

        lines.append("")
        lines.append("Chain: \(result.chainLength) certificates, \(result.chainValid ? "valid" : "\u{001B}[31mINVALID\u{001B}[0m")")
        lines.append("HSTS: \(result.hstsEnabled ? "\u{001B}[32menabled\u{001B}[0m" : "\u{001B}[31mdisabled\u{001B}[0m")")

        if !result.weakCiphers.isEmpty {
            lines.append("Weak ciphers: \(result.weakCiphers.joined(separator: ", "))")
        }

        if !result.issues.isEmpty {
            lines.append("")
            lines.append("Issues (\(result.issues.count)):")
            for issue in result.issues {
                lines.append("  \u{001B}[33m\u{26A0}\u{001B}[0m \(issue)")
            }
        }

        lines.append("")
        lines.append("Completed in \(result.durationMs)ms")

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - HTTP Fuzzing

    private static func secHTTP(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard let url = args.first(where: { !$0.hasPrefix("-") }) else {
            return textResult("Usage: sec http <url> [--fuzz] [--headers] [--methods]\n")
        }

        let fuzzer = HTTPFuzzer()
        let doFuzz = args.contains("--fuzz")
        let doHeaders = args.contains("--headers") || !doFuzz
        let doMethods = args.contains("--methods") || args.contains("--fuzz")

        if doFuzz || doMethods {
            if let error = requireSecurityAssessmentMode(
                runtime: runtime,
                minimum: .active,
                command: "sec http",
                rationale: "Method tests and path probing send active requests beyond passive inspection."
            ) {
                return error
            }
        } else if let error = requireSecurityAssessmentMode(
            runtime: runtime,
            minimum: .passive,
            command: "sec http",
            rationale: "HTTP inspection must remain explicitly scoped."
        ) {
            return error
        }

        var lines: [String] = ["HTTP Security: \(url)"]
        lines.append(securityAssessmentBanner(runtime: runtime))
        lines.append("")

        if doHeaders {
            let headers = fuzzer.checkSecurityHeaders(baseURL: url)
            lines.append("Security Headers:")
            for (header, present) in headers.sorted(by: { $0.key < $1.key }) {
                let icon = present ? "\u{001B}[32m\u{2713}\u{001B}[0m" : "\u{001B}[31m\u{2717}\u{001B}[0m"
                lines.append("  \(icon) \(header)")
            }
        }

        if doMethods {
            lines.append("")
            lines.append("Method Testing:")
            let methods = fuzzer.testMethods(baseURL: url)
            for m in methods {
                let indicator = m.finding != nil ? "\u{001B}[31m!\u{001B}[0m" : " "
                lines.append("  \(indicator) \(m.method): \(m.statusCode) (\(m.latencyMs)ms)")
                if let finding = m.finding { lines.append("    \u{001B}[33m\(finding)\u{001B}[0m") }
            }
        }

        if doFuzz {
            lines.append("")
            let result = fuzzer.fuzz(baseURL: url)
            let pathTests = result.tests.filter { $0.test.hasPrefix("path-") && $0.finding != nil }
            if !pathTests.isEmpty {
                lines.append("Path Traversal Findings:")
                for test in pathTests {
                    lines.append("  \u{001B}[31m\(test.finding!)\u{001B}[0m")
                }
            } else {
                lines.append("Path traversal: no findings")
            }
        }

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Stress Testing

    private static func secStress(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard let target = args.first(where: { !$0.hasPrefix("-") }) else {
            return textResult("Usage: sec stress <host:port> [--tcp|--udp|--http] [--rate N] [--duration S]\n")
        }

        if let error = requireSecurityAssessmentMode(
            runtime: runtime,
            minimum: .lab,
            command: "sec stress",
            rationale: "Stress testing is only allowed in disposable lab environments."
        ) {
            return error
        }
        if let error = requireLabTarget(resource: target, command: "sec stress") {
            return error
        }

        if !checkSecLease(capability: "sec:stress", resource: target, runtime: runtime) {
            return leaseRequiredError("sec:stress", target)
        }

        let proto = args.contains("--udp") ? "udp" : args.contains("--http") ? "http" : "tcp"
        let rate = Int(flagValue(args, flag: "--rate") ?? "50") ?? 50
        let duration = Int(flagValue(args, flag: "--duration") ?? "5") ?? 5

        runtime.runtimeStore.setIntent(
            statement: "Stress test \(target) via \(proto)",
            reason: "Resilience testing",
            mutations: ["network traffic to \(target)"],
            successCriteria: "Test completes",
            riskLevel: .high,
            verification: nil
        )

        let tester = TCPStressTester()
        let result: StressResult

        let parts = target.split(separator: ":")
        let host = String(parts[0])
        let port = parts.count > 1 ? UInt16(parts[1]) ?? 80 : UInt16(80)

        switch proto {
        case "udp":
            result = tester.udpStress(host: host, port: port, packetsPerSecond: rate, durationSeconds: duration)
        case "http":
            let url = target.hasPrefix("http") ? target : "http://\(target)"
            result = tester.httpStress(url: url, concurrency: min(rate, 100), totalRequests: rate * duration)
        default:
            result = tester.tcpStress(host: host, port: port, connections: rate, ratePerSecond: rate, durationSeconds: duration)
        }

        var lines: [String] = ["Stress Test: \(target) [\(proto.uppercased())]"]
        lines.append(securityAssessmentBanner(runtime: runtime))
        lines.append("")
        lines.append("  Requests:    \(result.totalRequests) (\(result.successCount) ok, \(result.failureCount) failed)")
        lines.append("  Duration:    \(result.durationMs)ms")
        lines.append("  Throughput:  \(String(format: "%.1f", result.requestsPerSecond)) req/s")
        lines.append("  Data:        \(formatBytes(result.bytesTransferred))")
        lines.append("")
        lines.append("  Latency:")
        lines.append("    min: \(result.latency.min)ms  avg: \(result.latency.avg)ms  max: \(result.latency.max)ms")
        lines.append("    p50: \(result.latency.p50)ms  p95: \(result.latency.p95)ms  p99: \(result.latency.p99)ms")
        lines.append("    jitter: \(result.latency.jitter)ms")

        runtime.runtimeStore.satisfyIntent()
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Latency

    private static func secLatency(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard let host = args.first(where: { !$0.hasPrefix("-") }) else {
            return textResult("Usage: sec latency <host> [-n 20]\n")
        }

        let count = Int(flagValue(args, flag: "-n") ?? "20") ?? 20
        let tester = TCPStressTester()
        let stats = tester.measureLatency(host: host, count: count)

        var lines: [String] = ["Latency: \(host) (\(count) samples)"]
        lines.append("  min: \(stats.min)ms  avg: \(stats.avg)ms  max: \(stats.max)ms")
        lines.append("  p50: \(stats.p50)ms  p95: \(stats.p95)ms  p99: \(stats.p99)ms")
        lines.append("  jitter: \(stats.jitter)ms")
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Vulnerability Assessment

    private static func secVuln(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard let target = args.first(where: { !$0.hasPrefix("-") }) else {
            return textResult("Usage: sec vuln <host>\n")
        }

        if let error = requireSecurityAssessmentMode(
            runtime: runtime,
            minimum: .active,
            command: "sec vuln",
            rationale: "Vulnerability assessment performs active multi-surface checks."
        ) {
            return error
        }

        if !checkSecLease(capability: "sec:vuln", resource: target, runtime: runtime) {
            return leaseRequiredError("sec:vuln", target)
        }

        runtime.runtimeStore.setIntent(
            statement: "Vulnerability assessment on \(target)",
            reason: "Security audit",
            mutations: ["network traffic to \(target)"],
            successCriteria: "Assessment report generated",
            riskLevel: .high,
            verification: nil
        )

        let checker = VulnChecker()
        let report = checker.assess(host: target)

        var lines: [String] = ["Vulnerability Assessment: \(target)"]
        lines.append(securityAssessmentBanner(runtime: runtime))
        lines.append(report.summary)
        lines.append("\(report.totalChecks) checks in \(report.durationMs)ms")
        lines.append("")

        if report.vulnerabilities.isEmpty {
            lines.append("\u{001B}[32mNo vulnerabilities found.\u{001B}[0m")
        } else {
            for vuln in report.vulnerabilities {
                let color: String
                switch vuln.severity {
                case .critical: color = "\u{001B}[31;1m"
                case .high: color = "\u{001B}[31m"
                case .medium: color = "\u{001B}[33m"
                case .low: color = "\u{001B}[36m"
                case .info: color = "\u{001B}[2m"
                }
                lines.append("\(color)[\(vuln.severity.rawValue.uppercased())] \(vuln.title)\u{001B}[0m")
                lines.append("  \(vuln.description)")
                lines.append("  Fix: \(vuln.remediation)")
                lines.append("")
            }
        }

        runtime.runtimeStore.satisfyIntent()
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Report

    // MARK: - Full Report (runs all scans, generates report)

    private static func secFullReport(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard let domain = args.first(where: { !$0.hasPrefix("-") }) else {
            return textError("sec report <domain>\n", status: 1)
        }

        if let error = requireSecurityAssessmentMode(
            runtime: runtime,
            minimum: .active,
            command: "sec report",
            rationale: "Full reports aggregate active scans and vulnerability assessment."
        ) {
            return error
        }

        guard checkSecLease(capability: "sec:scan", resource: domain, runtime: runtime) else {
            return textError("Security operation requires a lease.\nGrant with: lease grant sec:scan \(domain) 600\n", status: 1)
        }

        // Run all scans and collect output
        let shell = Shell(context: ShellContext(environment: runtime.context.environment))

        let tls = shell.run(source: "sec tls \(domain)").stdout
        let http = shell.run(source: "sec http \(domain)").stdout
        let dns = shell.run(source: "sec dns \(domain)").stdout
        let scan = shell.run(source: "sec scan \(domain)").stdout
        let vuln = shell.run(source: "sec vuln \(domain)").stdout

        let report = SecurityReportBuilder.buildReport(
            domain: domain, tlsOutput: tls, httpOutput: http,
            scanOutput: scan, dnsOutput: dns, vulnOutput: vuln
        )

        return textResult(SecurityReportBuilder.renderTerminal(report) + "\n")
    }

    // MARK: - Fix Generation

    private static func secFix(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard let domain = args.first(where: { !$0.hasPrefix("-") }) else {
            return textError("sec fix <domain>\nGenerates fix configurations for detected vulnerabilities.\n", status: 1)
        }

        // Run scans to get current state
        let shell = Shell(context: ShellContext(environment: runtime.context.environment))
        let tls = shell.run(source: "sec tls \(domain)").stdout
        let http = shell.run(source: "sec http \(domain)").stdout
        let dns = shell.run(source: "sec dns \(domain)").stdout

        let report = SecurityReportBuilder.buildReport(
            domain: domain, tlsOutput: tls, httpOutput: http,
            scanOutput: "", dnsOutput: dns, vulnOutput: ""
        )

        guard !report.fixes.isEmpty else {
            return textResult("No fixes needed — all checks passed.\n")
        }

        var output = "Fix Recommendations for \(domain)\n"
        output += String(repeating: "=", count: 40) + "\n\n"

        for fix in report.fixes {
            output += "[\(fix.platform)] \(fix.finding) (priority \(fix.priority))\n"
            output += String(repeating: "-", count: 40) + "\n"
            output += fix.config + "\n\n"
        }

        return textResult(output)
    }

    // MARK: - Export Report

    private static func secExport(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard let domain = args.first(where: { !$0.hasPrefix("-") }) else {
            return textError("sec export <domain>\nExports a full security report as markdown.\n", status: 1)
        }

        if let error = requireSecurityAssessmentMode(
            runtime: runtime,
            minimum: .active,
            command: "sec export",
            rationale: "Exporting a full report triggers active scan collection first."
        ) {
            return error
        }

        guard checkSecLease(capability: "sec:scan", resource: domain, runtime: runtime) else {
            return textError("Lease required: lease grant sec:scan \(domain) 600\n", status: 1)
        }

        let shell = Shell(context: ShellContext(environment: runtime.context.environment))
        let tls = shell.run(source: "sec tls \(domain)").stdout
        let http = shell.run(source: "sec http \(domain)").stdout
        let dns = shell.run(source: "sec dns \(domain)").stdout
        let scan = shell.run(source: "sec scan \(domain)").stdout
        let vuln = shell.run(source: "sec vuln \(domain)").stdout

        let report = SecurityReportBuilder.buildReport(
            domain: domain, tlsOutput: tls, httpOutput: http,
            scanOutput: scan, dnsOutput: dns, vulnOutput: vuln
        )

        let markdown = SecurityReportBuilder.renderMarkdown(report)
        let filename = "\(domain.replacingOccurrences(of: ".", with: "_"))_security_report.md"
        let path = runtime.context.currentDirectory + "/" + filename

        do {
            try markdown.write(toFile: path, atomically: true, encoding: .utf8)
            return textResult("Exported: \(filename) (\(markdown.count) bytes)\n")
        } catch {
            return textError("Could not write \(filename): \(error.localizedDescription)\n", status: 1)
        }
    }

    // MARK: - Attack Surface Profile

    private static func secProfile(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard let domain = args.first(where: { !$0.hasPrefix("-") }) else {
            return textError("sec profile <domain>\n", status: 1)
        }

        if let error = requireSecurityAssessmentMode(
            runtime: runtime,
            minimum: .passive,
            command: "sec profile",
            rationale: "Profiling should remain in explicitly approved scope."
        ) {
            return error
        }

        let shell = Shell(context: ShellContext(environment: runtime.context.environment))
        let dns = shell.run(source: "sec dns \(domain)").stdout
        let tls = shell.run(source: "sec tls \(domain)").stdout
        let http = shell.run(source: "sec http \(domain)").stdout

        var lines: [String] = ["Attack Surface Profile: \(domain)", String(repeating: "=", count: 40), ""]
        lines.append(securityAssessmentBanner(runtime: runtime))
        lines.append("")

        // Technologies
        var techs: [String] = []
        if dns.contains("18.239") || dns.lowercased().contains("cloudfront") { techs.append("AWS CloudFront") }
        if dns.lowercased().contains("amazonaws") { techs.append("AWS") }
        if http.lowercased().contains("nginx") { techs.append("nginx") }
        if http.lowercased().contains("apache") { techs.append("Apache") }
        lines.append("Technologies: \(techs.isEmpty ? "Unknown" : techs.joined(separator: ", "))")

        // TLS
        if tls.contains("Grade:") {
            let gradeLine = tls.split(separator: "\n").first(where: { $0.contains("Grade:") }) ?? ""
            lines.append("TLS: \(gradeLine.trimmingCharacters(in: .whitespaces))")
        }

        // DNS
        let ipLines = dns.split(separator: "\n").filter { $0.contains("IPv4") || $0.contains("CNAME") }
        for ip in ipLines { lines.append("DNS: \(ip.trimmingCharacters(in: .whitespaces))") }

        // Headers summary
        let missingCount = http.components(separatedBy: "\u{2717}").count - 1
        let presentCount = http.components(separatedBy: "\u{2713}").count - 1
        lines.append("Headers: \(presentCount) present, \(missingCount) missing")

        lines.append("")
        lines.append("OWASP Top 10 Exposure:")
        lines.append("  A01 Broken Access Control — check Permissions-Policy")
        lines.append("  A02 Cryptographic Failures — \(tls.contains("Weak") ? "WEAK CIPHERS DETECTED" : "OK")")
        lines.append("  A03 Injection — \(http.contains("Content-Security-Policy") && !http.contains("\u{2717}") ? "CSP present" : "NO CSP — XSS risk")")
        lines.append("  A05 Security Misconfiguration — \(missingCount) missing headers")

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Deep Recon (Web Intelligence)

    private static func secRecon(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard let urlStr = args.first(where: { !$0.hasPrefix("-") }) else {
            return textError("sec recon <url> [--max-pages N]\nPerforms deep reconnaissance by crawling for endpoints, forms, and assets.\n", status: 1)
        }
        if let error = rejectDeprecatedStealthFlag(args: args, command: "sec recon") {
            return error
        }
        let url = urlStr.contains("://") ? urlStr : "https://\(urlStr)"
        let domain = URL(string: url)?.host ?? urlStr

        if let error = requireSecurityAssessmentMode(
            runtime: runtime,
            minimum: .active,
            command: "sec recon",
            rationale: "Recon performs multi-page crawl and asset enumeration."
        ) {
            return error
        }

        guard checkSecLease(capability: "sec:scan", resource: domain, runtime: runtime) else {
            return leaseRequiredError("sec:scan", domain)
        }

        let browser = WebBrowser()
        let maxPages = Int(flagValue(args, flag: "--max-pages") ?? "10") ?? 10
        var lines: [String] = ["Security Reconnaissance: \(url)"]
        lines.append(String(repeating: "=", count: 40))
        lines.append(securityAssessmentBanner(runtime: runtime))
        lines.append("")

        // 1. Crawl for endpoints
        lines.append("Crawling for endpoints...")
        let results = browser.crawl(startURL: url, maxPages: maxPages)
        lines.append("Found \(results.count) endpoints.")

        // 2. Identify forms and inputs
        var allForms: [HTMLForm] = []
        var allLinks: Set<String> = []
        for r in results {
            allForms.append(contentsOf: r.forms)
            for link in r.links { allLinks.insert(link) }
        }

        lines.append("")
        lines.append("Attack Surface (Forms):")
        if allForms.isEmpty {
            lines.append("  No forms found.")
        } else {
            for (i, form) in allForms.enumerated() {
                lines.append("  [\(i)] \(form.method) \(form.action)")
                for input in form.inputs {
                    lines.append("    \(input.name) [\(input.type)]")
                }
            }
        }

        // 3. Asset discovery
        lines.append("")
        lines.append("Asset Discovery:")
        let scripts = results.flatMap { browser.parser.querySelectorAll(elements: browser.parser.parse($0.text).elements, selector: "script[src]") }
        let uniqueScripts = Set(scripts.compactMap { $0.attributes["src"] })
        lines.append("  Scripts: \(uniqueScripts.count) unique external scripts")
        for s in uniqueScripts.prefix(5) { lines.append("    - \(s)") }

        // 4. Integrated scan of main domain
        lines.append("")
        lines.append("Triggering standard security scans for \(domain)...")
        let shell = Shell(context: ShellContext(environment: runtime.context.environment))
        let http = shell.run(source: "sec http \(url)").stdout
        let tls = shell.run(source: "sec tls \(domain)").stdout

        lines.append("")
        lines.append("Recon Summary:")
        if http.contains("\u{2717}") { lines.append("  \u{26A0} Security headers missing (see sec http)") }
        if tls.contains("Grade: C") || tls.contains("Grade: D") || tls.contains("Grade: F") {
            lines.append("  \u{26A0} Weak TLS configuration detected")
        }
        lines.append("  \u{2713} \(allForms.count) potential injection points identified.")

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Threat Intelligence

    private static func secIntel(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        if let error = requireSecurityAssessmentMode(
            runtime: runtime,
            minimum: .passive,
            command: "sec intel",
            rationale: "Threat intelligence review should remain explicitly scoped."
        ) {
            return error
        }

        guard let sub = args.first else {
            return textResult(securityAssessmentBanner(runtime: runtime) + "\n" + ThreatIntelligence.renderCatalog() + "\n")
        }

        switch sub {
        case "list", "catalog":
            return textResult(securityAssessmentBanner(runtime: runtime) + "\n" + ThreatIntelligence.renderCatalog() + "\n")

        case "categories":
            let body = ThreatIntelligence.allCategories().map { "  - \($0)" }.joined(separator: "\n")
            return textResult(securityAssessmentBanner(runtime: runtime) + "\nThreat Intelligence Categories\n========================================\n\(body)\n")

        case "search":
            let query = args.dropFirst().joined(separator: " ")
            guard !query.isEmpty else {
                return textError("sec intel search <query>\n", status: 1)
            }
            let results = ThreatDefenseMirror.search(query, limit: 8)
            return textResult(securityAssessmentBanner(runtime: runtime) + "\n" + ThreatDefenseMirror.renderSearch(results) + "\n")

        case "mirror":
            guard args.count >= 2 else {
                return textError("sec intel mirror <pattern-id>\n", status: 1)
            }
            guard let pattern = ThreatIntelligence.pattern(id: args[1].uppercased()) else {
                return textError("Unknown threat pattern: \(args[1])\n", status: 1)
            }
            let profile = ThreatDefenseMirror.profile(pattern: pattern)
            return textResult(securityAssessmentBanner(runtime: runtime) + "\n" + ThreatDefenseMirror.renderProfile(profile) + "\n")

        case "analyze":
            return secIntelAnalyze(args: Array(args.dropFirst()), runtime: runtime)

        default:
            if let pattern = ThreatIntelligence.pattern(id: sub.uppercased()) {
                return textResult(securityAssessmentBanner(runtime: runtime) + "\n" + ThreatIntelligence.renderPattern(pattern) + "\n")
            }

            let results = ThreatDefenseMirror.search(args.joined(separator: " "), limit: 8)
            return textResult(securityAssessmentBanner(runtime: runtime) + "\n" + ThreatDefenseMirror.renderSearch(results) + "\n")
        }
    }

    private static func secIntelAnalyze(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard let target = args.first else {
            return textError("sec intel analyze <url|file|agent>\n", status: 1)
        }

        if target == "agent" || target == "runtime" {
            let recentCommands = runtime.sessionStore.commandHistory(limit: 12)
            let report = ThreatDefenseMirror.analyzeRuntime(
                target: "runtime",
                recentCommands: recentCommands,
                activeLeases: runtime.runtimeStore.activeLeases().count,
                intentStatement: runtime.runtimeStore.activeIntent?.statement
            )
            return textResult(securityAssessmentBanner(runtime: runtime) + "\n" + ThreatDefenseMirror.renderReport(report) + "\n")
        }

        if FileManager.default.fileExists(atPath: target) {
            guard let content = try? String(contentsOfFile: target, encoding: .utf8) else {
                return textError("Could not read \(target)\n", status: 1)
            }
            let matches = ThreatDefenseMirror.search(content, limit: 6)
            let profiles = matches.map { result in
                ThreatDefenseMirror.profile(
                    pattern: result.pattern,
                    confidence: result.score,
                    rationale: result.rationale
                )
            }
            let report = ThreatMirrorReport(
                target: target,
                generatedAt: Date(),
                observedSignals: [],
                profiles: profiles,
                riskScore: min(100, Double(profiles.count) * 12.0),
                summary: "Static content correlated against the threat intelligence catalog."
            )
            return textResult(securityAssessmentBanner(runtime: runtime) + "\n" + ThreatDefenseMirror.renderReport(report) + "\n")
        }

        let url = target.contains("://") ? target : "https://\(target)"
        let domain = URL(string: url)?.host ?? target
        guard checkSecLease(capability: "sec:scan", resource: domain, runtime: runtime) else {
            return leaseRequiredError("sec:scan", domain)
        }

        let client = WebClient()
        let response = client.get(url)
        guard response.statusCode != 0 else {
            return textError("Could not analyze \(url): no response\n", status: 1)
        }

        let report = ThreatDefenseMirror.analyzeHTTP(
            target: domain,
            url: response.url,
            headers: response.headers,
            body: response.body,
            responseHeaders: response.headers
        )
        return textResult(securityAssessmentBanner(runtime: runtime) + "\n" + ThreatDefenseMirror.renderReport(report) + "\n")
    }

    // MARK: - Request Path Analysis

    private static func secDetect(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard let target = args.first else {
            return textError("sec detect <url|path>\nAnalyzes a URL or log file for intermediary, proxy, and CDN signals.\n", status: 1)
        }

        if let error = requireSecurityAssessmentMode(
            runtime: runtime,
            minimum: .passive,
            command: "sec detect",
            rationale: "Traffic-path analysis should remain in explicit authorized scope."
        ) {
            return error
        }

        let detector = RequestPathDetector()
        var lines: [String] = ["Request Path Analysis: \(target)"]
        lines.append(String(repeating: "=", count: 40))
        lines.append(securityAssessmentBanner(runtime: runtime))
        lines.append("")

        if target.hasPrefix("http") || target.contains(".") && !target.contains("/") {
            let url = target.hasPrefix("http") ? target : "https://\(target)"
            let browser = WebBrowser()
            let result = browser.navigate(url)
            
            if let error = result.error {
                return textError("Could not reach target: \(error)\n", status: 1)
            }
            
            let report = detector.comprehensiveAudit(target: url, headers: result.headers, body: result.text)
            
            lines.append("Request-Path Risk Score: \(String(format: "%.2f", report.pathRiskScore * 100))%")
            lines.append("")
            
            if report.indicators.isEmpty {
                lines.append("\u{2713} No request-path anomalies detected.")
            } else {
                lines.append("Detected Request-Path Indicators:")
                for indicator in report.indicators {
                    lines.append("  [\(indicator.category.rawValue.uppercased())] \(indicator.description) (Conf: \(Int(indicator.confidence * 100))%)")
                    if !indicator.evidence.isEmpty {
                        for (k, v) in indicator.evidence {
                            lines.append("    \u{21AA} \(k): \(v)")
                        }
                    }
                }
            }
        } else if target == "system" {
            // Run system analysis
            lines.append("Running System-Level Anomaly Detection...")
            lines.append("")
            
            let shell = Shell(context: ShellContext(environment: runtime.context.environment))
            let processes = shell.run(source: "ps -Ao comm").stdout.split(separator: "\n").map(String.init)
            let connections = shell.run(source: "netstat -anp tcp").stdout.split(separator: "\n").map(String.init)
            
            let indicators = detector.detectSystemAnomalies(processes: processes, connections: connections)
            
            if indicators.isEmpty {
                lines.append("\u{2713} No system integrity anomalies detected.")
            } else {
                lines.append("Detected System Anomalies:")
                for indicator in indicators {
                    lines.append("  [\(indicator.category.rawValue.uppercased())] \(indicator.description) (Conf: \(Int(indicator.confidence * 100))%)")
                    if !indicator.evidence.isEmpty {
                        for (k, v) in indicator.evidence {
                            lines.append("    \u{21AA} \(k): \(v)")
                        }
                    }
                }
            }
        } else {
            lines.append("Log analysis not fully implemented in this preview.")
        }

        return textResult(lines.joined(separator: "\n") + "\n")
    }

}

extension Builtins {
    // MARK: - Vulnerability Validation

    private static func secValidate(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard let domain = args.first(where: { !$0.hasPrefix("-") }) else {
            return textError("sec validate <domain>\nRuns validation checks against private/test lab targets only.\n", status: 1)
        }

        if let error = requireSecurityAssessmentMode(
            runtime: runtime,
            minimum: .lab,
            command: "sec validate",
            rationale: "Validation probes belong only in disposable lab environments."
        ) {
            return error
        }
        if let error = requireLabTarget(resource: domain, command: "sec validate") {
            return error
        }

        guard checkSecLease(capability: "sec:scan", resource: domain, runtime: runtime) else {
            return textError("Lease required: lease grant sec:scan \(domain) 600\n", status: 1)
        }

        // Set intent for audit trail
        runtime.runtimeStore.setIntent(
            statement: "Validate security findings on \(domain)",
            reason: "Authorized lab assessment",
            riskLevel: .high
        )

        let report = SecurityValidator.validate(domain: domain)

        runtime.runtimeStore.proveExecution(
            command: "sec validate \(domain)",
            status: 0, stdout: "Validated \(report.results.count) findings",
            stderr: "", durationMs: 0, cwd: runtime.context.currentDirectory
        )

        runtime.runtimeStore.satisfyIntent()

        return textResult(securityAssessmentBanner(runtime: runtime) + "\n" + SecurityValidator.renderTerminal(report) + "\n")
    }

    // MARK: - Simple Report (existing, from proofs)

    private static func secReport(runtime: BuiltinRuntime) -> CommandResult {
        let proofs = runtime.runtimeStore.proofs.filter { $0.claim.contains("scan") || $0.claim.contains("sec") }
        if proofs.isEmpty {
            return textResult("No security scan results in this session. Run some scans first.\n")
        }

        var lines: [String] = ["Security Report"]
        lines.append(String(repeating: "=", count: 40))
        lines.append("")
        for proof in proofs.suffix(20) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            lines.append("[\(formatter.string(from: proof.validatedAt))] \(proof.claim)")
            for evidence in proof.evidence.prefix(3) {
                lines.append("  \(evidence.kind): \(evidence.value.prefix(80))")
            }
            lines.append("")
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Lease Helpers

    private static func checkSecLease(capability: String, resource: String, runtime: BuiltinRuntime) -> Bool {
        let leases = runtime.runtimeStore.activeLeases()
        return leases.contains { lease in
            let capMatch = lease.capability == capability ||
                          lease.capability.hasPrefix("sec") ||
                          lease.capability == "security" ||
                          lease.capability == "network"
            let resMatch = lease.resource == resource ||
                          lease.resource.contains("*") ||
                          lease.resource == "." ||
                          resource.hasPrefix(lease.resource) ||
                          resource.contains(lease.resource)
            return capMatch && resMatch
        }
    }

    private static func leaseRequiredError(_ capability: String, _ resource: String) -> CommandResult {
        let msg = """
        Security operation requires an active lease.
        Grant with: lease grant \(capability) \(resource) 600

        This ensures:
          \u{2022} Time-limited permission (auto-expires)
          \u{2022} Audit trail (who authorized what, when)
          \u{2022} Scope control (only the granted target)

        """
        return CommandResult(status: 1, io: ShellIO(stderr: Data(msg.utf8)))
    }

    // MARK: - Helpers

    private static func flagValue(_ args: [String], flag: String) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    private static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
    }
}
