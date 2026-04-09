# DodexaCode OpenAI Submission Note

## Summary

DodexaCode is a clean-room Swift shell and stdio MCP runtime for humans and AI systems. It combines a dependency-light local shell, structured workspace understanding, typed execution primitives, and policy-gated security review tooling in one macOS-native package.

Repository: `https://github.com/Reyanda/dodexacode`

## Core Capabilities

- Interactive Swift shell with command execution, pipes, redirection, and scripting
- 35 structured MCP tools exposed over stdio JSON-RPC
- Workspace briefing, workflow matching, history, prediction, and native Markdown parsing
- Self-diagnostics with `doctor` and machine-readable product self-description with `catalog`
- Typed future-shell primitives such as `intent`, `lease`, `simulate`, `prove`, and `replay`
- Defensive threat-intelligence and mirror-defense analysis for authorized security review

## Safety Posture

- Security workflows are explicitly scoped by `passive`, `active`, and `lab` modes.
- Browser and web paths do not expose stealth routing or attribution-masking features.
- Threat intelligence is framed around defensive controls, detection, containment, recovery, and validation.
- The public plugin surface points to published privacy, terms, and security documents in this repository.

## Verification

Build:

```bash
swift build
```

Smoke test:

```bash
./scripts/smoke-test.sh
```

Reviewer commands:

```bash
./.build/arm64-apple-macosx/debug/dodexacode -c 'doctor'
./.build/arm64-apple-macosx/debug/dodexacode -c 'catalog reviewer'
```

Run MCP server:

```bash
swift run dodexacode --mcp
```

## Submission Artifacts

- Plugin manifest: `.codex-plugin/plugin.json`
- Reviewer note: `REVIEWER_NOTE.md`
- Privacy policy: `PRIVACY.md`
- Terms of service: `TERMS.md`
- Security policy: `SECURITY.md`
