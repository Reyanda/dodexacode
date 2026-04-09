import Darwin
import Foundation

// MARK: - Network Scanner: TCP Connect Scanner + Service Fingerprinter

public enum PortState: String, Codable, Sendable {
    case open, closed, filtered
}

public struct PortResult: Codable, Sendable {
    public let port: UInt16
    public let state: PortState
    public let service: String?
    public let banner: String?
    public let latencyMs: Int
}

public struct ScanResult: Codable, Sendable {
    public let host: String
    public let ip: String
    public let ports: [PortResult]
    public let startedAt: Date
    public let finishedAt: Date
    public let totalScanned: Int
    public var openPorts: [PortResult] { ports.filter { $0.state == .open } }
    public var summary: String {
        "\(host) (\(ip)): \(openPorts.count) open / \(totalScanned) scanned in \(Int(finishedAt.timeIntervalSince(startedAt) * 1000))ms"
    }
}

public enum WellKnownPorts {
    public static let top100: [UInt16] = [
        7,20,21,22,23,25,43,53,67,68,69,79,80,88,110,111,113,119,123,135,137,138,139,143,
        161,162,179,194,389,427,443,445,464,465,500,514,515,520,543,544,548,554,587,593,
        625,631,636,646,691,860,873,902,989,990,993,995,1025,1080,1194,1433,1434,1521,
        1701,1723,1812,2049,2222,2375,3000,3128,3306,3389,3690,4443,5000,5432,5900,5984,
        6379,6667,8000,8008,8080,8443,8888,9000,9090,9200,9418,27017
    ]
    public static let common: [UInt16] = [21,22,23,25,53,80,110,135,139,143,443,445,993,995,3306,3389,5432,5900,8080]

    public static func serviceName(for port: UInt16) -> String? {
        let map: [UInt16: String] = [
            21:"ftp",22:"ssh",23:"telnet",25:"smtp",53:"dns",80:"http",110:"pop3",111:"rpcbind",
            135:"msrpc",139:"netbios",143:"imap",161:"snmp",389:"ldap",443:"https",445:"smb",
            465:"smtps",514:"syslog",587:"submission",631:"ipp",636:"ldaps",993:"imaps",995:"pop3s",
            1080:"socks",1433:"mssql",1521:"oracle",1723:"pptp",2049:"nfs",2222:"ssh-alt",2375:"docker",
            3000:"dev-server",3128:"squid",3306:"mysql",3389:"rdp",3690:"svn",5000:"upnp",
            5432:"postgresql",5900:"vnc",5984:"couchdb",6379:"redis",6667:"irc",
            8000:"http-alt",8080:"http-proxy",8443:"https-alt",9090:"prometheus",9200:"elasticsearch",
            9418:"git",27017:"mongodb"
        ]
        return map[port]
    }
}

public final class TCPScanner: @unchecked Sendable {
    public let timeoutMs: Int
    public let grabBanner: Bool

    public init(timeoutMs: Int = 2000, grabBanner: Bool = true) {
        self.timeoutMs = timeoutMs
        self.grabBanner = grabBanner
    }

    public func scan(host: String, ports: [UInt16]) -> ScanResult {
        let startedAt = Date()
        let ip = resolveHost(host) ?? host
        var results: [PortResult] = []

        // Sequential scan — safe, no threading issues
        // For large port ranges, batch into groups with controlled concurrency
        if ports.count <= 32 {
            for port in ports {
                results.append(scanPort(host: ip, port: port))
            }
        } else {
            // Concurrent for large scans
            let group = DispatchGroup()
            let lock = NSLock()
            let semaphore = DispatchSemaphore(value: 16)
            let queue = DispatchQueue(label: "net.scanner", attributes: .concurrent)

            for port in ports {
                group.enter()
                semaphore.wait()
                queue.async { [self] in
                    let r = self.scanPort(host: ip, port: port)
                    lock.lock(); results.append(r); lock.unlock()
                    semaphore.signal(); group.leave()
                }
            }
            group.wait()
        }

        return ScanResult(host: host, ip: ip, ports: results.sorted { $0.port < $1.port },
                         startedAt: startedAt, finishedAt: Date(), totalScanned: ports.count)
    }

    public func scanPort(host: String, port: UInt16) -> PortResult {
        let start = DispatchTime.now()

        // Use /usr/bin/nc (netcat) for reliable port checking
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-z", "-w", String(timeoutMs / 1000 + 1), "-G", String(timeoutMs / 1000 + 1), host, String(port)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return PortResult(port: port, state: .filtered, service: nil, banner: nil, latencyMs: latMs(start))
        }

        let ms = latMs(start)

        if process.terminationStatus == 0 {
            return PortResult(port: port, state: .open, service: WellKnownPorts.serviceName(for: port), banner: nil, latencyMs: ms)
        } else {
            return PortResult(port: port, state: .closed, service: nil, banner: nil, latencyMs: ms)
        }
    }

    private func readBanner(sock: Int32, port: UInt16) -> String? {
        if [80,8080,8000,8443,443,3000].contains(port) {
            let req = "HEAD / HTTP/1.0\r\nHost: target\r\n\r\n"
            _ = req.withCString { send(sock, $0, strlen($0), 0) }
        }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = recv(sock, &buf, buf.count - 1, 0)
        guard n > 0 else { return nil }
        return String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String(String(cString: buf).prefix(256))
    }

    private func identify(_ port: UInt16, _ banner: String?) -> String? {
        if let b = banner?.lowercased() {
            if b.hasPrefix("ssh-") { return "ssh" }
            if b.contains("http/") { return port == 443 ? "https" : "http" }
            if b.contains("smtp") { return "smtp" }
            if b.contains("ftp") { return "ftp" }
            if b.contains("mysql") { return "mysql" }
            if b.contains("redis") { return "redis" }
            if b.contains("mongodb") { return "mongodb" }
        }
        return WellKnownPorts.serviceName(for: port)
    }

    private func resolveHost(_ host: String) -> String? {
        var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let addr = res else { return nil }
        defer { freeaddrinfo(res) }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var sinAddr = addr.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0 }.pointee.sin_addr
        inet_ntop(AF_INET, &sinAddr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    private func latMs(_ start: DispatchTime) -> Int { Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000) }

    public static func parsePorts(_ spec: String) -> [UInt16] {
        if spec == "common" { return WellKnownPorts.common }
        if spec == "top100" { return WellKnownPorts.top100 }
        if spec == "all" { return Array(1...65535) }
        var ports: [UInt16] = []
        for part in spec.split(separator: ",") {
            let t = part.trimmingCharacters(in: .whitespaces)
            if t.contains("-") {
                let r = t.split(separator: "-")
                if r.count == 2, let s = UInt16(r[0]), let e = UInt16(r[1]) { ports.append(contentsOf: s...e) }
            } else if let p = UInt16(t) { ports.append(p) }
        }
        return ports
    }
}
