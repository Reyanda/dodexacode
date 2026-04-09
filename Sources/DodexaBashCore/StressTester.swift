import Darwin
import Foundation

// MARK: - Stress Tester: TCP/UDP/HTTP Load Generation + Bandwidth + Latency
// Pure Swift using Darwin sockets and Foundation URLSession.
// For authorized internal network resilience testing only.

// MARK: - Result Types

public struct StressResult: Codable, Sendable {
    public let target: String
    public let protocol_: String   // "tcp", "udp", "http"
    public let totalRequests: Int
    public let successCount: Int
    public let failureCount: Int
    public let durationMs: Int
    public let requestsPerSecond: Double
    public let latency: LatencyStats
    public let bytesTransferred: Int
}

public struct LatencyStats: Codable, Sendable {
    public let min: Int     // ms
    public let max: Int     // ms
    public let avg: Int     // ms
    public let p50: Int     // ms
    public let p95: Int     // ms
    public let p99: Int     // ms
    public let jitter: Int  // ms (stddev)
}

public struct BandwidthResult: Codable, Sendable {
    public let target: String
    public let direction: String      // "upload" or "download"
    public let bytesTransferred: Int
    public let durationMs: Int
    public let throughputMbps: Double
}

// MARK: - TCP Stress Tester

public final class TCPStressTester: @unchecked Sendable {

    public init() {}

    /// TCP connection flood — open many connections to test connection handling
    public func tcpStress(
        host: String,
        port: UInt16,
        connections: Int = 100,
        ratePerSecond: Int = 50,
        durationSeconds: Int = 10,
        payloadSize: Int = 64
    ) -> StressResult {
        let startTime = DispatchTime.now()
        let deadline = Date().addingTimeInterval(TimeInterval(durationSeconds))
        let payload = Data(repeating: 0x41, count: payloadSize) // 'A' bytes

        let group = DispatchGroup()
        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: min(connections, 128))
        let queue = DispatchQueue(label: "stress.tcp", attributes: .concurrent)

        var successes = 0
        var failures = 0
        var latencies: [Int] = []
        var totalBytes = 0
        var requestCount = 0

        let intervalNs = ratePerSecond > 0 ? UInt64(1_000_000_000 / ratePerSecond) : 0

        while Date() < deadline && requestCount < connections * durationSeconds {
            requestCount += 1
            group.enter()
            semaphore.wait()

            queue.async {
                let connStart = DispatchTime.now()
                let result = self.tcpConnect(host: host, port: port, payload: payload)
                let elapsed = Int((DispatchTime.now().uptimeNanoseconds - connStart.uptimeNanoseconds) / 1_000_000)

                lock.lock()
                if result.success {
                    successes += 1
                    totalBytes += result.bytesReceived
                } else {
                    failures += 1
                }
                latencies.append(elapsed)
                lock.unlock()

                semaphore.signal()
                group.leave()
            }

            // Rate limiting
            if intervalNs > 0 {
                Thread.sleep(forTimeInterval: Double(intervalNs) / 1_000_000_000.0)
            }
        }

        group.wait()

        let totalDuration = Int((DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)
        let rps = totalDuration > 0 ? Double(successes + failures) / (Double(totalDuration) / 1000.0) : 0

        return StressResult(
            target: "\(host):\(port)",
            protocol_: "tcp",
            totalRequests: successes + failures,
            successCount: successes,
            failureCount: failures,
            durationMs: totalDuration,
            requestsPerSecond: rps,
            latency: computeLatencyStats(latencies),
            bytesTransferred: totalBytes
        )
    }

    private func tcpConnect(host: String, port: UInt16, payload: Data) -> (success: Bool, bytesReceived: Int) {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return (false, 0) }
        defer { close(sock) }

        // Set timeout
        var tv = timeval()
        tv.tv_sec = 3
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { return (false, 0) }

        // Send payload
        _ = payload.withUnsafeBytes { ptr in
            send(sock, ptr.baseAddress, payload.count, 0)
        }

        // Read response (non-blocking)
        var buf = [UInt8](repeating: 0, count: 4096)
        let received = recv(sock, &buf, buf.count, 0)

