# Browser Isolation Launcher Spec

@trace spec:browser-isolation-launcher

## Status: suspended

## Why This Spec

Multiple @trace annotations reference this spec name, but the spec was never formally created during OpenSpec artifact generation. This is a placeholder to eliminate ghost trace errors during validation.

## Requirements

### Requirement: TBD — placeholder spec

This spec is created retroactively as part of the traces-audit refactor and serves as a placeholder. Actual requirements are to be determined based on usage patterns in annotations.

## Implementation Notes

This spec is created retroactively as part of the traces-audit refactor. It may represent:
- An abandoned initiative that was never fully spec'd
- A feature whose spec was lost or mishandled
- A trace annotation that should have been corrected instead

## Sources of Truth

- `cheatsheets/runtime/chromium-isolation.md` — Chromium Isolation reference and patterns
- `cheatsheets/web/cdp.md` — Cdp reference and patterns

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Observable ephemeral guarantee: resources created during initialization are destroyed on shutdown
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked resources, persistence) are detectable

## Observability

```bash
git log --all --grep="browser-isolation-launcher" --oneline
git grep -n "@trace spec:browser-isolation-launcher"
```

