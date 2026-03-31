## Why

The `logging-accountability-framework` and `secret-rotation-tokens` changes create a system where runtime log output links to spec names and cheatsheet paths. But those cheatsheet files do not exist yet. Without them, the accountability window's "Cheatsheet:" lines are dead references.

Cheatsheets serve three audiences:
1. **Users** wondering "what is my app doing with my credentials?" — the accountability window says `Cheatsheet: docs/cheatsheets/secret-management.md`, and the file explains the full flow in plain language.
2. **Developers** debugging a specific subsystem — the cheatsheet provides a concise reference for the mechanism, failure modes, and where to look in the source.
3. **Auditors** reviewing security posture — the cheatsheet documents what protections exist, why they were chosen, and what the threat model is.

## What Changes

- Create `docs/cheatsheets/secret-management.md` — How secrets flow through the system: keyring retrieval, token file writes, container mount, GIT_ASKPASS, cleanup.
- Create `docs/cheatsheets/logging-levels.md` — What each log level shows, how to use accountability windows, the six module names, example commands.
- Create `docs/cheatsheets/token-rotation.md` — Why short-lived tokens, how the refresh task works, what happens on failure, the path toward GitHub App tokens.

Each cheatsheet follows a consistent format: Overview, How It Works (step-by-step), Failure Modes, Related Specs, CLI Commands.

## Capabilities

### New Capabilities
- `cheatsheets`: Human-readable reference documents for subsystem behavior, linked from accountability window output and @trace annotations

### Modified Capabilities
- None (documentation only)

## Impact

- **New files**: `docs/cheatsheets/secret-management.md`, `docs/cheatsheets/logging-levels.md`, `docs/cheatsheets/token-rotation.md`
- **No code changes**: These are documentation files
- **User-visible change**: The accountability window's "Cheatsheet:" lines resolve to real files
- **Dependency on**: Best created after `logging-accountability-framework` and `secret-rotation-tokens` designs are finalized (so the cheatsheets match the implementation). Can be created in parallel with a convergence pass at the end.
