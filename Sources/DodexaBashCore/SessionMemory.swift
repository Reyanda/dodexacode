import Foundation

public struct ShellTrace: Codable, Sendable {
    public let timestamp: Date
    public let source: String
    public let cwd: String
    public let status: Int32
    public let durationMs: Int
    public let stdoutPreview: String
    public let stderrPreview: String
}

public struct PredictedCommand: Codable, Sendable {
    public let command: String
    public let rationale: String
    public let confidence: Double
}

private struct SessionSnapshot: Codable, Sendable {
    var version: Int = 1
    var traces: [ShellTrace] = []
}

public final class SessionStore {
    private let fileURL: URL
    private var snapshot: SessionSnapshot
    private let ignoredCommands: Set<String> = ["history", "predict", "help"]

    public init(directory: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("session.json")
        self.snapshot = SessionStore.loadSnapshot(from: fileURL)
    }

    public func record(
        source: String,
        cwd: String,
        status: Int32,
        durationMs: Int,
        stdoutPreview: String,
        stderrPreview: String
    ) {
        snapshot = SessionStore.loadSnapshot(from: fileURL)
        snapshot.traces.append(
            ShellTrace(
                timestamp: Date(),
                source: source,
                cwd: cwd,
                status: status,
                durationMs: durationMs,
                stdoutPreview: stdoutPreview,
                stderrPreview: stderrPreview
            )
        )
        if snapshot.traces.count > 400 {
            snapshot.traces.removeFirst(snapshot.traces.count - 400)
        }
        persist()
    }

    public func recent(limit: Int) -> [ShellTrace] {
        snapshot = SessionStore.loadSnapshot(from: fileURL)
        return Array(snapshot.traces.suffix(limit).reversed())
    }

    public func predictions(seedCommand: String?, limit: Int) -> [PredictedCommand] {
        snapshot = SessionStore.loadSnapshot(from: fileURL)
        let seed = normalized(seedCommand ?? latestMeaningfulCommand()?.source ?? "")
        guard !seed.isEmpty else {
            return []
        }

        var ranked: [String: (count: Int, success: Int)] = [:]
        let relevant = snapshot.traces.filter { !shouldIgnore($0.source) }
        if relevant.count >= 2 {
            for pairIndex in 1..<relevant.count {
                let previous = normalized(relevant[pairIndex - 1].source)
                let current = normalized(relevant[pairIndex].source)
                guard previous == seed else {
                    continue
                }
                var value = ranked[current, default: (0, 0)]
                value.count += 1
                if relevant[pairIndex].status == 0 {
                    value.success += 1
                }
                ranked[current] = value
            }
        }

        var results = ranked
            .sorted {
                if $0.value.count == $1.value.count {
                    return $0.value.success > $1.value.success
                }
                return $0.value.count > $1.value.count
            }
            .prefix(limit)
            .map { entry in
                let confidenceBase = Double(entry.value.success + 1) / Double(entry.value.count + 1)
                let confidence = min(0.97, 0.35 + confidenceBase * 0.45 + Double(entry.value.count) * 0.08)
                return PredictedCommand(
                    command: entry.key,
                    rationale: "observed after '\(seed)' \(entry.value.count)x in local history",
                    confidence: confidence
                )
            }

        if results.count < limit {
            for prediction in heuristicPredictions(seed: seed, limit: limit - results.count) {
                if results.contains(where: { $0.command == prediction.command }) {
                    continue
                }
                results.append(prediction)
            }
        }

        return Array(results.prefix(limit))
    }

    public func completion(prefix: String, limit: Int = 1) -> [String] {
        snapshot = SessionStore.loadSnapshot(from: fileURL)
        let normalizedPrefix = normalized(prefix)
        guard !normalizedPrefix.isEmpty else {
            return []
        }

        var seen: Set<String> = []
        var results: [String] = []
        for trace in snapshot.traces.reversed() {
            let candidate = normalized(trace.source)
            guard !shouldIgnore(trace.source) else {
                continue
            }
            guard candidate.hasPrefix(normalizedPrefix), candidate != normalizedPrefix else {
                continue
            }
            guard !seen.contains(candidate) else {
                continue
            }
            seen.insert(candidate)
            results.append(candidate)
            if results.count >= limit {
                break
            }
        }

        return results
    }

    public func commandHistory(limit: Int) -> [String] {
        snapshot = SessionStore.loadSnapshot(from: fileURL)
        var seen: Set<String> = []
        var results: [String] = []
        for trace in snapshot.traces.reversed() {
            let candidate = normalized(trace.source)
            guard !shouldIgnore(trace.source) else {
                continue
            }
            guard !candidate.isEmpty, !seen.contains(candidate) else {
                continue
            }
            seen.insert(candidate)
            results.append(candidate)
            if results.count >= limit {
                break
            }
        }
        return results
    }

    private func latestMeaningfulCommand() -> ShellTrace? {
        snapshot.traces.reversed().first { !shouldIgnore($0.source) }
    }

    private func shouldIgnore(_ source: String) -> Bool {
        guard let first = source.split(separator: " ").first else {
            return true
        }
        return ignoredCommands.contains(String(first))
    }

    private func heuristicPredictions(seed: String, limit: Int) -> [PredictedCommand] {
        let latestStatus = latestMeaningfulCommand()?.status ?? 0
        var suggestions: [PredictedCommand] = []

        func add(_ command: String, _ rationale: String, _ confidence: Double) {
            suggestions.append(PredictedCommand(command: command, rationale: rationale, confidence: confidence))
        }

        if latestStatus != 0 {
            add("brief", "failed commands usually need fresh repo context before another patch", 0.61)
            add("workflow match debug failing command", "triage flow is a good default after a failed command", 0.58)
            add("history 10", "recent command traces help explain the failure path", 0.52)
        }

        if seed.contains("swift build") {
            add("swift test", "successful builds are often followed by verification", 0.72)
            add("workflow show implementation-verification-loop", "build success usually leads into a verification pass", 0.55)
        } else if seed.contains("swift test") {
            add("history 5", "test results are often followed by quick trace review", 0.48)
        } else if seed.hasPrefix("cd ") {
            add("brief", "directory changes usually call for a compact workspace refresh", 0.63)
        } else if seed.hasPrefix("rg ") || seed.hasPrefix("grep ") {
            add("brief", "searches often lead into focused repo context review", 0.44)
        }

        if suggestions.isEmpty {
            add("brief", "compact workspace context is the safest default next step", 0.40)
            add("workflow list", "workflow cards expose repeatable operator loops", 0.37)
        }

        return Array(suggestions.prefix(limit))
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func loadSnapshot(from fileURL: URL) -> SessionSnapshot {
        guard
            let data = try? Data(contentsOf: fileURL),
            let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data)
        else {
            return SessionSnapshot()
        }
        return snapshot
    }

    private func normalized(_ command: String) -> String {
        command.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}
