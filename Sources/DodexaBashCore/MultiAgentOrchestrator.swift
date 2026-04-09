import Foundation

// MARK: - Multi-Agent Orchestrator (Magnitude Pattern)
// A hierarchical multi-agent framework where a Lead Agent delegates
// specialized tasks to focused worker roles.

enum AgentRole: String, Codable, Sendable {
    case lead
    case explorer
    case planner
    case design
    case security
    case builder
    case reviewer
    case debugger
    case browser
}

struct AgentTask: Codable, Sendable {
    let id: String
    let description: String
    let assignee: AgentRole
    var status: TaskStatus
    var result: String?

    enum TaskStatus: String, Codable, Sendable {
        case pending, inProgress, completed, failed
    }
}

protocol WorkerAgent: Sendable {
    var role: AgentRole { get }
    var brain: LocalBrain { get }
    var context: ShellContext { get }
    
    func execute(task: String, cwd: String, runtime: BuiltinRuntime) -> String
}

// MARK: - Specialized Workers

final class DesignWorker: WorkerAgent, @unchecked Sendable {
    let role: AgentRole = .design
    let brain: LocalBrain
    let context: ShellContext
    private let designEngine: DesignEngine
    
    init(brain: LocalBrain, context: ShellContext, designEngine: DesignEngine) {
        self.brain = brain
        self.context = context
        self.designEngine = designEngine
    }
    
    func execute(task: String, cwd: String, runtime: BuiltinRuntime) -> String {
        let design = designEngine.loadDesign(cwd: cwd) ?? "No DESIGN.md found. Use standard clean UI principles."
        let systemPrompt = """
        You are the DESIGNER. Your job is to define the visual and interaction specification.
        
        If no DESIGN.md is found, you MUST autonomously establish high-end design principles:
        - Typography: San Francisco style, tight tracking, fluid scales using CSS clamp()
        - Colors: Minimalist, high contrast, subtle grays, frosted glass effects
        - Layout: Extreme negative space, 8rem+ section margins, edge-to-edge heroes
        - Animation: 60fps scroll-driven transitions, IntersectionObserver based fade-ins
        
        Current Design Context:
        ---
        \(design)
        ---
        
        Analyze the task and provide specific UI implementation specs (tokens, spacing, components).
        """
        let result = brain.askExtended(question: task, cwd: cwd, lastStatus: 0, recentHistory: [], context: systemPrompt)
        return result ?? "Design spec failed."
    }
}

final class ExplorerWorker: WorkerAgent, @unchecked Sendable {
    let role: AgentRole = .explorer
    let brain: LocalBrain
    let context: ShellContext
    private let researchEngine: ResearchEngine
    
    init(brain: LocalBrain, context: ShellContext, researchEngine: ResearchEngine) {
        self.brain = brain
        self.context = context
        self.researchEngine = researchEngine
    }
    
    func execute(task: String, cwd: String, runtime: BuiltinRuntime) -> String {
        let systemPrompt = """
        You are the EXPLORER. Your job is to research codebases and the web to gather context.
        Analyze the task and provide a set of specific search queries or areas to investigate.
        Focus on identifying high-quality libraries, performance patterns, and existing architecture.
        """
        
        // 1. Brain formulates search strategy
        guard let query = brain.askExtended(question: "Based on this task: \(task)\nWhat is the single most important search query to run to get technical context?", cwd: cwd, lastStatus: 0, recentHistory: [], context: systemPrompt) else {
            return "Exploration failed: Brain could not formulate query."
        }
        
        let cleanedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
        
        // 2. Research Engine executes the search
        let results = researchEngine.research(task: cleanedQuery, runtime: runtime)
        
        var summary = "Explorer ran search for: \(cleanedQuery)\n"
        summary += "Top Results Found:\n"
        for (i, r) in results.allResults.prefix(3).enumerated() {
            summary += "[\(i+1)] \(r.title) (\(r.source))\n"
            let snippet = r.content
            if !snippet.isEmpty { summary += "    \(snippet.prefix(200))...\n" }
        }
        
        return summary
    }
}

final class PlannerWorker: WorkerAgent, @unchecked Sendable {
    let role: AgentRole = .planner
    let brain: LocalBrain
    let context: ShellContext
    
    init(brain: LocalBrain, context: ShellContext) {
        self.brain = brain
        self.context = context
    }
    
