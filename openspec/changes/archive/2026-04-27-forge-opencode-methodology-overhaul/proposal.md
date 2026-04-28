## Why

Today's `images/default/config-overlay/opencode/instructions/methodology.md` is 36 lines of generalities. The model in `~/src/java/ENVIRONMENT_REPORT.md` never even tried `which java` because the methodology never told it to discover what was on PATH. Per `~/src/java/container_enhancements.md`: opencode's instruction surface needs an action-first methodology that tells the agent on first turn:

1. Run `tillandsias-inventory`. Read `$TILLANDSIAS_CHEATSHEETS/INDEX.md`. Do NOT assume tools are missing.
2. Cache discipline: shared cache is RO via nix; per-project cache is RW; project workspace is for source only; use the env vars (12 of them) to redirect build artifacts.
3. Nix-first for new projects (per the project methodology).
4. OpenSpec workflow for any non-trivial change (proposal → design → spec → tasks → archive).
5. Cheatsheets are the source of truth — query via the MCP server, cite via `@cheatsheet path` in code.

## What Changes

- **MODIFIED** `images/default/config-overlay/opencode/instructions/methodology.md` becomes the orchestration index — short, points at the four sub-files.
- **NEW** `instructions/forge-discovery.md` — first-turn discovery sequence (inventory → cheatsheets → openspec changes); cites `forge-environment-discoverability` capability.
- **NEW** `instructions/cache-discipline.md` — the four-category path model + per-language env vars; cites `forge-cache-architecture`.
- **NEW** `instructions/nix-first.md` — Nix-flake recommendation for new projects; cites `forge-bake-nix`.
- **NEW** `instructions/openspec-workflow.md` — paragraph-per-step with worked example (when to scaffold, what each artifact is for, when to archive).
- **MODIFIED** `images/default/config-overlay/opencode/config.json` lists all five instruction files.

## Capabilities

### New Capabilities
- `forge-opencode-onboarding` — the methodology as a structured set of action-first instructions.

### Modified Capabilities
- `default-image`: opencode config-overlay gains 4 new instruction files.

## Impact

- 4 new markdown files under `images/default/config-overlay/opencode/instructions/`. Each ≤ 100 lines.
- `methodology.md` shrinks from 36 generic lines to ~15 lines that orchestrate the others.
- `config.json` adds 4 file references.
- Forge image rebuild required (config-overlay re-COPY).
- No tray changes. No prompts.

## Sources of Truth

- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — cited from cache-discipline.md.
- `cheatsheets/runtime/forge-shared-cache-via-nix.md` — cited from nix-first.md.
- `cheatsheets/agents/openspec.md` (DRAFT) — cited from openspec-workflow.md.
- `cheatsheets/runtime/cheatsheet-architecture-v2.md` — cited from forge-discovery.md.
