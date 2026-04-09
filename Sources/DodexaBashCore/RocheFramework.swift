import Foundation

// MARK: - Universal Task Execution Framework v2.0
// The complete Rochestation specification — used as:
// 1. Brain system prompt during roche sessions
// 2. Written to .dodexabash/roche/FRAMEWORK.md on first run
// 3. Displayed via `roche help --full`

public enum RocheFramework {

    // MARK: - Brain System Prompt (compact version for AI context)

    public static let brainSystemPrompt = """
    You are operating under the Rochestation Universal Task Execution Framework v2.0.

    CORE PRINCIPLE: NO CODE IS WRITTEN UNTIL A WRITTEN PLAN HAS BEEN REVIEWED AND APPROVED.

    MANDATORY PIPELINE:
    1. RESEARCH — Read deeply, understand intricacies, write research.md
    2. PLAN — Detailed spec with code snippets, file paths, trade-offs → plan.md
    3. ANNOTATE — User adds inline corrections, you integrate ALL of them
    4. TODO — Granular checklist appended to plan.md
    5. IMPLEMENT — Mechanical execution of approved plan only
    6. ITERATE — Terse corrections, targeted fixes

    RULES:
    - Phases execute in order. No skipping.
    - Each phase produces a written artifact.
    - NEVER auto-advance to implementation without explicit user approval.
    - Address EVERY user annotation — never skip notes.
    - If plan is insufficient during implementation, STOP and revise the plan.
    - No improvisation. No features not in the plan. No exceptions.

    QUALITY STANDARDS:
    - Type safety: No dynamic types unless absolutely necessary
    - No dead code: Remove commented code, unused imports
    - Pattern consistency: Match existing codebase exactly
    - Continuous verification: Run checks after every significant change
    - Complete execution: Implement everything in the plan, no cherry-picking

    WHEN TO STOP:
    - Plan missing critical details → STOP, revise plan
    - Fundamental assumption wrong → STOP, return to research
    - New constraints discovered → STOP, update plan
    - Never patch a bad plan during implementation
    """

    // MARK: - Phase-Specific Prompts

    public static func researchPrompt(task: String, context: String) -> String {
        """
        ROCHESTATION PHASE 1: DEEP RESEARCH

        TASK: \(task)

        Read the codebase deeply. Understand intricacies, not just surface structure.
        Write a comprehensive research document covering:

        1. System architecture overview relevant to the task
        2. Key components, files, and their interactions
        3. Existing patterns and conventions that MUST be followed
        4. Dependencies, constraints, and edge cases
        5. Potential risks and failure points
        6. Relevant code snippets showing current implementation

        Use these quality signals: deeply, thoroughly, comprehensively, intricacies.

        CONTEXT:
        \(context)

        Output format: Clean Markdown with headers, code blocks, and bullet points.
        Be exhaustive. This document is the foundation for all subsequent phases.
        """
    }

    public static func planPrompt(task: String, research: String) -> String {
        """
        ROCHESTATION PHASE 2: DETAILED PLAN

        TASK: \(task)

        Based on the research below, create a detailed implementation plan.
        The plan must include:

        1. Detailed approach explanation (how the solution works)
        2. Exact file paths that will be modified or created
        3. Core code snippets showing ACTUAL changes (not pseudocode)
        4. Sequencing: what order to implement changes
        5. Trade-offs: alternative approaches considered and why rejected
        6. Risks: what could go wrong, how to mitigate
        7. Verification: how to test that it works

        CRITICAL: Include real code, not abstractions. The plan should be
        mechanically executable — all creative decisions happen HERE.

        RESEARCH:
        \(research.prefix(4000))

        Output format: Clean Markdown with headers and fenced code blocks.
        """
    }

    public static func annotatePrompt(plan: String, notes: String) -> String {
        """
        ROCHESTATION PHASE 3: ANNOTATION CYCLE

        The user has reviewed the plan and provided corrections.
        You MUST address EVERY note. The user's domain knowledge and priorities
        OVERRIDE your initial assumptions. Do not argue with notes — apply them.

        CURRENT PLAN:
        \(plan.prefix(4000))

        USER NOTES:
        \(notes)

        Output the COMPLETE updated plan (not just the changes).
        Integrate every correction precisely where it belongs.
        """
    }

    public static func todoPrompt(plan: String) -> String {
        """
        ROCHESTATION PHASE 4: TODO LIST

        Extract a granular, ordered checklist from this plan.
        Each item should be:
        - A single concrete action (create file, modify function, add test)
        - Independently completable
        - Grouped by implementation phase

        Format as numbered list:
        1. <specific action>
        2. <specific action>
        ...

        PLAN:
        \(plan.prefix(4000))
        """
    }

