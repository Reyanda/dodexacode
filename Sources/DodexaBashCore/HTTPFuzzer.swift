import Foundation

// MARK: - HTTP Fuzzer: HTTP Security Testing + Method/Header/Path Fuzzing
// Uses Foundation URLSession. For authorized internal testing only.

// MARK: - Result Types

public struct HTTPFuzzResult: Codable, Sendable {
    public let url: String
    public let tests: [HTTPTestResult]
    public let securityHeaders: [String: Bool]
    public let issues: [String]
    public let durationMs: Int
}

public struct HTTPTestResult: Codable, Sendable {
    public let test: String
    public let method: String
    public let path: String
    public let statusCode: Int
    public let responseSize: Int
    public let latencyMs: Int
    public let headers: [String: String]
    public let finding: String?   // non-nil if something notable was found
}

// MARK: - HTTP Fuzzer

public final class HTTPFuzzer: @unchecked Sendable {
    public init() {}

    // MARK: - Full Fuzz

    public func fuzz(baseURL: String) -> HTTPFuzzResult {
        let start = DispatchTime.now()
        var tests: [HTTPTestResult] = []
        var issues: [String] = []

        // 1. Method testing
        tests.append(contentsOf: testMethods(baseURL: baseURL))

        // 2. Path traversal
        tests.append(contentsOf: testPathTraversal(baseURL: baseURL))

        // 3. Security headers
        let headers = checkSecurityHeaders(baseURL: baseURL)

        // 4. Analyze findings
        for test in tests {
            if let finding = test.finding {
                issues.append(finding)
            }
        }
        for (header, present) in headers where !present {
            issues.append("Missing security header: \(header)")
        }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)

        return HTTPFuzzResult(
            url: baseURL,
            tests: tests,
            securityHeaders: headers,
            issues: issues,
            durationMs: elapsed
        )
    }

    // MARK: - HTTP Method Testing

    public func testMethods(baseURL: String) -> [HTTPTestResult] {
        let methods = ["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "TRACE", "HEAD"]
        var results: [HTTPTestResult] = []

        for method in methods {
            let result = makeRequest(url: baseURL, method: method, testName: "method-\(method)")
            var r = result
            // Flag dangerous methods that are enabled
            if ["TRACE", "PUT", "DELETE"].contains(method) && result.statusCode != 405 && result.statusCode != 501 {
                results.append(HTTPTestResult(
                    test: result.test, method: result.method, path: result.path,
                    statusCode: result.statusCode, responseSize: result.responseSize,
                    latencyMs: result.latencyMs, headers: result.headers,
                    finding: "\(method) method enabled (status \(result.statusCode)) — potential risk"
                ))
            } else {
                results.append(result)
            }
        }
        return results
    }

    // MARK: - Path Traversal Testing

    public func testPathTraversal(baseURL: String) -> [HTTPTestResult] {
        let paths = [
            "../../../etc/passwd",
            "..%2F..%2F..%2Fetc%2Fpasswd",
            "....//....//....//etc/passwd",
            "%2e%2e%2f%2e%2e%2f%2e%2e%2fetc%2fpasswd",
            "..\\..\\..\\etc\\passwd",
            ".env",
            ".git/config",
            ".git/HEAD",
            "wp-admin/",
            "admin/",
            "phpinfo.php",
            "server-status",
            "server-info",
            ".htaccess",
            "robots.txt",
            "sitemap.xml",
            "crossdomain.xml",
            "backup.sql",
            "dump.sql",
            "config.json",
            "package.json",
            ".aws/credentials"
        ]

        var results: [HTTPTestResult] = []
        for path in paths {
            let url = baseURL.hasSuffix("/") ? baseURL + path : baseURL + "/" + path
            var result = makeRequest(url: url, method: "GET", testName: "path-\(path)")

            if result.statusCode == 200 {
                let finding: String?
                if path.contains("passwd") {
                    finding = "Path traversal to \(path) returned 200 — CRITICAL"
                } else if path.contains(".env") || path.contains(".git") || path.contains(".aws") {
                    finding = "Sensitive file \(path) accessible — HIGH"
                } else if path.contains("backup") || path.contains("dump") || path.contains("config") {
                    finding = "Sensitive file \(path) accessible — MEDIUM"
                } else {
                    finding = nil
                }
                results.append(HTTPTestResult(
                    test: result.test, method: result.method, path: path,
                    statusCode: result.statusCode, responseSize: result.responseSize,
                    latencyMs: result.latencyMs, headers: result.headers,
                    finding: finding
                ))
            } else {
                results.append(result)
            }
        }
        return results
    }

    // MARK: - Security Headers Check

    public func checkSecurityHeaders(baseURL: String) -> [String: Bool] {
        let result = makeRequest(url: baseURL, method: "GET", testName: "headers")
        let headers = result.headers

        let lowered = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })

        return [
            "X-Frame-Options": lowered["x-frame-options"] != nil,
            "X-Content-Type-Options": lowered["x-content-type-options"] != nil,
            "X-XSS-Protection": lowered["x-xss-protection"] != nil,
            "Content-Security-Policy": lowered["content-security-policy"] != nil,
            "Strict-Transport-Security": lowered["strict-transport-security"] != nil,
            "Referrer-Policy": lowered["referrer-policy"] != nil,
            "Permissions-Policy": lowered["permissions-policy"] != nil,
            "X-Permitted-Cross-Domain-Policies": lowered["x-permitted-cross-domain-policies"] != nil
        ]
    }

    // MARK: - HTTP Request Helper

    private func makeRequest(url: String, method: String, testName: String) -> HTTPTestResult {
        let semaphore = DispatchSemaphore(value: 0)
        guard let urlObj = URL(string: url) else {
            return HTTPTestResult(test: testName, method: method, path: url,
                                 statusCode: 0, responseSize: 0, latencyMs: 0,
                                 headers: [:], finding: nil)
        }

        var request = URLRequest(url: urlObj)
        request.httpMethod = method
        request.timeoutInterval = 8
        // Don't follow redirects for testing
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)

        var statusCode = 0
        var responseSize = 0
        var responseHeaders: [String: String] = [:]
        let start = DispatchTime.now()

        session.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse {
                statusCode = http.statusCode
                responseSize = Int(http.expectedContentLength)
                if responseSize < 0 { responseSize = data?.count ?? 0 }
                for (key, value) in http.allHeaderFields {
                    responseHeaders["\(key)"] = "\(value)"
                }
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 10)
        session.invalidateAndCancel()

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)

        return HTTPTestResult(
            test: testName,
            method: method,
            path: urlObj.path.isEmpty ? "/" : urlObj.path,
            statusCode: statusCode,
            responseSize: responseSize,
            latencyMs: elapsed,
            headers: responseHeaders,
            finding: nil
        )
    }
}