    func execute(task: String, cwd: String, runtime: BuiltinRuntime) -> String {
        let systemPrompt = """
        You are the PLANNER. Your job is to evaluate implementation strategies and break the task into steps.
        
        Guidelines for high-quality engineering:
        - Prefer vanilla, dependency-free implementations for core logic (HTML/CSS/JS)
        - Mandate performance-first architecture (60fps, minimal reflows)
        - Structure projects with clear separation of concerns (assets/, css/, js/, index.html)
        - Include explicit verification steps for each phase
        
        Provide a concrete, step-by-step technical plan based on the exploration and design context.
        """
        let result = brain.askExtended(question: task, cwd: cwd, lastStatus: 0, recentHistory: [], context: systemPrompt)
        return result ?? "Planning failed."
    }
}

final class BuilderWorker: WorkerAgent, @unchecked Sendable {
    let role: AgentRole = .builder
    let brain: LocalBrain
    let context: ShellContext
    
    init(brain: LocalBrain, context: ShellContext) {
        self.brain = brain
        self.context = context
    }
    
    func execute(task: String, cwd: String, runtime: BuiltinRuntime) -> String {
        let systemPrompt = """
        You are the BUILDER. Your job is to take technical plans and design specs and IMPLEMENT them by writing actual code files.
        
        Output the full content of each file in a markdown code block. 
        Each code block MUST be preceded by a line with the filename, like this:
        
        FILE: path/to/filename.ext
        ```extension
        code here...
        ```
        
        Rules:
        - Ensure code is production-grade, semantic, and well-commented.
        - Follow the DESIGN and PLAN exactly.
        - Create directories if needed.
        - Only output the file blocks. No extra conversation.
        """
        
        guard let result = brain.askExtended(question: task, cwd: cwd, lastStatus: 0, recentHistory: [], context: systemPrompt, maxTokens: 4096) else {
            return "Building failed: Brain did not respond."
        }
        
        let files = parseAndWriteFiles(from: result, root: cwd)
        return "Builder emitted \(files.count) file(s):\n" + files.map { "  - \($0)" }.joined(separator: "\n")
    }
    
    private func parseAndWriteFiles(from text: String, root: String) -> [String] {
        var written: [String] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        
        var currentFile: String?
        var currentBuffer: [String] = []
        var inCodeBlock = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.uppercased().hasPrefix("FILE:") {
                currentFile = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                continue
            }
            
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    // Save buffer
                    if let filename = currentFile {
                        let fullPath = root + "/" + filename
                        let dir = (fullPath as NSString).deletingLastPathComponent
                        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                        
                        let content = currentBuffer.joined(separator: "\n")
                        try? content.write(toFile: fullPath, atomically: true, encoding: .utf8)
                        written.append(filename)
                    }
                    inCodeBlock = false
                    currentFile = nil
                    currentBuffer = []
                } else {
                    inCodeBlock = true
                }
                continue
            }
            
            if inCodeBlock {
                currentBuffer.append(String(line))
            }
        }
        
        return written
    }
}

final class ReviewerWorker: WorkerAgent, @unchecked Sendable {
    let role: AgentRole = .reviewer
    let brain: LocalBrain
    let context: ShellContext
    
    init(brain: LocalBrain, context: ShellContext) {
        self.brain = brain
        self.context = context
    }
    
    func execute(task: String, cwd: String, runtime: BuiltinRuntime) -> String {
        let systemPrompt = """
        You are the REVIEWER. Your job is to verify that the BUILDER's output matches the DESIGN and PLAN.
        Identify any missing features, bugs, or design inconsistencies.
        Output a simple PASS/FAIL summary with feedback.
        """
        let result = brain.askExtended(question: task, cwd: cwd, lastStatus: 0, recentHistory: [], context: systemPrompt)
        return result ?? "Review failed."
    }
}

final class SecurityWorker: WorkerAgent, @unchecked Sendable {
    let role: AgentRole = .security
    let brain: LocalBrain
    let context: ShellContext
    
    init(brain: LocalBrain, context: ShellContext) {
        self.brain = brain
        self.context = context
    }
    
    func execute(task: String, cwd: String, runtime: BuiltinRuntime) -> String {
        let systemPrompt = """
        You are the SECURITY ANALYST. Your job is to perform Red Teaming (Offensive) and establish Defensive guardrails.
        
        OFFENSIVE STRATEGY (Red Teaming):
        - Probe for OWASP Agentic Vectors: Goal Hijack (ASI01), Tool Misuse (ASI02), and Privilege Abuse (ASI03).
        - Test for Indirect Prompt Injections: Look for malicious payloads in web context or tool outputs.
        - Assess Operational Risk: Measure the Attack Success Rate (ASR) of the proposed plan.
        
        DEFENSIVE STRATEGY (Mitigation):
        - Enforce Zero Trust: Mandate the Principle of Least Privilege. Use "lease" for every capability.
        - Contain Blast Radius: Ensure session isolation and data provenance tracking.
        - Validate MCP/Tool Inputs: Implement strict rate limiting and cryptographic traceability ("prove").
        
        Analyze the task and provide a security audit report with mandatory mitigation steps.
        """
        let result = brain.askExtended(question: task, cwd: cwd, lastStatus: 0, recentHistory: [], context: systemPrompt)
        return result ?? "Security audit failed."
    }
}