        return (true, max(0, received))
    }

    // MARK: - UDP Stress

    public func udpStress(
        host: String,
        port: UInt16,
        packetsPerSecond: Int = 100,
        durationSeconds: Int = 10,
        payloadSize: Int = 512
    ) -> StressResult {
        let startTime = DispatchTime.now()
        let deadline = Date().addingTimeInterval(TimeInterval(durationSeconds))
        let payload = Data(repeating: 0x42, count: payloadSize)

        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else {
            return StressResult(target: "\(host):\(port)", protocol_: "udp", totalRequests: 0,
                               successCount: 0, failureCount: 1, durationMs: 0,
                               requestsPerSecond: 0, latency: emptyLatency(), bytesTransferred: 0)
        }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)

        var sent = 0
        var failed = 0
        var latencies: [Int] = []
        let intervalUs = packetsPerSecond > 0 ? 1_000_000 / packetsPerSecond : 0

        while Date() < deadline {
            let pktStart = DispatchTime.now()

            let result = payload.withUnsafeBytes { ptr -> Int in
                withUnsafePointer(to: &addr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        sendto(sock, ptr.baseAddress, payload.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }

            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - pktStart.uptimeNanoseconds) / 1_000_000)
            latencies.append(elapsed)

            if result >= 0 { sent += 1 } else { failed += 1 }

            if intervalUs > 0 { usleep(UInt32(intervalUs)) }
        }

        let totalDuration = Int((DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)
        let rps = totalDuration > 0 ? Double(sent + failed) / (Double(totalDuration) / 1000.0) : 0

        return StressResult(
            target: "\(host):\(port)",
            protocol_: "udp",
            totalRequests: sent + failed,
            successCount: sent,
            failureCount: failed,
            durationMs: totalDuration,
            requestsPerSecond: rps,
            latency: computeLatencyStats(latencies),
            bytesTransferred: sent * payloadSize
        )
    }

    // MARK: - HTTP Stress

    public func httpStress(
        url: String,
        concurrency: Int = 10,
        totalRequests: Int = 100,
        method: String = "GET"
    ) -> StressResult {
        let startTime = DispatchTime.now()
        guard let urlObj = URL(string: url) else {
            return StressResult(target: url, protocol_: "http", totalRequests: 0,
                               successCount: 0, failureCount: 1, durationMs: 0,
                               requestsPerSecond: 0, latency: emptyLatency(), bytesTransferred: 0)
        }

        let group = DispatchGroup()
        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: concurrency)

        var successes = 0
        var failures = 0
        var latencies: [Int] = []
        var totalBytes = 0

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpMaximumConnectionsPerHost = concurrency
        let session = URLSession(configuration: config)

        for _ in 0..<totalRequests {
            group.enter()
            semaphore.wait()

            var request = URLRequest(url: urlObj)
            request.httpMethod = method

            let reqStart = DispatchTime.now()
            session.dataTask(with: request) { data, response, error in
                let elapsed = Int((DispatchTime.now().uptimeNanoseconds - reqStart.uptimeNanoseconds) / 1_000_000)

                lock.lock()
                latencies.append(elapsed)
                if let http = response as? HTTPURLResponse, http.statusCode < 500, error == nil {
                    successes += 1
                    totalBytes += data?.count ?? 0
                } else {
                    failures += 1
                }
                lock.unlock()

                semaphore.signal()
                group.leave()
            }.resume()
        }

        group.wait()
        session.invalidateAndCancel()

        let totalDuration = Int((DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)
        let rps = totalDuration > 0 ? Double(successes + failures) / (Double(totalDuration) / 1000.0) : 0

        return StressResult(
            target: url,
            protocol_: "http",
            totalRequests: successes + failures,
            successCount: successes,
            failureCount: failures,
            durationMs: totalDuration,
            requestsPerSecond: rps,
            latency: computeLatencyStats(latencies),
            bytesTransferred: totalBytes
        )
    }

    // MARK: - Bandwidth Measurement

    public func measureBandwidth(host: String, port: UInt16, durationSeconds: Int = 5) -> BandwidthResult {
        let startTime = DispatchTime.now()
        let deadline = Date().addingTimeInterval(TimeInterval(durationSeconds))
        let payload = Data(repeating: 0x58, count: 65536) // 64KB chunks

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            return BandwidthResult(target: "\(host):\(port)", direction: "upload",
                                  bytesTransferred: 0, durationMs: 0, throughputMbps: 0)
        }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            return BandwidthResult(target: "\(host):\(port)", direction: "upload",
                                  bytesTransferred: 0, durationMs: 0, throughputMbps: 0)
        }

        var totalSent = 0
        while Date() < deadline {
            let sent = payload.withUnsafeBytes { ptr in
                send(sock, ptr.baseAddress, payload.count, 0)
            }
            if sent <= 0 { break }
            totalSent += sent
        }

        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)
        let mbps = elapsed > 0 ? (Double(totalSent) * 8.0) / (Double(elapsed) / 1000.0) / 1_000_000.0 : 0

        return BandwidthResult(
            target: "\(host):\(port)",
            direction: "upload",
            bytesTransferred: totalSent,
            durationMs: elapsed,
            throughputMbps: mbps
        )
    }

    // MARK: - Latency Profiler

    public func measureLatency(host: String, count: Int = 20) -> LatencyStats {
        var latencies: [Int] = []
        for _ in 0..<count {
            let (alive, ms) = HostDiscovery.ping(host: host, timeout: 3)
            if alive { latencies.append(ms) }
        }
        return computeLatencyStats(latencies)
    }

    // MARK: - Stats Helpers

    func computeLatencyStats(_ latencies: [Int]) -> LatencyStats {
        guard !latencies.isEmpty else { return emptyLatency() }

        let sorted = latencies.sorted()
        let sum = sorted.reduce(0, +)
        let avg = sum / sorted.count
        let mean = Double(avg)
        let variance = sorted.map { pow(Double($0) - mean, 2) }.reduce(0, +) / Double(sorted.count)
        let jitter = Int(sqrt(variance))

        return LatencyStats(
            min: sorted.first ?? 0,
            max: sorted.last ?? 0,
            avg: avg,
            p50: percentile(sorted, 0.50),
            p95: percentile(sorted, 0.95),
            p99: percentile(sorted, 0.99),
            jitter: jitter
        )
    }

    private func percentile(_ sorted: [Int], _ p: Double) -> Int {
        let index = Int(Double(sorted.count - 1) * p)
        return sorted[max(0, min(index, sorted.count - 1))]
    }

    private func emptyLatency() -> LatencyStats {
        LatencyStats(min: 0, max: 0, avg: 0, p50: 0, p95: 0, p99: 0, jitter: 0)
    }
}
