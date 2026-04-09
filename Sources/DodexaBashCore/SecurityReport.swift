import Foundation

// MARK: - Security Report Generator

public struct SecurityFinding: Codable, Sendable {
    public let id: String
    public let category: String        // tls, headers, ports, dns, vuln, request-path
    public let severity: Severity
    public let title: String
    public let description: String
    public let impact: String
    public let fix: String
    public let owaspCategory: String?  // A01-A10
    public let cvssEstimate: Double    // 0.0-10.0

    public enum Severity: String, Codable, Sendable {
        case critical, high, medium, low, info
    }
}

public struct SecurityReport: Codable, Sendable {
    public let domain: String
    public let scannedAt: Date
    public let grade: String           // A+ through F
    public let summary: String
    public let findings: [SecurityFinding]
    public let attackSurface: AttackSurface
    public let fixes: [FixRecommendation]

    public var criticalCount: Int { findings.filter { $0.severity == .critical }.count }
    public var highCount: Int { findings.filter { $0.severity == .high }.count }
    public var mediumCount: Int { findings.filter { $0.severity == .medium }.count }
    public var lowCount: Int { findings.filter { $0.severity == .low }.count }
}

public struct AttackSurface: Codable, Sendable {
    public let openPorts: [PortEntry]
    public let technologies: [String]
    public let entryPoints: [String]
    public let tlsVersion: String?
    public let httpsMandatory: Bool
    public let cdnProvider: String?
}

public struct PortEntry: Codable, Sendable {
    public let port: Int
    public let service: String
    public let risk: String
}

public struct FixRecommendation: Codable, Sendable {
    public let finding: String
    public let platform: String        // cloudfront, nginx, apache, caddy, generic
    public let config: String
    public let priority: Int           // 1=urgent, 5=nice-to-have
}

// MARK: - Report Builder

public enum SecurityReportBuilder {

