# DodexaCode Reviewer Note

## What This Is

DodexaCode packages the DodexaBash runtime as a clean-room Swift shell and MCP server for humans and AI systems. It provides:

- a dependency-light local shell,
- 33 structured MCP tools over stdio JSON-RPC,
- typed "future-shell" primitives such as intent, lease, simulate, prove, and replay,
- policy-gated security review features,
- a defensive threat-intelligence and mirror-defense engine.

## Quick Verification

Build:

```bash
swift build
```

Smoke tests:

```bash
./scripts/smoke-test.sh
```

Run the shell:

```bash
./.build/arm64-apple-macosx/debug/dodexabash
```

Run MCP server:

```bash
./.build/arm64-apple-macosx/debug/dodexabash --mcp
# or
swift run dodexabash --mcp
```

## Safety Posture

- Security modes are explicitly scoped: `passive`, `active`, `lab`.
- The browser and web client no longer implement stealth routing or attribution masking.
- Threat intelligence is framed around defensive controls and authorized validation only.

## Known Environment Note

`swift test` may require full Xcode / XCTest availability on macOS. In this environment, `swift build` and `./scripts/smoke-test.sh` are the verified paths.

## Manual Fields To Replace Before External Submission

The plugin manifest at `.codex-plugin/plugin.json` contains placeholder public URLs and contact email fields because no repository remote or public docs host was configured in this workspace.
