# Step 58 - Drain future intentions into planned tasks

- **Status**: ready
- **Owner host**: any
- **Branch**: linux-next
- **Depends on**: None
- **Specs**: None

## Goal

To process all orphaned tasks listed in `future_intentions` of `plan.yaml`, formalizing them into actionable plan steps and issues so builder hosts can pick them up.

## Context

The `plan.yaml` file currently contains several "future intentions" that have not been assigned a specific step or task. Builders need structured plan nodes to work on. This meta-step ensures each intention is properly planned.

## Tasks

- [x] Item 1 drained: "Move CURL installers and manual TAR/GZ manipulation in Containerfile to DNF." → `plan/issues/containerfile-dnf-migration-2026-06-20.md` (ready)
- [x] Item 2 drained: "Enable iterative forge enhancement via the `/forge-continuous-enhancement` skill." → `plan/issues/forge-continuous-enhancement-automation-2026-06-20.md` (ready)
- [x] Item 3 drained: "Ensure opencode and codex/claude permission files are highly permissive by default." → `plan/issues/forge-permission-files-audit-2026-06-20.md` (done — already fully YOLO mode, no code changes needed)
- [x] Drain next item from `future_intentions` in `plan.yaml`.
- [x] Convert each drained item into its own issue (e.g., inside `plan/issues/`) and its corresponding step in `plan/index.yaml` and `plan/steps/`.
- [x] Elaborate on the issue, expanding on what needs to be done.
- [x] **Important**: Where architectural decisions are required, formalize these as requirements to have discussions with "The Tlatoāni" for approval. Much of the work is self-evident to create tasks from it, but architecture choices need approval.
- [x] Remove the drained item from `future_intentions` once it has been fully formalized into the `./plan`.
- [x] Items 1-7 drained; no orphaned `future_intentions` remain in `plan.yaml`.

## Progress

- 2026-06-20T01:45Z (linux-macuahuitl-big-pickle): Drained item 1 — created `plan/issues/containerfile-dnf-migration-2026-06-20.md` with full audit, feasibility analysis, and implementation plan. Removed from `future_intentions`.
- 2026-06-20T02:37Z (linux-macuahuitl-big-pickle): Drained item 2 — created `plan/issues/forge-continuous-enhancement-automation-2026-06-20.md` with gap analysis and recommendation. Removed from `future_intentions`.
- 2026-06-20T03:24Z (linux-tlatoani-big-pickle): Drained item 3 — created `plan/issues/forge-permission-files-audit-2026-06-20.md` confirming all agents (opencode, codex, claude, gemini) already operate in fully permissive YOLO mode via `"permission": "allow"` config and `--dangerously-skip-permissions` / equivalent flags. Removed from `future_intentions`.
- 2026-06-20T04:13Z (linux-tlatoani-big-pickle): Drained item 4 — created `plan/issues/forge-build-telemetry-2026-06-20.md` with full instrumentation gap analysis, three-slice implementation plan, and Podman JSON progress recommendation. Removed from `future_intentions`, added to `drained_items`.
- 2026-06-20T05:10Z (linux-tlatoani-big-pickle): Implemented containerfile-dnf-migration slice 1 — migrated wasmtime from curl+tar to microdnf install wasmtime. Scope correction: buf already absent from Containerfile, ollama intentionally avoids DNF (GPU bloat). Commit `7293c902`.
- 2026-06-20T05:16Z (linux-tlatoani-big-pickle): Drained items 5-6 (tellme + forge-expert) — updated `plan/issues/tellme-discoverability-and-forge-expert-2026-06-12.md` with structured gap analysis, 4-slice implementation plan, and acceptance criteria. Removed from `future_intentions`, added to `drained_items`.
- 2026-06-20T05:44Z (linux-macuahuitl-codex): Drained item 7 (Windows/macOS feature parity) — expanded `plan/issues/windows-macos-feature-parity-2026-06-12.md` into a structured cross-host parity packet with blocker closure, launch-route parity, menu truth, and e2e acceptance waves. Removed the last orphan from `future_intentions`, added to `drained_items`.
