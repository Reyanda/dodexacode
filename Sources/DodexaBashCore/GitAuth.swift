import Foundation
import Security

// MARK: - Git Auth: SSH, HTTPS, macOS Keychain
// Full authentication stack for git push/pull/fetch operations.
// Zero external dependencies — uses Security.framework for Keychain,
// Foundation.Process for SSH, URLSession for HTTPS.

// MARK: - Credential Types

public enum GitTransport: String, Sendable {
    case ssh
    case https
    case local
}

public struct GitCredential: Sendable {
    public let host: String
    public let username: String
    public let token: String?       // password or PAT for HTTPS
    public let sshKeyPath: String?  // for SSH
    public let source: String       // "keychain", "ssh-agent", "config", "manual"
}

public struct GitRemoteInfo: Sendable {
    public let name: String
    public let url: String
    public let host: String
    public let path: String
    public let transport: GitTransport

    public static func parse(name: String, url: String) -> GitRemoteInfo {
        // SSH: git@github.com:user/repo.git or ssh://git@github.com/user/repo.git
        if url.hasPrefix("git@") || url.hasPrefix("ssh://") {
            let cleaned = url.replacingOccurrences(of: "ssh://", with: "")
            let parts = cleaned.split(separator: ":", maxSplits: 1)
            let host = String(parts.first ?? "").replacingOccurrences(of: "git@", with: "")
            let path = parts.count > 1 ? String(parts[1]) : ""
            return GitRemoteInfo(name: name, url: url, host: host, path: path, transport: .ssh)
        }

        // HTTPS: https://github.com/user/repo.git
        if url.hasPrefix("https://") || url.hasPrefix("http://") {
            if let urlObj = URL(string: url) {
                return GitRemoteInfo(name: name, url: url, host: urlObj.host ?? "", path: urlObj.path, transport: .https)
            }
        }

        // Local: /path/to/repo or file:///path/to/repo
        return GitRemoteInfo(name: name, url: url, host: "local", path: url, transport: .local)
    }
}

// MARK: - Auth Manager

public final class GitAuthManager: @unchecked Sendable {
    private let configDir: URL  // .dodexabash/

    public init(configDir: URL) {
        self.configDir = configDir
    }

    // MARK: - Authenticate

    public func authenticate(remote: GitRemoteInfo) -> GitCredential? {
        switch remote.transport {
        case .ssh:
            return authenticateSSH(host: remote.host)
        case .https:
            return authenticateHTTPS(host: remote.host)
        case .local:
            return GitCredential(host: "local", username: "", token: nil, sshKeyPath: nil, source: "local")
        }
    }

    // MARK: - SSH

    private func authenticateSSH(host: String) -> GitCredential? {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let sshDir = home + "/.ssh"
        let fm = FileManager.default

        // Priority: ed25519 > rsa > ecdsa > dsa
        let keyNames = ["id_ed25519", "id_rsa", "id_ecdsa", "id_dsa"]

        for keyName in keyNames {
            let keyPath = sshDir + "/" + keyName
            if fm.fileExists(atPath: keyPath) {
                return GitCredential(
                    host: host,
                    username: "git",
                    token: nil,
                    sshKeyPath: keyPath,
                    source: "ssh-key"
                )
            }
        }

        // Check if ssh-agent is running
        if let authSock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"],
           fm.fileExists(atPath: authSock) {
            return GitCredential(
                host: host,
                username: "git",
                token: nil,
                sshKeyPath: nil,
                source: "ssh-agent"
            )
        }

        return nil
    }

    // MARK: - HTTPS

    private func authenticateHTTPS(host: String) -> GitCredential? {
        // 1. Try macOS Keychain (same format as git-credential-osxkeychain)
        if let cred = keychainCredential(host: host) {
            return cred
        }

        // 2. Try stored credentials in .dodexabash/credentials.json
        if let cred = storedCredential(host: host) {
            return cred
        }

        // 3. Try git credential helper
        if let cred = credentialHelperCredential(host: host) {
            return cred
        }

        return nil
    }

    // MARK: - macOS Keychain

    private func keychainCredential(host: String) -> GitCredential? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: host,
            kSecAttrProtocol: kSecAttrProtocolHTTPS,
            kSecReturnAttributes: true,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let dict = result as? [CFString: Any],
              let account = dict[kSecAttrAccount] as? String,
              let passwordData = dict[kSecValueData] as? Data,
              let password = String(data: passwordData, encoding: .utf8) else {
            return nil
        }