    public static func buildReport(
        domain: String,
        tlsOutput: String,
        httpOutput: String,
        scanOutput: String,
        dnsOutput: String,
        vulnOutput: String
    ) -> SecurityReport {
        var findings: [SecurityFinding] = []
        var technologies: [String] = []
        var ports: [PortEntry] = []

        // Parse TLS findings
        if tlsOutput.contains("HSTS") && tlsOutput.contains("disabled") {
            findings.append(SecurityFinding(
                id: "TLS-001", category: "tls", severity: .medium,
                title: "HSTS Not Enabled",
                description: "HTTP Strict Transport Security header is not set. Browsers can be tricked into using HTTP.",
                impact: "Man-in-the-middle attacks possible on first visit. SSL stripping attacks.",
                fix: "Add Strict-Transport-Security: max-age=31536000; includeSubDomains; preload",
                owaspCategory: "A02", cvssEstimate: 5.3
            ))
        }
        if tlsOutput.contains("Weak cipher") {
            findings.append(SecurityFinding(
                id: "TLS-002", category: "tls", severity: .medium,
                title: "Weak Cipher Suite Detected",
                description: "Server accepts weak or export-grade cipher suites.",
                impact: "Encrypted traffic may be decryptable by attackers with sufficient resources.",
                fix: "Disable EXPORT, RC4, DES, and 3DES cipher suites. Use only TLS 1.2+ with AEAD ciphers.",
                owaspCategory: "A02", cvssEstimate: 4.8
            ))
        }

        // Parse HTTP header findings
        let missingHeaders: [(String, String, String, String, String, Double)] = [
            ("Content-Security-Policy", "HDR-001", "A03",
             "Prevents XSS and code injection by restricting resource origins.",
             "Cross-site scripting (XSS) attacks, data exfiltration via injected scripts.", 6.1),
            ("Strict-Transport-Security", "HDR-002", "A02",
             "Forces HTTPS connections, prevents protocol downgrade.",
             "Man-in-the-middle attacks, session hijacking via HTTP.", 5.3),
            ("X-Frame-Options", "HDR-003", "A05",
             "Prevents clickjacking by controlling iframe embedding.",
             "UI redress attacks, credential theft via invisible frames.", 4.3),
            ("X-Content-Type-Options", "HDR-004", "A05",
             "Prevents MIME-type sniffing attacks.",
             "Drive-by download attacks via MIME confusion.", 3.5),
            ("X-XSS-Protection", "HDR-005", "A03",
             "Enables browser's built-in XSS filter.",
             "Reflected XSS attacks in older browsers.", 3.1),
            ("Referrer-Policy", "HDR-006", "A01",
             "Controls what referrer info is sent with requests.",
             "Sensitive URL parameters leaked to third parties.", 3.0),
            ("Permissions-Policy", "HDR-007", "A05",
             "Controls browser feature access (camera, mic, geolocation).",
             "Unauthorized feature access by embedded content.", 2.5),
        ]

        for (header, id, owasp, description, impact, cvss) in missingHeaders {
            if httpOutput.contains(header) && httpOutput.contains("\u{2717}") {
                findings.append(SecurityFinding(
                    id: id, category: "headers", severity: cvss >= 5.0 ? .medium : .low,
                    title: "Missing \(header) Header",
                    description: description,
                    impact: impact,
                    fix: "Add \(header) header to server response configuration.",
                    owaspCategory: owasp, cvssEstimate: cvss
                ))
            }
        }

        // Parse port findings
        for line in scanOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("\topen\t") {
                let parts = trimmed.split(separator: "\t")
                if let portNum = Int(parts.first ?? "") {
                    let service = parts.count >= 3 ? String(parts[2]) : "unknown"
                    let risk: String
                    switch portNum {
                    case 80, 443: risk = "expected"
                    case 22: risk = "low — SSH access"
                    case 53: risk = "low — DNS"
                    case 8080, 8443: risk = "medium — non-standard web port"
                    case 3306, 5432, 27017: risk = "high — database exposed"
                    case 6379: risk = "critical — Redis exposed"
                    default: risk = "investigate"
                    }
                    ports.append(PortEntry(port: portNum, service: service, risk: risk))

                    if portNum == 8080 {
                        findings.append(SecurityFinding(
                            id: "PORT-001", category: "ports", severity: .medium,
                            title: "Non-Standard HTTP Port Open (8080)",
                            description: "Port 8080 is open, typically used for proxy or dev servers.",
                            impact: "May expose internal services, debug endpoints, or admin panels.",
                            fix: "Close port 8080 in security group/firewall if not needed. If needed, restrict to known IPs.",
                            owaspCategory: "A05", cvssEstimate: 4.0
                        ))
                    }
                }
            }
        }

        // Detect technologies from DNS/headers
        if dnsOutput.contains("18.239") || dnsOutput.contains("cloudfront") {
            technologies.append("AWS CloudFront (CDN)")
        }
        if dnsOutput.contains("amazonaws") {
            technologies.append("AWS")
        }

        // Grade calculation
        let maxCVSS = findings.map(\.cvssEstimate).max() ?? 0
        let grade: String
        if findings.isEmpty { grade = "A+" }
        else if maxCVSS >= 9.0 { grade = "F" }
        else if maxCVSS >= 7.0 { grade = "D" }
        else if maxCVSS >= 5.0 { grade = "C" }
        else if maxCVSS >= 3.0 { grade = "B" }
        else { grade = "A" }

        // Generate fixes
        let fixes = generateFixes(findings: findings, technologies: technologies)

        // Attack surface
        let surface = AttackSurface(
            openPorts: ports,
            technologies: technologies,
            entryPoints: ports.map { ":\($0.port) (\($0.service))" },
            tlsVersion: tlsOutput.contains("TLS 1.3") ? "TLS 1.3" : "TLS 1.2",
            httpsMandatory: tlsOutput.contains("redirect-to-https") || httpOutput.contains("301"),
            cdnProvider: technologies.contains("AWS CloudFront (CDN)") ? "CloudFront" : nil
        )

