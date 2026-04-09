import Darwin
import Foundation

// MARK: - Network Reconnaissance: DNS, ARP, Host Discovery, Interface Enumeration

public struct DNSRecord: Codable, Sendable {
    public let hostname: String
    public let addresses: [String]
    public let family: String
    public let canonicalName: String?
}

public struct DNSResult: Codable, Sendable {
    public let query: String
    public let records: [DNSRecord]
    public let durationMs: Int
}

public enum DNSResolver {
    public static func resolve(hostname: String) -> DNSResult {
        let start = DispatchTime.now()
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_flags = AI_CANONNAME
        var res: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &res)
        defer { freeaddrinfo(res) }
        var addr4: [String] = []; var addr6: [String] = []; var cname: String?
        if status == 0 {
            var cur = res
            while let a = cur {
                if let cn = a.pointee.ai_canonname { cname = String(cString: cn) }
                if a.pointee.ai_family == AF_INET {
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var sa = a.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0 }.pointee.sin_addr
                    inet_ntop(AF_INET, &sa, &buf, socklen_t(INET_ADDRSTRLEN))
                    addr4.append(String(cString: buf))
                } else if a.pointee.ai_family == AF_INET6 {
                    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    var sa = a.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0 }.pointee.sin6_addr
                    inet_ntop(AF_INET6, &sa, &buf, socklen_t(INET6_ADDRSTRLEN))
                    addr6.append(String(cString: buf))
                }
                cur = a.pointee.ai_next
            }
        }
        var records: [DNSRecord] = []
        if !addr4.isEmpty { records.append(DNSRecord(hostname: hostname, addresses: Array(Set(addr4)), family: "IPv4", canonicalName: cname)) }
        if !addr6.isEmpty { records.append(DNSRecord(hostname: hostname, addresses: Array(Set(addr6)), family: "IPv6", canonicalName: cname)) }
        let ms = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        return DNSResult(query: hostname, records: records, durationMs: ms)
    }

    public static func reverse(ip: String) -> String? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, ip, &addr.sin_addr)
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let r = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &buf, socklen_t(NI_MAXHOST), nil, 0, NI_NAMEREQD)
            }
        }
        return r == 0 ? String(cString: buf) : nil
    }

    public static func enumerateSubdomains(domain: String) -> [(subdomain: String, ip: String)] {
        let words = ["www","mail","ftp","smtp","pop","imap","ns1","ns2","api","dev","staging","test",
                     "admin","vpn","ssh","git","gitlab","jenkins","ci","monitor","grafana","redis",
                     "db","mysql","postgres","mongo","cdn","static","docs","wiki","blog","app","beta","internal"]
        var found: [(String, String)] = []
        let group = DispatchGroup(); let lock = NSLock(); let sem = DispatchSemaphore(value: 16)
        let q = DispatchQueue(label: "dns.enum", attributes: .concurrent)
        for w in words {
            let fqdn = "\(w).\(domain)"
            group.enter(); sem.wait()
            q.async {
                let r = resolve(hostname: fqdn)
                if let ip = r.records.first?.addresses.first { lock.lock(); found.append((fqdn, ip)); lock.unlock() }
                sem.signal(); group.leave()
            }
        }
        group.wait()
        return found.sorted { $0.0 < $1.0 }
    }
}

// MARK: - Network Interfaces

public struct NetworkInterface: Codable, Sendable {
    public let name: String
    public let address: String
    public let netmask: String?
    public let broadcastAddr: String?
    public let family: String
    public let isUp: Bool
    public let isLoopback: Bool
}

public enum NetworkInterfaces {
    public static func list() -> [NetworkInterface] {
        var interfaces: [NetworkInterface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(first) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cur {
            let name = String(cString: ifa.pointee.ifa_name)
            let flags = ifa.pointee.ifa_flags
            if let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) {
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sa = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0 }.pointee.sin_addr
                inet_ntop(AF_INET, &sa, &buf, socklen_t(INET_ADDRSTRLEN))
                var maskStr: String?
                if let mask = ifa.pointee.ifa_netmask?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0 }) {
                    var mb = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var ma = mask.pointee.sin_addr
                    inet_ntop(AF_INET, &ma, &mb, socklen_t(INET_ADDRSTRLEN))
                    maskStr = String(cString: mb)
                }
                var bcast: String?
                if flags & UInt32(IFF_BROADCAST) != 0, let dst = ifa.pointee.ifa_dstaddr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0 }) {
                    var bb = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var ba = dst.pointee.sin_addr
                    inet_ntop(AF_INET, &ba, &bb, socklen_t(INET_ADDRSTRLEN))
                    bcast = String(cString: bb)
                }
                interfaces.append(NetworkInterface(name: name, address: String(cString: buf), netmask: maskStr,
                    broadcastAddr: bcast, family: "IPv4",
                    isUp: flags & UInt32(IFF_UP) != 0, isLoopback: flags & UInt32(IFF_LOOPBACK) != 0))
            }
            cur = ifa.pointee.ifa_next
        }
        return interfaces
    }

    public static func arpTable() -> [(ip: String, mac: String, iface: String)] {
        let p = Process(); let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/arp"); p.arguments = ["-an"]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return [] }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var entries: [(String, String, String)] = []
        for line in text.split(separator: "\n") {
            let s = String(line)
            guard let o = s.firstIndex(of: "("), let c = s.firstIndex(of: ")"), s.contains(" at ") else { continue }
            let ip = String(s[s.index(after: o)..<c])
            let afterAt = s[s.range(of: " at ")!.upperBound...]
            let parts = afterAt.split(separator: " ")
            guard parts.count >= 3 else { continue }
            let mac = String(parts[0])
            if let oi = parts.firstIndex(of: "on"), oi + 1 < parts.count { entries.append((ip, mac, String(parts[oi + 1]))) }
        }
        return entries
    }
}

// MARK: - Host Discovery

public enum HostDiscovery {
    public static func pingSweep(subnet: String, timeout: Int = 1) -> [(ip: String, alive: Bool, latencyMs: Int)] {
        guard let (base, maskBits) = parseSubnet(subnet) else { return [] }
        let hostCount = min(254, (1 << (32 - maskBits)) - 2)
        let octets = base.split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4 else { return [] }
        let baseIP = (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
        var results: [(String, Bool, Int)] = []
        let group = DispatchGroup(); let lock = NSLock(); let sem = DispatchSemaphore(value: 32)
        let q = DispatchQueue(label: "ping", attributes: .concurrent)
        for i in 1...hostCount {
            let ip = baseIP + UInt32(i)
            let s = "\(ip >> 24 & 0xFF).\(ip >> 16 & 0xFF).\(ip >> 8 & 0xFF).\(ip & 0xFF)"
            group.enter(); sem.wait()
            q.async {
                let (alive, ms) = ping(host: s, timeout: timeout)
                lock.lock(); results.append((s, alive, ms)); lock.unlock()
                sem.signal(); group.leave()
            }
        }
        group.wait()
        return results.sorted { $0.0 < $1.0 }
    }

    public static func ping(host: String, timeout: Int = 2) -> (alive: Bool, latencyMs: Int) {
        let start = DispatchTime.now()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/ping")
        p.arguments = ["-c", "1", "-W", String(timeout * 1000), host]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return (false, 0) }
        let ms = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        return (p.terminationStatus == 0, ms)
    }

    private static func parseSubnet(_ s: String) -> (base: String, maskBits: Int)? {
        let parts = s.split(separator: "/")
        guard parts.count == 2, let m = Int(parts[1]) else { return (s, 24) }
        return (String(parts[0]), m)
    }
}
