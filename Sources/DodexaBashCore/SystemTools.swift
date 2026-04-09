import Foundation

public struct ProcessExecutionResult: Codable, Sendable {
    public let command: [String]
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public struct SystemSnapshot: Codable, Sendable {
    public let cwd: String
    public let osVersion: String
    public let kernelVersion: String
    public let architecture: String
    public let machine: String
    public let cpuCount: String
}

public struct BinaryInspectionResult: Codable, Sendable {
    public let path: String
    public let fileDescription: String
    public let machHeader: String
    public let linkedLibraries: String
}

public struct PluginManifestDescriptor: Codable, Sendable {
    public let path: String
    public let directory: String
    public let displayName: String
    public let description: String
}

public enum SystemTools {
    public static func run(command: [String], cwd: String? = nil) -> ProcessExecutionResult {
        guard let program = command.first else {
            return .init(command: command, status: 1, stdout: "", stderr: "missing program")
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = Array(command.dropFirst())
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        do {
            try process.run()
            process.waitUntilExit()
            return .init(
                command: command,
                status: process.terminationStatus,
                stdout: String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                stderr: String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            )
        } catch {
            return .init(command: command, status: 126, stdout: "", stderr: error.localizedDescription)
        }
    }

    public static func captureSystemSnapshot(cwd: String) -> SystemSnapshot {
        SystemSnapshot(
            cwd: cwd,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            kernelVersion: sysctlValue("kern.version"),
            architecture: sysctlValue("hw.optional.arm64") == "1" ? "arm64" : sysctlValue("hw.machine"),
            machine: sysctlValue("hw.machine"),
            cpuCount: sysctlValue("hw.ncpu")
        )
    }

    public static func inspectBinary(path: String) -> BinaryInspectionResult {
        let fileResult = run(command: ["/usr/bin/file", path])
        let headerResult = run(command: ["/usr/bin/otool", "-hv", path])
        let linkedLibrariesResult = run(command: ["/usr/bin/otool", "-L", path])
        return BinaryInspectionResult(
            path: path,
            fileDescription: trimmed(fileResult.stdout, fallback: fileResult.stderr),
            machHeader: trimmed(headerResult.stdout, fallback: headerResult.stderr),
            linkedLibraries: trimmed(linkedLibrariesResult.stdout, fallback: linkedLibrariesResult.stderr)
        )
    }

    public static func binarySymbols(path: String, limit: Int) -> ProcessExecutionResult {
        let result = run(command: ["/usr/bin/nm", "-m", path])
        guard result.status == 0 else {
            return result
        }
        let lines = result.stdout.split(separator: "\n").prefix(limit).joined(separator: "\n")
        return .init(command: result.command, status: result.status, stdout: lines + (lines.isEmpty ? "" : "\n"), stderr: result.stderr)
    }

    public static func disassemble(path: String, symbol: String?, limit: Int) -> ProcessExecutionResult {
        let result = run(command: ["/usr/bin/otool", "-tvV", path])
        guard result.status == 0 else {
            return result
        }

        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let selected: [String]
        if let symbol, !symbol.isEmpty,
           let startIndex = lines.firstIndex(where: { $0.contains("<\(symbol)>:") || $0.contains("_\(symbol):") || $0.contains("\(symbol):") }) {
            selected = Array(lines[startIndex..<min(lines.count, startIndex + limit)])
        } else {
            selected = Array(lines.prefix(limit))
        }

        return .init(
            command: result.command,
            status: result.status,
            stdout: selected.joined(separator: "\n") + (selected.isEmpty ? "" : "\n"),
            stderr: result.stderr
        )
    }

    public static func discoverPluginManifests(workspace: String) -> [PluginManifestDescriptor] {
        let roots = [
            URL(fileURLWithPath: workspace).appendingPathComponent("plugins", isDirectory: true),
            URL(fileURLWithPath: workspace).appendingPathComponent(".agents/plugins", isDirectory: true),
            URL(fileURLWithPath: workspace).appendingPathComponent(".inference_os/plugins", isDirectory: true)
        ]

        let decoder = JSONDecoder()
        let fm = FileManager.default
        var seen: Set<String> = []
        var manifests: [PluginManifestDescriptor] = []

        for root in roots where fm.fileExists(atPath: root.path) {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard fileURL.lastPathComponent == "plugin.json",
                      fileURL.deletingLastPathComponent().lastPathComponent == ".codex-plugin" else {
                    continue
                }
                let normalized = fileURL.standardizedFileURL.path
                guard seen.insert(normalized).inserted else {
                    continue
                }

                let descriptor: PluginManifestDescriptor
                if let data = try? Data(contentsOf: fileURL),
                   let manifest = try? decoder.decode(GenericPluginManifest.self, from: data) {
                    descriptor = .init(
                        path: normalized,
                        directory: fileURL.deletingLastPathComponent().deletingLastPathComponent().path,
                        displayName: manifest.name ?? fileURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
                        description: manifest.description ?? ""
                    )
                } else {
                    descriptor = .init(
                        path: normalized,
                        directory: fileURL.deletingLastPathComponent().deletingLastPathComponent().path,
                        displayName: fileURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
                        description: ""
                    )
                }
                manifests.append(descriptor)
            }
        }

        return manifests.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func sysctlValue(_ key: String) -> String {
        let result = run(command: ["/usr/sbin/sysctl", "-n", key])
        return trimmed(result.stdout, fallback: result.stderr)
    }

    private static func trimmed(_ value: String, fallback: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }
}

private struct GenericPluginManifest: Codable {
    let name: String?
    let description: String?
}
