# Security Policy

## Supported Scope

This repository supports:

- local shell execution,
- stdio MCP server operation,
- policy-gated security review workflows,
- defensive threat-intelligence and mirror-defense analysis.

## Disclosure

If you identify a security issue in DodexaCode:

1. Do not publish exploit details before maintainers have had a chance to review them.
2. Provide a clear description, impacted component, reproduction steps, and expected impact.
3. Include logs, stack traces, or sanitized artifacts where possible.

Contact: `techreyanda@gmail.com`

## Safe Testing Expectations

Testing should remain within:

- systems you own,
- systems you are explicitly authorized to assess,
- private or disposable lab environments for high-impact validation.

This repository intentionally avoids features that would reduce attribution, defeat anti-abuse systems, or suppress audit trails.

## Current Hardening Notes

- Security workflows are gated by assessment mode: `passive`, `active`, `lab`.
- Browser and HTTP client paths no longer expose stealth transport behavior.
- Threat-intelligence coverage includes protocol abuse, session isolation, identity-fabric erosion, and context provenance loss.