        return GitCredential(
            host: host,
            username: account,
            token: password,
            sshKeyPath: nil,
            source: "keychain"
        )
    }

    public func saveToKeychain(host: String, username: String, token: String) -> Bool {
        // Delete existing
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: host,
            kSecAttrProtocol: kSecAttrProtocolHTTPS
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new
        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: host,
            kSecAttrProtocol: kSecAttrProtocolHTTPS,
            kSecAttrAccount: username,
            kSecValueData: Data(token.utf8),
            kSecAttrLabel: "dodexabash: \(host)"
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess || status == errSecDuplicateItem
    }

    public func removeFromKeychain(host: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassInternetPassword,
            kSecAttrServer: host,
            kSecAttrProtocol: kSecAttrProtocolHTTPS
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    // MARK: - Stored Credentials (.dodexabash/credentials.json)

    private struct StoredCredentials: Codable {
        var entries: [StoredEntry]
    }

    private struct StoredEntry: Codable {
        let host: String
        let username: String
        let token: String
    }

    private func storedCredential(host: String) -> GitCredential? {
        let url = configDir.appendingPathComponent("credentials.json")
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(StoredCredentials.self, from: data) else {
            return nil
        }
        guard let entry = stored.entries.first(where: { $0.host == host }) else {
            return nil
        }
        return GitCredential(
            host: host,
            username: entry.username,
            token: entry.token,
            sshKeyPath: nil,
            source: "config"
        )
    }

    public func saveCredential(host: String, username: String, token: String) {
        let url = configDir.appendingPathComponent("credentials.json")
        var stored: StoredCredentials
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONDecoder().decode(StoredCredentials.self, from: data) {
            stored = existing
        } else {
            stored = StoredCredentials(entries: [])
        }

        stored.entries.removeAll { $0.host == host }
        stored.entries.append(StoredEntry(host: host, username: username, token: token))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(stored) {
            try? data.write(to: url, options: .atomic)
            // Set restrictive permissions (owner read/write only)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    public func removeCredential(host: String) {
        let url = configDir.appendingPathComponent("credentials.json")
        guard let data = try? Data(contentsOf: url),
              var stored = try? JSONDecoder().decode(StoredCredentials.self, from: data) else {
            return
        }
        stored.entries.removeAll { $0.host == host }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let newData = try? encoder.encode(stored) {
            try? newData.write(to: url, options: .atomic)
        }
    }

    // MARK: - Git Credential Helper

    private func credentialHelperCredential(host: String) -> GitCredential? {
        // Read credential.helper from ~/.gitconfig
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let globalConfig = GitConfig.parse(at: URL(fileURLWithPath: home + "/.gitconfig"))
        guard let helper = globalConfig.value(section: "credential", key: "helper") else {
            return nil
        }

        // Invoke the helper
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()

        if helper == "osxkeychain" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["credential-osxkeychain", "get"]
        } else if helper.contains("/") {
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["get"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["credential-\(helper)", "get"]
        }

        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let input = "protocol=https\nhost=\(host)\n\n"
            try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()

            let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            var username = ""
            var password = ""
            for line in output.split(separator: "\n") {
                if line.hasPrefix("username=") { username = String(line.dropFirst(9)) }
                if line.hasPrefix("password=") { password = String(line.dropFirst(9)) }
            }

            guard !username.isEmpty, !password.isEmpty else { return nil }

            return GitCredential(
                host: host,
                username: username,
                token: password,
                sshKeyPath: nil,
                source: "credential-helper"
            )
        } catch {
            return nil
        }
    }

    // MARK: - Status

    public struct AuthStatus: Sendable {
        public let sshKeys: [String]
        public let sshAgentRunning: Bool
        public let keychainHosts: [String]
        public let storedHosts: [String]
        public let credentialHelper: String?
    }

    public func authStatus() -> AuthStatus {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let sshDir = home + "/.ssh"
        let fm = FileManager.default

        // Find SSH keys
        let keyNames = ["id_ed25519", "id_rsa", "id_ecdsa", "id_dsa"]
        let sshKeys = keyNames.filter { fm.fileExists(atPath: sshDir + "/" + $0) }

        // SSH agent
        let agentRunning = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] != nil

        // Stored credentials
        let url = configDir.appendingPathComponent("credentials.json")
        var storedHosts: [String] = []
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(StoredCredentials.self, from: data) {
            storedHosts = stored.entries.map(\.host)
        }

        // Credential helper
        let globalConfig = GitConfig.parse(at: URL(fileURLWithPath: home + "/.gitconfig"))
        let helper = globalConfig.value(section: "credential", key: "helper")

        return AuthStatus(
            sshKeys: sshKeys,
            sshAgentRunning: agentRunning,
            keychainHosts: [],  // Can't enumerate keychain easily
            storedHosts: storedHosts,
            credentialHelper: helper
        )
    }
}
