# Privacy Policy

## Summary

DodexaCode packages a local-first Swift shell and MCP runtime. The underlying runtime executes user commands locally, stores runtime state under `.dodexabash/`, and exposes structured tools over stdio when launched with `--mcp`.

## Data We Process

- Command inputs provided by the user.
- Command outputs, exit status, and proof metadata.
- Local runtime state stored in `.dodexabash/runtime.json`, `.dodexabash/session.json`, `.dodexabash/blocks.json`, and related files.
- Optional workspace summaries generated from local files when the user calls briefing or indexing features.

## What We Do Not Do

- We do not require a hosted backend to run the core product.
- We do not ship analytics or telemetry to a remote service in the default configuration.
- We do not provide attribution masking, stealth browsing, or audit suppression features.

## Security Review Features

The security commands are designed for authorized use with explicit policy gates:

- `passive`: review only
- `active`: authorized active assessment
- `lab`: private or test-only validation

These controls are intended to preserve auditability and limit unsafe use.

## Retention

Runtime state is retained locally until the operator removes it. Operators are responsible for managing retention and access to `.dodexabash/`.

## Third-Party Services

The core shell has no mandatory third-party service dependency. If an operator invokes external commands or accesses remote endpoints, those interactions are controlled by the operator's environment and policies.

## Contact

Contact: `techreyanda@gmail.com`
