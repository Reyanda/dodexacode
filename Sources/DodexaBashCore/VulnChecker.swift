import Foundation

// MARK: - Vulnerability Checker: Port Audit, Service Checks, Configuration Assessment
// Combines scan results with known-vulnerability heuristics.
// For authorized internal security assessment only.

// MARK: - Result Types

public enum VulnSeverity: String, Codable, Sendable {
    case critical
    case high
    case medium
    case low
    case info
}

public struct Vulnerability: Codable, Sendable {
    public let id: String           // e.g. "OPEN-TELNET", "WEAK-SSH"
    public let title: String
    public let severity: VulnSeverity
    public let host: String
    public let port: UInt16?
    public let service: String?
    public let description: String
    public let remediation: String
}

public struct VulnReport: Codable, Sendable {
    public let target: String
    public let vulnerabilities: [Vulnerability]
    public let totalChecks: Int
    public let durationMs: Int

    public var critical: [Vulnerability] { vulnerabilities.filter { $0.severity == .critical } }
    public var high: [Vulnerability] { vulnerabilities.filter { $0.severity == .high } }
    public var medium: [Vulnerability] { vulnerabilities.filter { $0.severity == .medium } }
    public var low: [Vulnerability] { vulnerabilities.filter { $0.severity == .low } }

    public var summary: String {
        let c = critical.count, h = high.count, m = medium.count, l = low.count
        return "\(vulnerabilities.count) findings: \(c) critical, \(h) high, \(m) medium, \(l) low"
    }
}

// MARK: - Vulnerability Checker

public final class VulnChecker: @unchecked Sendable {

    public init() {}

    // MARK: - Full Assessment

    public func assess(host: String, scanResult: ScanResult? = nil) -> VulnReport {
        let start = DispatchTime.now()
        var vulns: [Vulnerability] = []
        var checks = 0

        // Use existing scan or perform one
        let scan: ScanResult
        if let existing = scanResult {
            scan = existing
        } else {
            let scanner = TCPScanner(timeoutMs: 2000, grabBanner: true)
            scan = scanner.scan(host: host, ports: WellKnownPorts.top100)
        }

        // 1. Dangerous port audit
        checks += scan.openPorts.count
        vulns.append(contentsOf: auditDangerousPorts(scan.openPorts, host: host))

        // 2. Service version checks
        checks += scan.openPorts.count
        vulns.append(contentsOf: checkServiceVersions(scan.openPorts, host: host))

        // 3. Configuration checks on open services
        for port in scan.openPorts {
            checks += 1
            vulns.append(contentsOf: checkServiceConfig(host: host, port: port))
        }

        // 4. HTTP security checks if web ports are open
        let webPorts = scan.openPorts.filter { [80, 443, 8080, 8443, 3000, 8000].contains($0.port) }
        for port in webPorts {
            checks += 8 // header checks
            vulns.append(contentsOf: checkHTTPSecurity(host: host, port: port.port))
        }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)

