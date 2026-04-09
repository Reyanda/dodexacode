import XCTest
@testable import DodexaCodeCore

final class StealthDetectorTests: XCTestCase {
    func testIEEEClaims() {
        let detector = StealthDetector()

        // 1. WSA Casing Anomaly
        let mixedCaseHeaders = [
            "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            "Accept-Encoding": "gzip, deflate"
        ]
        let wsaReport = detector.comprehensiveAudit(target: "test.local", headers: mixedCaseHeaders, body: nil)
        XCTAssertTrue(wsaReport.indicators.contains { $0.type == "casing_mismatch" }, "WSA should detect mixed-case header anomalies.")

        // 2. TLI Proxy Headers
        let proxyHeaders = [
            "User-Agent": "Mozilla/5.0",
            "X-Forwarded-For": "1.2.3.4",
            "Via": "1.1 vegur"
        ]
        let tliReport = detector.comprehensiveAudit(target: "test.local", headers: proxyHeaders, body: nil)
        XCTAssertTrue(tliReport.indicators.contains { $0.category == .proxyLaundering }, "TLI should identify proxy laundering via forwarding headers.")

        // 3. SIH Masquerading
        let fakeProcesses = ["kernel_task", "launchd", "ptsd", "syslogd_update"]
        let fakeConns = ["127.0.0.1:443", "192.168.1.5:1337"]
        let sihIndicators = detector.detectSystemAnomalies(processes: fakeProcesses, connections: fakeConns)
        
        XCTAssertTrue(sihIndicators.contains { $0.type == "persistence_masquerade" }, "SIH should detect process masquerading.")
        XCTAssertTrue(sihIndicators.contains { $0.type == "c2_callback" }, "SIH should flag suspicious outbound connections.")
    }
}