// MARK: - Lead Agent Orchestrator

final class MultiAgentOrchestrator: @unchecked Sendable {
    private let brain: LocalBrain
    private let context: ShellContext
    private let researchEngine: ResearchEngine
    private let designEngine: DesignEngine
    private var tasks: [AgentTask] = []
    
    init(brain: LocalBrain, context: ShellContext, researchEngine: ResearchEngine, designEngine: DesignEngine) {
        self.brain = brain
        self.context = context
        self.researchEngine = researchEngine
        self.designEngine = designEngine
    }
    
    func delegate(intent: String, cwd: String, runtime: BuiltinRuntime) -> String {
        // 1. Lead Agent maps intent to subtasks
        let systemPrompt = """
        You are the LEAD AGENT. The user wants: "\(intent)"
        
        You must autonomously coordinate a secure development lifecycle:
        1. EXPLORER: Research technical context and potential vulnerabilities.
        2. DESIGNER: Establish high-end UI and interaction specs.
        3. SECURITY: Perform a Red Team audit and define Zero Trust guardrails.
        4. PLANNER: Create a step-by-step implementation plan incorporating security mitigations.
        5. BUILDER: Implement the files in a sandboxed directory using "simulate" and "lease".
        6. REVIEWER: Verify implementation against design and security specs.
        
        Output a simple list of tasks in format: [ROLE]: [TASK]
        """
        guard let planStr = brain.askExtended(question: "Plan the workflow.", cwd: cwd, lastStatus: 0, recentHistory: [], context: systemPrompt) else {
            print("DEBUG: MultiAgentOrchestrator brain.askExtended returned nil for plan.")
            return "Lead Agent failed to formulate a plan (nil response)."
        }
        
        if planStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("DEBUG: MultiAgentOrchestrator brain.askExtended returned empty string for plan.")
            return "Lead Agent failed to formulate a plan (empty response)."
        }
        
        print("DEBUG: Lead Agent formulated plan:\n\(planStr)")
        var output = "Lead Agent formulated plan:\n\(planStr)\n\n"
        
        // 2. Parse and execute
        let explorer = ExplorerWorker(brain: brain, context: context, researchEngine: researchEngine)
        let designer = DesignWorker(brain: brain, context: context, designEngine: designEngine)
        let security = SecurityWorker(brain: brain, context: context)
        let planner = PlannerWorker(brain: brain, context: context)
        let builder = BuilderWorker(brain: brain, context: context)
        let reviewer = ReviewerWorker(brain: brain, context: context)
        
        output += "--> Delegating to EXPLORER...\n"
        let expResult = explorer.execute(task: intent, cwd: cwd, runtime: runtime)
        output += "Explorer Result:\n\(expResult)\n\n"
        
        output += "--> Delegating to DESIGNER...\n"
        let designResult = designer.execute(task: "Define UI specs based on: \(expResult)", cwd: cwd, runtime: runtime)
        output += "Designer Result:\n\(designResult)\n\n"

        output += "--> Delegating to SECURITY (Red Team + Zero Trust)...\n"
        let securityResult = security.execute(task: "Audit intent: \(intent)\nContext: \(expResult)", cwd: cwd, runtime: runtime)
        output += "Security Result:\n\(securityResult)\n\n"
        
        output += "--> Delegating to PLANNER...\n"
        let planResult = planner.execute(task: "Based on design: \(designResult)\nSecurity Audit: \(securityResult)\nCreate a plan for: \(intent)", cwd: cwd, runtime: runtime)
        output += "Planner Result:\n\(planResult)\n\n"
        
        output += "--> Delegating to BUILDER...\n"
        let buildResult = builder.execute(task: "Plan: \(planResult)\nDesign: \(designResult)\nSecurity Audit: \(securityResult)\nIntent: \(intent)", cwd: cwd, runtime: runtime)
        output += "Builder Result:\n\(buildResult)\n\n"
        
        output += "--> Delegating to REVIEWER...\n"
        let reviewResult = reviewer.execute(task: "Review the builder output based on Intent: \(intent)\nBuilder output: \(buildResult)\nSecurity Requirements: \(securityResult)", cwd: cwd, runtime: runtime)
        output += "Reviewer Result:\n\(reviewResult)\n\n"
        
        output += "Lead Agent: Orchestration complete."
        return output
    }
}