        return VulnReport(
            target: host,
            vulnerabilities: vulns.sorted { severityRank($0.severity) < severityRank($1.severity) },
            totalChecks: checks,
            durationMs: elapsed
        )
    }

    // MARK: - Dangerous Port Audit

    private func auditDangerousPorts(_ ports: [PortResult], host: String) -> [Vulnerability] {
        var vulns: [Vulnerability] = []

        let dangerousPorts: [(UInt16, String, VulnSeverity, String)] = [
            (23, "Telnet", .critical, "Telnet transmits credentials in plaintext. Disable and use SSH."),
            (21, "FTP", .high, "FTP transmits credentials in plaintext. Use SFTP or SCP instead."),
            (513, "rlogin", .critical, "rlogin has no encryption. Disable immediately."),
            (514, "rsh", .critical, "Remote shell has no authentication or encryption."),
            (69, "TFTP", .high, "TFTP has no authentication. Restrict to management networks."),
            (161, "SNMP", .medium, "SNMP v1/v2 uses community strings. Upgrade to v3."),
            (445, "SMB", .medium, "SMB exposed. Ensure latest patches and restrict access."),
            (3389, "RDP", .medium, "RDP exposed. Use VPN/NLA and restrict access."),
            (5900, "VNC", .high, "VNC often uses weak auth. Use SSH tunnel instead."),
            (6379, "Redis", .critical, "Redis may be unauthenticated. Set requirepass."),
            (27017, "MongoDB", .critical, "MongoDB may be unauthenticated. Enable auth."),
            (9200, "Elasticsearch", .high, "Elasticsearch may be unauthenticated. Enable X-Pack security."),
            (2375, "Docker", .critical, "Docker daemon exposed without TLS. Immediate risk of container escape."),
            (11211, "Memcached", .high, "Memcached has no built-in auth. Restrict to internal IPs."),
            (5984, "CouchDB", .medium, "CouchDB admin interface may be exposed."),
        ]

        for port in ports {
            for (dangerous, name, severity, remediation) in dangerousPorts {
                if port.port == dangerous {
                    vulns.append(Vulnerability(
                        id: "OPEN-\(name.uppercased())",
                        title: "\(name) service exposed on port \(port.port)",
                        severity: severity,
                        host: host,
                        port: port.port,
                        service: port.service ?? name.lowercased(),
                        description: "\(name) is running and accessible from the network.",
                        remediation: remediation
                    ))
                }
            }
        }

        return vulns
    }

    // MARK: - Service Version Checks

    private func checkServiceVersions(_ ports: [PortResult], host: String) -> [Vulnerability] {
        var vulns: [Vulnerability] = []

        for port in ports {
            guard let banner = port.banner else { continue }
            let lower = banner.lowercased()

            // SSH version checks
            if lower.hasPrefix("ssh-") {
                if lower.contains("ssh-1") {
                    vulns.append(Vulnerability(
                        id: "WEAK-SSH-V1",
                        title: "SSH Protocol 1 enabled",
                        severity: .critical,
                        host: host, port: port.port, service: "ssh",
                        description: "SSH v1 has known cryptographic weaknesses.",
                        remediation: "Disable SSH Protocol 1 in sshd_config."
                    ))
                }
                if lower.contains("openssh_6") || lower.contains("openssh_5") || lower.contains("openssh_4") {
                    vulns.append(Vulnerability(
                        id: "OLD-SSH",
                        title: "Outdated OpenSSH version detected",
                        severity: .high,
                        host: host, port: port.port, service: "ssh",
                        description: "Banner: \(banner.prefix(60)). Old versions have known CVEs.",
                        remediation: "Upgrade to latest OpenSSH version."
                    ))
                }
            }

            // Apache/nginx version disclosure
            if lower.contains("apache/") || lower.contains("nginx/") {
                let version = banner.prefix(60)
                vulns.append(Vulnerability(
                    id: "SERVER-DISCLOSURE",
                    title: "Web server version disclosed",
                    severity: .low,
                    host: host, port: port.port, service: port.service,
                    description: "Server header: \(version)",
                    remediation: "Configure server to hide version info (ServerTokens Prod / server_tokens off)."
                ))
            }

            // MySQL/MariaDB version check
            if lower.contains("mysql") || lower.contains("mariadb") {
                if lower.contains("5.5") || lower.contains("5.6") || lower.contains("5.1") {
                    vulns.append(Vulnerability(
                        id: "OLD-MYSQL",
                        title: "Outdated MySQL/MariaDB version",
                        severity: .high,
                        host: host, port: port.port, service: "mysql",
                        description: "Banner: \(banner.prefix(60)). EOL versions have unpatched CVEs.",
                        remediation: "Upgrade to MySQL 8.x or MariaDB 10.6+."
                    ))
                }
            }
        }

        return vulns
    }

    // MARK: - Service Configuration Checks

    private func checkServiceConfig(host: String, port: PortResult) -> [Vulnerability] {
        var vulns: [Vulnerability] = []

        // Check for anonymous FTP
        if port.port == 21 && (port.service == "ftp" || port.banner?.lowercased().contains("ftp") == true) {
            if testAnonymousFTP(host: host) {
                vulns.append(Vulnerability(
                    id: "ANON-FTP",
                    title: "Anonymous FTP login allowed",
                    severity: .high,
                    host: host, port: 21, service: "ftp",
                    description: "FTP server accepts anonymous logins.",
                    remediation: "Disable anonymous FTP access."
                ))
            }
        }

        // Check for unauthenticated Redis
        if port.port == 6379 {
            if testUnauthRedis(host: host) {
                vulns.append(Vulnerability(
                    id: "UNAUTH-REDIS",
                    title: "Redis accessible without authentication",
                    severity: .critical,
                    host: host, port: 6379, service: "redis",
                    description: "Redis responds to commands without requiring authentication.",
                    remediation: "Set requirepass in redis.conf and bind to 127.0.0.1."
                ))
            }
        }

        return vulns
    }

    // MARK: - HTTP Security Headers

    private func checkHTTPSecurity(host: String, port: UInt16) -> [Vulnerability] {
        var vulns: [Vulnerability] = []
        let scheme = port == 443 || port == 8443 ? "https" : "http"
        let fuzzer = HTTPFuzzer()
        let headers = fuzzer.checkSecurityHeaders(baseURL: "\(scheme)://\(host):\(port)")

        let headerImportance: [(String, VulnSeverity, String)] = [
            ("Content-Security-Policy", .medium, "CSP prevents XSS and injection attacks."),
            ("Strict-Transport-Security", .medium, "HSTS ensures HTTPS-only connections."),
            ("X-Frame-Options", .low, "Prevents clickjacking attacks."),
            ("X-Content-Type-Options", .low, "Prevents MIME-type confusion attacks."),
            ("X-XSS-Protection", .low, "Browser-level XSS filter."),
            ("Referrer-Policy", .low, "Controls referrer information leakage."),
        ]

        for (header, severity, description) in headerImportance {
            if headers[header] != true {
                vulns.append(Vulnerability(
                    id: "MISSING-\(header.uppercased().replacingOccurrences(of: "-", with: "_"))",
                    title: "Missing \(header) header",
                    severity: severity,
                    host: host, port: port, service: "http",
                    description: description,
                    remediation: "Add \(header) header to server configuration."
                ))
            }
        }

        return vulns
    }

    // MARK: - Protocol Tests

    private func testAnonymousFTP(host: String) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(21).bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return false }

        // Read banner
        var buf = [UInt8](repeating: 0, count: 1024)
        _ = recv(sock, &buf, buf.count, 0)

        // Send USER anonymous
        let user = "USER anonymous\r\n"
        _ = user.withCString { send(sock, $0, strlen($0), 0) }
        _ = recv(sock, &buf, buf.count, 0)

        // Send PASS
        let pass = "PASS test@test.com\r\n"
        _ = pass.withCString { send(sock, $0, strlen($0), 0) }
        let n = recv(sock, &buf, buf.count, 0)
        guard n > 0 else { return false }

        let response = String(cString: buf)
        return response.hasPrefix("230") // 230 = login successful
    }

    private func testUnauthRedis(host: String) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(6379).bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return false }

        // Send PING
        let ping = "*1\r\n$4\r\nPING\r\n"
        _ = ping.withCString { send(sock, $0, strlen($0), 0) }

        var buf = [UInt8](repeating: 0, count: 256)
        let n = recv(sock, &buf, buf.count, 0)
        guard n > 0 else { return false }

        let response = String(cString: buf)
        return response.contains("+PONG") // Unauthenticated response
    }

    // MARK: - Helpers

    private func severityRank(_ s: VulnSeverity) -> Int {
        switch s {
        case .critical: return 0
        case .high: return 1
        case .medium: return 2
        case .low: return 3
        case .info: return 4
        }
    }
}
