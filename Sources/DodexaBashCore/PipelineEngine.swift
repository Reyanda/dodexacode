import Foundation

// MARK: - Pipeline Engine: General Stage-Based Processing Framework
// Chain stages: ingest → transform → analyze → output
// Like Unix pipes but for structured data with checkpoints, metrics, and branching.
// Zero dependencies. Each stage is a pure function: Input → Output.

// MARK: - Core Types

public struct PipelineMessage: Sendable {
    public var content: String
    public var metadata: [String: String]
    public var tokens: Int              // estimated token count
    public var cost: Double             // estimated cost in dollars
    public var stage: String            // which stage produced this
    public var timestamp: Date

    public init(content: String, metadata: [String: String] = [:], tokens: Int = 0,
                cost: Double = 0, stage: String = "input") {
        self.content = content
        self.metadata = metadata
        self.tokens = tokens > 0 ? tokens : Self.estimateTokens(content)
        self.cost = cost
        self.stage = stage
        self.timestamp = Date()
    }

    public static func estimateTokens(_ text: String) -> Int {
        // Rough estimate: ~4 chars per token for English
        max(1, text.count / 4)
    }
}

public struct PipelineStageResult: Sendable {
    public let stageName: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let savings: Double          // percentage saved (0.0 - 1.0)
    public let durationMs: Int
    public let applied: Bool            // false if stage was skipped
    public let reason: String           // why skipped or what was done
}

public struct PipelineResult: Sendable {
    public let input: PipelineMessage
    public let output: PipelineMessage
    public let stages: [PipelineStageResult]
    public let totalDurationMs: Int
    public let totalSavings: Double     // overall token reduction

    public var summary: String {
        let pct = Int(totalSavings * 100)
        return "\(input.tokens) → \(output.tokens) tokens (\(pct)% saved) in \(totalDurationMs)ms via \(stages.filter(\.applied).count) stages"
    }
}

// MARK: - Stage Protocol

public protocol PipelineStage: Sendable {
    var name: String { get }
    var description: String { get }
    func process(_ message: PipelineMessage) -> PipelineMessage
    func shouldApply(_ message: PipelineMessage) -> Bool
}

// Default: always apply
extension PipelineStage {
    public func shouldApply(_ message: PipelineMessage) -> Bool { true }
}

// MARK: - Pipeline Definition

public struct PipelineDefinition: Sendable {
    public let name: String
    public let description: String
    public let stages: [any PipelineStage]

    public init(name: String, description: String, stages: [any PipelineStage]) {
        self.name = name
        self.description = description
        self.stages = stages
    }
}

// MARK: - Pipeline Executor

public final class PipelineExecutor: @unchecked Sendable {
    private var pipelines: [String: PipelineDefinition] = [:]
    private var history: [PipelineResult] = []
    private var totalInputTokens: Int = 0
    private var totalOutputTokens: Int = 0
    private var totalRuns: Int = 0

    public init() {}

    // MARK: - Pipeline Management

    public func register(_ pipeline: PipelineDefinition) {
        pipelines[pipeline.name] = pipeline
    }

    public func pipeline(named name: String) -> PipelineDefinition? {
        pipelines[name]
    }

    public var registeredPipelines: [PipelineDefinition] {
        Array(pipelines.values).sorted { $0.name < $1.name }
    }

    // MARK: - Execute

    public func execute(pipeline name: String, input: PipelineMessage) -> PipelineResult? {
        guard let pipeline = pipelines[name] else { return nil }
        return execute(pipeline: pipeline, input: input)
    }

