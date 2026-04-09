# DodexaCode

DodexaCode is the public repository for the DodexaBash runtime: a Bash-inspired shell written in Swift, designed as a lightweight operator environment for humans and AI systems. It is clean-room, dependency-free, and includes local memory, workspace briefing, workflow cards, and 20 future-shell primitives as first-class runtime objects.

## Dependency Policy

- No third-party Swift packages
- No terminal UI frameworks
- No local database dependency
- No Python or Node sidecars
- Swift standard library, `Foundation`, and `Darwin` only

The TUI uses raw ANSI rendering and `termios` directly.

## Features

### Core Shell

- Interactive REPL with CotEditor-inspired ANSI rendering
- External command execution through `PATH`
- Pipelines with buffered stage handoff
- Command chaining: `;`, `&&`, `||`
- Quotes, escapes, `~`, `$VAR`, `${VAR}`, `$?`
- Command substitution with `$(...)`
- Wildcard globbing for `*`, `?`, and `[...]`
- Redirection: `<`, `>`, `>>`
- Script file execution and `-c` single-command mode

### Builtins

| Command | Description |
| --- | --- |
| `cd [dir]` | Change directory with `OLDPWD` tracking |
| `pwd` | Print working directory |
| `echo [-n] [args...]` | Print arguments |
| `env` / `set` | List environment variables |
| `export NAME=value` | Set environment variable |
| `unset NAME` | Remove environment variable |
| `brief [path] [--json]` | Compact workspace briefing |
| `history [limit] [--json]` | Structured session memory |
| `predict [seed] [--json]` | Next-command suggestions |
| `workflow [list\|show\|match] [--json]` | Workflow cards |
| `md [show\|headings\|section\|ingest] [--json]` | Native Markdown parsing for session docs and handoff files |
| `help` | List all builtins |
| `exit [status]` | Exit the shell |

### AI-Native Additions

- **`brief`** generates a compact workspace briefing: file counts, language mix, key files, recent edits, and symbol counts.
- **`history`** reads structured local session memory with status, timing, working directory, and previews.
- **`predict`** runs a shadow-scheduler heuristic that suggests likely next commands from local transition history plus fallback rules.
- **`workflow`** lists and matches workflow cards so common tasks like repo refresh, bug triage, and verification have an explicit operating frame.
- **`md`** parses Markdown files natively into headings, bullets, code blocks, and path-addressable sections so files like `SESSION.md` become shell-readable state instead of opaque text blobs.

### MCP Server

33 structured tools exposed over stdio JSON-RPC via `--mcp`. Tools carry structured envelopes with `traceId`, `generatedAt`, and `futureHints` metadata.

### System Tools

Binary inspection, symbol listing, and disassembly via `otool` and `nm` for assembly-level context.

## Future-Shell Primitives

The DodexaBash runtime implements 20 primitives that replace the Unix "strings + exit codes" model with typed, provenance-aware, capability-scoped execution.

| Primitive | Builtin | Description |
| --- | --- | --- |
| Artifact envelopes | `artifact` | Typed pipes with provenance, content hashing, and policy tags |
| Intent contracts | `intent` | Declare what you are trying to do before mutating anything |
| Capability leases | `lease` | Scoped, time-limited permissions that auto-expire |
| Simulation | `simulate` | Predict effects, risk, and rollback path before executing |
| Proof-carrying outputs | `prove` | Every execution generates an evidence chain with confidence |
| Entity handles | `entity` | Latent object references with multimodal views |
| Attention routing | `attention` | Ranked interrupts: urgent, important, normal, deferrable |
| Policy envelopes | `policy` | Privacy, budget, locality, and air-gap constraints on execution |
| World graph | `world` | Live graph of files, directories, and relationships |
| Uncertainty surfaces | `uncertainty` | What is known, inferred, guessed, stale, or contradicted |
| Repair loops | `repair` | Structured failure recovery with root causes and retry plans |
| Delegation fabric | `delegate` | Spawn agent tasks with ownership, merge rules, and leases |
| Cognitive replay | `replay` | Compressed decision state for agent handoff |
| Semantic diff | `diff semantic` | Meaning-level comparison, not just line diffs |

All primitives support `--json` for machine consumption and are exposed as MCP tools.

### How Primitives Compose

```bash
# Declare intent, simulate the risky command, then execute with proof
intent set "Deploy new version safely"
simulate git push origin main
lease grant write:repo origin 120
# ... execute ...
prove last
uncertainty show
replay create
md section SESSION.md "3. Attach Rich Metadata to Command Results"
```

### Automatic Runtime Behavior

Every command execution automatically:

1. **Generates a proof envelope** with exit status, stdout/stderr previews, timestamps, and working directory as evidence items.
2. **Creates a repair plan** on failure (exit != 0) with root cause analysis and suggested fixes.
3. **Stores an artifact** from non-trivial output with provenance and content hash.
4. **Persists runtime state** to `.dodexabash/runtime.json` so intents, leases, proofs, artifacts, and repair state survive across shell restarts.

## Running

```bash
swift build
./.build/arm64-apple-macosx/debug/dodexabash           # interactive REPL on Apple Silicon
./.build/arm64-apple-macosx/debug/dodexabash -c 'echo hello | tr a-z A-Z'
./.build/arm64-apple-macosx/debug/dodexabash --mcp
swift run dodexabash --mcp                             # portable MCP startup path
./scripts/smoke-test.sh                                # feature and persistence smoke tests
```

## Architecture

```
Sources/
  DodexaBash/
    main.swift             # entry point: --mcp, -c, script, or interactive
    TerminalUI.swift       # CotEditor-inspired ANSI TUI with raw termios
  DodexaBashCore/
    AST.swift              # abstract syntax tree definitions
    Lexer.swift            # tokenization with quotes, escapes, variables
    Parser.swift           # recursive descent: conditionals, pipelines, commands
    ShellContext.swift     # environment, lastStatus, working directory
    ShellEvaluator.swift   # main Shell class and evaluation engine
    Builtins.swift         # all 28 built-in commands
    SessionMemory.swift    # local history, predictions, completion
    WorkspaceBriefing.swift # compact repo context generation
    WorkflowLibrary.swift  # routing templates for operator tasks
    SystemTools.swift      # binary inspection, plugin discovery
    MarkdownNative.swift   # native markdown parsing for session and handoff docs
    McpServer.swift        # MCP protocol server with 33 tools
    FutureRuntime.swift    # 17 type families for 20 future-shell primitives
```

## What It Is Not

- Not GNU Bash source code
- Not POSIX-complete
- Does not implement job control, shell functions, arrays, or streaming pipelines yet

## Where to Go Next

1. Replace buffered pipelines with true streaming and backpressure-aware process graphs
2. Track quote boundaries explicitly so expansion semantics can become shell-accurate instead of shell-inspired
3. Deeper simulate engine: parse through lexer, resolve builtins, predict actual file modifications
4. Enrich world graph with source-level symbol nodes and dependency edges
5. Attach trace IDs, intent IDs, and lease scopes to command results