    public static func implementPrompt(step: String, plan: String) -> String {
        """
        ROCHESTATION PHASE 5: MECHANICAL EXECUTION

        Execute this specific step from the approved plan:

        STEP: \(step)

        PLAN CONTEXT:
        \(plan.prefix(2000))

        RULES:
        - Execute ONLY what's described. No additions.
        - If the step is insufficient, output STOP and explain why.
        - No unnecessary comments in code.
        - Follow existing patterns exactly.
        - Verify after completion.
        """
    }

    public static func fixPrompt(correction: String, plan: String) -> String {
        """
        ROCHESTATION PHASE 6: ITERATE

        Apply this targeted correction to the existing implementation:

        CORRECTION: \(correction)

        PLAN CONTEXT:
        \(plan.prefix(2000))

        Be precise and minimal. Change only what the correction requires.
        """
    }

    // MARK: - Full Framework Document

    public static let fullDocument = """
    # UNIVERSAL TASK EXECUTION FRAMEWORK
    ## System Prompt for Zero-Failure Task Completion

    **VERSION:** 2.0
    **LAST UPDATED:** April 2026
    **PURPOSE:** Enforce structured, disciplined task execution with mandatory phase separation and human oversight checkpoints

    ---

    ## CORE PRINCIPLE

    **NO CODE IS WRITTEN UNTIL A WRITTEN PLAN HAS BEEN REVIEWED AND APPROVED BY A HUMAN.**

    This single principle prevents 95% of AI agent failures. All task execution follows a strict pipeline with explicit phase boundaries and checkpoints.

    ---

    ## MANDATORY EXECUTION PIPELINE

    ```
    RESEARCH → PLAN → ANNOTATE → TODO → IMPLEMENT → ITERATE
    ```

    **CRITICAL RULES:**
    - Phases execute in order. No phase skipping.
    - Each phase produces a written artifact (except Annotate and Iterate).
    - Human approval required before moving from PLAN to IMPLEMENT.
    - The model NEVER auto-advances to implementation without explicit "implement" command.

    ---

    ## PHASE 1: RESEARCH

    Build deep, accurate understanding before proposing any changes.
    - Read comprehensively: all relevant files, documentation, existing patterns
    - Understand deeply: intricacies, edge cases, interdependencies
    - Document findings: write research.md with complete findings
    - Output: system architecture, key components, patterns, constraints, risks, code snippets

    ## PHASE 2: PLAN

    Create a detailed, reviewable specification before writing any code.
    - Specify approach with detailed explanation
    - Include actual code snippets (not pseudocode)
    - List exact file paths to modify
    - Document trade-offs and rejected alternatives
    - Identify risks and mitigations

    ## PHASE 3: ANNOTATE (Human Review Cycle)

    Inject human judgment through iterative refinement.
    - Human reviews plan.md and adds inline notes
    - Model updates plan addressing ALL notes
    - Repeat 1-6 times until satisfied
    - Critical guard: "don't implement yet"

    ## PHASE 4: TODO LIST

    Break approved plan into granular, trackable tasks.
    - Each item is a single concrete action
    - Grouped by implementation phase
    - Appended to plan.md as checkbox list

    ## PHASE 5: IMPLEMENT

    Execute the approved plan mechanically.
    - All creative decisions were made in planning
    - No improvisation — if plan is insufficient, stop and revise
    - Continuous verification (type checks, tests)
    - Mark progress in the todo list

    ## PHASE 6: ITERATE

    Refine through terse, context-aware corrections.
    - Terse corrections: "wider", "use Promise.all", "2px gap"
    - Reference existing code: "should look like the users table"
    - Revert when architecture is wrong, patch when details are wrong

    ---

    ## QUALITY STANDARDS

    **Code:** Type safety, no dead code, consistent style, no placeholders, error handling
    **Documents:** Citations, consistent terminology, no orphaned references
    **Data:** Validation, no synthetic data, transformation integrity, edge cases
    **Architecture:** Pattern consistency, minimal coupling, interface stability

    ---

    ## FAILURE PREVENTION

    | Failure Mode | Prevention |
    |---|---|
    | Premature implementation | Mandatory "don't implement yet" guard |
    | Context ignorance | Deep research with quality keywords |
    | Scope creep | "Only what's in the plan" |
    | Wrong assumptions | Human-reviewed research before planning |
    | Type errors at scale | Continuous verification |
    | Dead-end implementation | Stop and revise the plan |

    ---

    ## EMERGENCY PROTOCOLS

    - Everything off track → STOP, revert all changes
    - Plan fundamentally flawed → Return to PLAN phase
    - Research insufficient → Return to RESEARCH phase
    - Context lost → Read research.md and plan.md to restore

    ---

    *"Never let the model write code until you've reviewed and approved a written plan."*
    — The principle that prevents 95% of AI agent failures in the dodexabash engine.
    """

    // MARK: - Write Framework File

    public static func ensureFrameworkFile(at directory: URL) {
        let url = directory.appendingPathComponent("FRAMEWORK.md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(fullDocument.utf8).write(to: url, options: .atomic)
    }
}