    public func execute(pipeline: PipelineDefinition, input: PipelineMessage) -> PipelineResult {
        let start = DispatchTime.now()
        var current = input
        var stageResults: [PipelineStageResult] = []

        for stage in pipeline.stages {
            let stageStart = DispatchTime.now()
            let inputTokens = current.tokens

            if stage.shouldApply(current) {
                current = stage.process(current)
                current.stage = stage.name
                current.timestamp = Date()

                let outputTokens = current.tokens
                let savings = inputTokens > 0 ? 1.0 - (Double(outputTokens) / Double(inputTokens)) : 0
                let elapsed = Int((DispatchTime.now().uptimeNanoseconds - stageStart.uptimeNanoseconds) / 1_000_000)

                stageResults.append(PipelineStageResult(
                    stageName: stage.name,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    savings: max(0, savings),
                    durationMs: elapsed,
                    applied: true,
                    reason: "Applied \(stage.name)"
                ))
            } else {
                let elapsed = Int((DispatchTime.now().uptimeNanoseconds - stageStart.uptimeNanoseconds) / 1_000_000)
                stageResults.append(PipelineStageResult(
                    stageName: stage.name,
                    inputTokens: inputTokens,
                    outputTokens: inputTokens,
                    savings: 0,
                    durationMs: elapsed,
                    applied: false,
                    reason: "Skipped: condition not met"
                ))
            }
        }

        let totalMs = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        let totalSavings = input.tokens > 0 ? 1.0 - (Double(current.tokens) / Double(input.tokens)) : 0

        let result = PipelineResult(
            input: input,
            output: current,
            stages: stageResults,
            totalDurationMs: totalMs,
            totalSavings: max(0, totalSavings)
        )

        // Track metrics
        history.append(result)
        if history.count > 200 { history.removeFirst() }
        totalInputTokens += input.tokens
        totalOutputTokens += current.tokens
        totalRuns += 1

        return result
    }

    // MARK: - Metrics

    public var metrics: PipelineMetrics {
        let avgSavings = history.isEmpty ? 0 : history.map(\.totalSavings).reduce(0, +) / Double(history.count)
        return PipelineMetrics(
            totalRuns: totalRuns,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            totalSaved: totalInputTokens - totalOutputTokens,
            averageSavings: avgSavings,
            recentHistory: Array(history.suffix(10))
        )
    }

    public func resetMetrics() {
        history.removeAll()
        totalInputTokens = 0
        totalOutputTokens = 0
        totalRuns = 0
    }
}

public struct PipelineMetrics: Sendable {
    public let totalRuns: Int
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let totalSaved: Int
    public let averageSavings: Double
    public let recentHistory: [PipelineResult]

    public var savingsPercent: Int { Int(averageSavings * 100) }
}

// MARK: - Built-in Generic Stages

public struct TrimWhitespaceStage: PipelineStage, Sendable {
    public let name = "trim-whitespace"
    public let description = "Remove excessive whitespace, blank lines, trailing spaces"

    public init() {}

    public func process(_ message: PipelineMessage) -> PipelineMessage {
        var text = message.content
        // Collapse multiple blank lines to single
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        // Trim trailing spaces per line
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .init(charactersIn: " \t")) }
        text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        var result = message
        result.content = text
        result.tokens = PipelineMessage.estimateTokens(text)
        return result
    }
}

public struct DeduplicateStage: PipelineStage, Sendable {
    public let name = "deduplicate"
    public let description = "Remove duplicate lines and repeated phrases"

    public init() {}

    public func process(_ message: PipelineMessage) -> PipelineMessage {
        let lines = message.content.split(separator: "\n", omittingEmptySubsequences: false)
        var seen = Set<String>()
        var unique: [String] = []
        for line in lines {
            let normalized = line.trimmingCharacters(in: .whitespaces).lowercased()
            if normalized.isEmpty || !seen.contains(normalized) {
                seen.insert(normalized)
                unique.append(String(line))
            }
        }
        var result = message
        result.content = unique.joined(separator: "\n")
        result.tokens = PipelineMessage.estimateTokens(result.content)
        return result
    }
}

public struct TruncateStage: PipelineStage, Sendable {
    public let name: String
    public let description: String
    public let maxTokens: Int

    public init(maxTokens: Int = 4000) {
        self.name = "truncate-\(maxTokens)"
        self.description = "Truncate to \(maxTokens) estimated tokens"
        self.maxTokens = maxTokens
    }

    public func shouldApply(_ message: PipelineMessage) -> Bool {
        message.tokens > maxTokens
    }

    public func process(_ message: PipelineMessage) -> PipelineMessage {
        let maxChars = maxTokens * 4  // rough estimate
        var result = message
        if result.content.count > maxChars {
            result.content = String(result.content.prefix(maxChars)) + "\n[...truncated]"
        }
        result.tokens = PipelineMessage.estimateTokens(result.content)
        return result
    }
}

public struct MetadataStage: PipelineStage, Sendable {
    public let name = "metadata"
    public let description = "Add processing metadata"
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    public func process(_ message: PipelineMessage) -> PipelineMessage {
        var result = message
        result.metadata[key] = value
        return result
    }
}
