import Foundation

// MARK: - Pipeline Builtins: Shell commands for pipeline management

extension Builtins {
    static func pipelineBuiltin(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let sub = args.first ?? "status"
        let subArgs = Array(args.dropFirst())

        switch sub {
        case "status":
            return pipelineStatus(runtime: runtime)
        case "list":
            return pipelineList(runtime: runtime)
        case "run":
            return pipelineRun(args: subArgs, runtime: runtime)
        case "test":
            return pipelineTest(args: subArgs, runtime: runtime)
        case "metrics":
            return pipelineMetrics(runtime: runtime)
        case "reset":
            return pipelineReset(runtime: runtime)
        case "optimize":
            return pipelineOptimize(args: subArgs, runtime: runtime)
        default:
            return pipelineHelp()
        }
    }

    // MARK: - Status

    private static func pipelineStatus(runtime: BuiltinRuntime) -> CommandResult {
        let exec = runtime.pipelineExecutor
        let pipelines = exec.registeredPipelines
        let metrics = exec.metrics

        var lines: [String] = ["Pipeline Engine:"]
        lines.append("  Registered: \(pipelines.count) pipelines")
        lines.append("  Total runs: \(metrics.totalRuns)")
        if metrics.totalRuns > 0 {
            lines.append("  Tokens in: \(formatTokens(metrics.totalInputTokens))")
            lines.append("  Tokens out: \(formatTokens(metrics.totalOutputTokens))")
            lines.append("  Saved: \(formatTokens(metrics.totalSaved)) (\(metrics.savingsPercent)% avg)")
        }
        for p in pipelines {
            lines.append("  \u{25CF} \(p.name) — \(p.stages.count) stages: \(p.stages.map(\.name).joined(separator: " → "))")
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - List

    private static func pipelineList(runtime: BuiltinRuntime) -> CommandResult {
        let pipelines = runtime.pipelineExecutor.registeredPipelines
        if pipelines.isEmpty { return textResult("No pipelines registered.\n") }

        var lines: [String] = ["Pipelines (\(pipelines.count)):"]
        for p in pipelines {
            lines.append("")
            lines.append("  \u{001B}[1m\(p.name)\u{001B}[0m — \(p.description)")
            for (i, stage) in p.stages.enumerated() {
                let connector = i == p.stages.count - 1 ? "\u{2514}" : "\u{251C}"
                lines.append("    \(connector)\u{2500} \(stage.name): \(stage.description)")
            }
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Run

    private static func pipelineRun(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard args.count >= 2 else {
            return textResult("Usage: pipeline run <pipeline-name> <input text...>\n")
        }
        let name = args[0]
        let input = args.dropFirst().joined(separator: " ")

        let message = PipelineMessage(content: input)
        guard let result = runtime.pipelineExecutor.execute(pipeline: name, input: message) else {
            return CommandResult(status: 1, io: ShellIO(stderr: Data("Pipeline '\(name)' not found.\n".utf8)))
        }

        return formatPipelineResult(result)
    }

    // MARK: - Test (run token-optimizer on sample)

    private static func pipelineTest(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        let input = args.isEmpty
            ? "In order to understand how it works, please analyze the following document comprehensively and provide me with a detailed summary that includes all key points and important details about the system architecture. I would like to know about the intricacies of the implementation."
            : args.joined(separator: " ")

        let message = PipelineMessage(content: input)
        guard let result = runtime.pipelineExecutor.execute(pipeline: "token-optimizer", input: message) else {
            return textResult("Token optimizer pipeline not registered. Run any command first.\n")
        }

        return formatPipelineResult(result)
    }

    // MARK: - Optimize (shorthand for token-optimizer)

    private static func pipelineOptimize(args: [String], runtime: BuiltinRuntime) -> CommandResult {
        guard !args.isEmpty else {
            return textResult("Usage: pipeline optimize <text to optimize>\n")
        }
        let input = args.joined(separator: " ")
        let message = PipelineMessage(content: input)
        guard let result = runtime.pipelineExecutor.execute(pipeline: "token-optimizer", input: message) else {
            return textResult("Token optimizer not available.\n")
        }

        var lines: [String] = []
        lines.append("Original (\(result.input.tokens) tokens):")
        lines.append("  \(String(result.input.content.prefix(120)))")
        lines.append("")
        lines.append("Optimized (\(result.output.tokens) tokens):")
        lines.append("  \(String(result.output.content.prefix(120)))")
        lines.append("")
        lines.append("Saved: \(result.input.tokens - result.output.tokens) tokens (\(Int(result.totalSavings * 100))%)")
        if let model = result.output.metadata["routed_model"] {
            lines.append("Routed to: \(model) model (\(result.output.metadata["complexity"] ?? "unknown") complexity)")
        }
        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Metrics

    private static func pipelineMetrics(runtime: BuiltinRuntime) -> CommandResult {
        let m = runtime.pipelineExecutor.metrics
        if m.totalRuns == 0 { return textResult("No pipeline runs yet.\n") }

        var lines: [String] = ["Pipeline Metrics:"]
        lines.append("  Total runs: \(m.totalRuns)")
        lines.append("  Input tokens: \(formatTokens(m.totalInputTokens))")
        lines.append("  Output tokens: \(formatTokens(m.totalOutputTokens))")
        lines.append("  Tokens saved: \(formatTokens(m.totalSaved))")
        lines.append("  Average savings: \(m.savingsPercent)%")

        if !m.recentHistory.isEmpty {
            lines.append("")
            lines.append("Recent runs:")
            for r in m.recentHistory.suffix(5) {
                let pct = Int(r.totalSavings * 100)
                lines.append("  \(r.input.tokens) → \(r.output.tokens) (\(pct)% saved) \(r.stages.filter(\.applied).count) stages")
            }
        }

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Reset

    private static func pipelineReset(runtime: BuiltinRuntime) -> CommandResult {
        runtime.pipelineExecutor.resetMetrics()
        return textResult("Pipeline metrics reset.\n")
    }

    // MARK: - Help

    private static func pipelineHelp() -> CommandResult {
        textResult("""
        Pipeline Engine — Stage-based processing framework

        Commands:
          pipeline status              Overview + registered pipelines
          pipeline list                Detailed pipeline descriptions
          pipeline run <name> <text>   Run a named pipeline on text
          pipeline test [text]         Test the token-optimizer pipeline
          pipeline optimize <text>     Shorthand: compress text through token-optimizer
          pipeline metrics             Token savings statistics
          pipeline reset               Reset metrics counters

        Built-in Pipelines:
          token-optimizer    6-stage: compress → cache → route → optimize → control → monitor
          token-light        2-stage: compress + whitespace only
          token-aggressive   9-stage: all optimizations + truncation + dedup

        Token Optimization Stages:
          1. trim-whitespace     Remove excessive whitespace
          2. prompt-compress     Replace verbose phrases (30-70% savings)
          3. semantic-cache      Skip if similar query was cached (60-91%)
          4. model-router        Route to cheapest capable model (40-60%)
          5. context-optimizer   Compact JSON, abbreviate code (50-70%)
          6. output-control      Set max tokens + stop sequences (25-50%)
          7. token-monitor       Track usage against budget

        """)
    }

    // MARK: - Formatting

    private static func formatPipelineResult(_ result: PipelineResult) -> CommandResult {
        var lines: [String] = ["Pipeline Result: \(result.summary)"]
        lines.append("")

        for stage in result.stages {
            let icon = stage.applied ? "\u{001B}[32m\u{2713}\u{001B}[0m" : "\u{001B}[2m\u{25CB}\u{001B}[0m"
            let savings = stage.applied && stage.savings > 0
                ? " \u{001B}[32m-\(Int(stage.savings * 100))%\u{001B}[0m"
                : ""
            lines.append("  \(icon) \(stage.stageName): \(stage.inputTokens) → \(stage.outputTokens)\(savings) (\(stage.durationMs)ms)")
        }

        lines.append("")
        lines.append("Input:  \(String(result.input.content.prefix(80)))")
        lines.append("Output: \(String(result.output.content.prefix(80)))")

        if let model = result.output.metadata["routed_model"] {
            lines.append("Model: \(model) (\(result.output.metadata["complexity"] ?? "?"))")
        }
        if result.output.metadata["cache_hit"] == "true" {
            lines.append("\u{001B}[32mCache HIT\u{001B}[0m (similarity: \(result.output.metadata["cache_similarity"] ?? "?"))")
        }
        if let warning = result.output.metadata["budget_warning"] {
            lines.append("\u{001B}[33m\u{26A0} \(warning)\u{001B}[0m")
        }

        return textResult(lines.joined(separator: "\n") + "\n")
    }

    private static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