        // Summary
        let summary = "\(domain): Grade \(grade). \(findings.count) findings (\(findings.filter{$0.severity == .critical || $0.severity == .high}.count) critical/high, \(findings.filter{$0.severity == .medium}.count) medium, \(findings.filter{$0.severity == .low}.count) low)."

        return SecurityReport(
            domain: domain,
            scannedAt: Date(),
            grade: grade,
            summary: summary,
            findings: findings.sorted { $0.cvssEstimate > $1.cvssEstimate },
            attackSurface: surface,
            fixes: fixes
        )
    }

    // MARK: - Fix Generation

    private static func generateFixes(findings: [SecurityFinding], technologies: [String]) -> [FixRecommendation] {
        var fixes: [FixRecommendation] = []
        let isCloudFront = technologies.contains(where: { $0.contains("CloudFront") })

        let headerFindings = findings.filter { $0.category == "headers" }
        if !headerFindings.isEmpty {
            if isCloudFront {
                fixes.append(FixRecommendation(
                    finding: "Missing security headers",
                    platform: "cloudfront",
                    config: """
                    # AWS CLI — Attach managed security headers policy
                    DIST_ID="YOUR_DISTRIBUTION_ID"
                    POLICY_ID="67f7725c-6f97-4210-82d7-5512b31e9d03"  # Managed-SecurityHeadersPolicy

                    ETAG=$(aws cloudfront get-distribution-config --id $DIST_ID --query "ETag" --output text)
                    aws cloudfront get-distribution-config --id $DIST_ID --query "DistributionConfig" > /tmp/cf.json

                    python3 -c "
                    import json
                    with open('/tmp/cf.json') as f: c = json.load(f)
                    c['DefaultCacheBehavior']['ResponseHeadersPolicyId'] = '$POLICY_ID'
                    with open('/tmp/cf.json', 'w') as f: json.dump(c, f)
                    "

                    aws cloudfront update-distribution --id $DIST_ID --if-match "$ETAG" --distribution-config file:///tmp/cf.json
                    """,
                    priority: 1
                ))
            }

            fixes.append(FixRecommendation(
                finding: "Missing security headers",
                platform: "nginx",
                config: """
                # Add to server block in nginx.conf
                add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
                add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:;" always;
                add_header X-Frame-Options "DENY" always;
                add_header X-Content-Type-Options "nosniff" always;
                add_header X-XSS-Protection "1; mode=block" always;
                add_header Referrer-Policy "strict-origin-when-cross-origin" always;
                add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
                """,
                priority: 1
            ))

            fixes.append(FixRecommendation(
                finding: "Missing security headers",
                platform: "apache",
                config: """
                # Add to .htaccess or httpd.conf
                Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
                Header always set Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline';"
                Header always set X-Frame-Options "DENY"
                Header always set X-Content-Type-Options "nosniff"
                Header always set X-XSS-Protection "1; mode=block"
                Header always set Referrer-Policy "strict-origin-when-cross-origin"
                Header always set Permissions-Policy "camera=(), microphone=(), geolocation=()"
                """,
                priority: 1
            ))
        }

        if findings.contains(where: { $0.id == "TLS-002" }) {
            fixes.append(FixRecommendation(
                finding: "Weak cipher suites",
                platform: "nginx",
                config: """
                ssl_protocols TLSv1.2 TLSv1.3;
                ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
                ssl_prefer_server_ciphers on;
                """,
                priority: 2
            ))
        }

        if findings.contains(where: { $0.id == "EXP-001" }) {
            fixes.append(FixRecommendation(
                finding: "Source code / Config exposure",
                platform: "nginx",
                config: """
                # Block access to sensitive files
                location ~ /\\.(git|env|docker|config) {
                    deny all;
                    return 404;
                }
                location ~ ^/(wp-config.php|web.config|phpinfo.php) {
                    deny all;
                }
                """,
                priority: 1
            ))

            if isCloudFront {
                fixes.append(FixRecommendation(
                    finding: "Source code exposure (CloudFront)",
                    platform: "cloudfront",
                    config: """
                    # AWS WAF — Create rule to block sensitive paths
                    # Rule: String match on Path starting with /., /.git, /.env
                    # Action: Block (403)
                    """,
                    priority: 1
                ))
            }
        }

        if findings.contains(where: { $0.id == "DOS-001" }) {
            fixes.append(FixRecommendation(
                finding: "Lack of rate limiting",
                platform: "nginx",
                config: """
                # Add to http block
                limit_req_zone $binary_remote_addr zone=mylimit:10m rate=10r/s;

                # Add to server/location block
                limit_req zone=mylimit burst=20 nodelay;
                """,
                priority: 3
            ))
        }

        return fixes.sorted { $0.priority < $1.priority }
    }

    // MARK: - Report Rendering

    public static func renderMarkdown(_ report: SecurityReport) -> String {
        let fmt = ISO8601DateFormatter()
        var md = """
        # Security Assessment Report

        **Domain:** \(report.domain)
        **Date:** \(fmt.string(from: report.scannedAt))
        **Overall Grade:** \(report.grade)

        ## Executive Summary

        \(report.summary)

        | Severity | Count |
        | --- | --- |
        | Critical | \(report.criticalCount) |
        | High | \(report.highCount) |
        | Medium | \(report.mediumCount) |
        | Low | \(report.lowCount) |

        ## Attack Surface

        **Technologies:** \(report.attackSurface.technologies.joined(separator: ", "))
        **CDN:** \(report.attackSurface.cdnProvider ?? "None detected")
        **HTTPS Mandatory:** \(report.attackSurface.httpsMandatory ? "Yes" : "No")
        **TLS Version:** \(report.attackSurface.tlsVersion ?? "Unknown")

        ### Open Ports

        | Port | Service | Risk |
        | --- | --- | --- |
        """

        for port in report.attackSurface.openPorts {
            md += "| \(port.port) | \(port.service) | \(port.risk) |\n"
        }

        md += "\n## Findings\n\n"

        for (i, finding) in report.findings.enumerated() {
            let icon: String
            switch finding.severity {
            case .critical: icon = "CRITICAL"
            case .high: icon = "HIGH"
            case .medium: icon = "MEDIUM"
            case .low: icon = "LOW"
            case .info: icon = "INFO"
            }
            md += """
            ### \(i + 1). [\(icon)] \(finding.title)

            - **ID:** \(finding.id)
            - **CVSS:** \(String(format: "%.1f", finding.cvssEstimate))
            - **OWASP:** \(finding.owaspCategory ?? "N/A")
            - **Impact:** \(finding.impact)
            - **Fix:** \(finding.fix)

            """
        }

        md += "\n## Remediation\n\n"

        for fix in report.fixes {
            md += """
            ### \(fix.finding) (\(fix.platform))

            Priority: \(fix.priority)

            ```
            \(fix.config)
            ```

            """
        }

        md += """

        ---
        *Generated by dodexabash security toolkit*
        *This report is for authorized security assessment purposes only.*
        """

        return md
    }

    public static func renderTerminal(_ report: SecurityReport) -> String {
        var lines: [String] = []
        lines.append("Security Report: \(report.domain)")
        lines.append("Grade: \(report.grade)")
        lines.append("Scanned: \(ISO8601DateFormatter().string(from: report.scannedAt))")
        lines.append("")
        lines.append(report.summary)
        lines.append("")

        for finding in report.findings {
            let sev = finding.severity.rawValue.uppercased()
            lines.append("[\(sev)] \(finding.title) (CVSS \(String(format: "%.1f", finding.cvssEstimate)))")
            lines.append("  \(finding.description)")
            lines.append("  Fix: \(finding.fix)")
            lines.append("")
        }

        if !report.fixes.isEmpty {
            lines.append("--- Fixes ---")
            for fix in report.fixes {
                lines.append("\(fix.finding) (\(fix.platform), priority \(fix.priority))")
            }
        }

        return lines.joined(separator: "\n")
    }
}
