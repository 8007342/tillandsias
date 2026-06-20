# Forge Discoverability via "tellme" and Forge-Expert Inference Model

## Source

Drained from `plan.yaml` `future_intentions` items 5 and 6:
> "Implement a global `tellme` discoverability script: `tellme about [...]` for static cheatsheets, and `tellme howto [...]` using a <1B inference model ('forge-expert')."
> "Train 'forge-expert' at launch time and retrain on commits to answer questions with no tool usage."

Trace: plan.yaml, plan/steps/58-future-intentions-drain.md, plan/issues/tellme-discoverability-and-forge-expert-2026-06-12.md

Status: ready
Owner host: linux
Capability tags: [forge, shell, discoverability, inference, docs]
Dependencies: none

## Current State

The forge environment has rich discoverability infrastructure but no unified entry point:
- **Cheatsheets**: 90+ cheatsheets in `cheatsheets/` covering languages, tools, build systems, web, security, UX, data, algorithms
- **INDEX.md**: `cheatsheets/INDEX.md` provides a categorized index
- **help.sh**: `scripts/help.sh` exists but provides basic usage info
- **Shell tools**: `forge-shell-tools` spec documents terminal tools but no `tellme`-style command
- **Welcome banner**: `forge-welcome.sh` advertises discoverability CLIs but doesn't implement `tellme`
- **Existing issue**: This file was created 2026-06-12 with high-level requirements but no implementation plan

### Gap Analysis

| Aspect | Status |
|---|---|
| Static cheatsheet lookup (`tellme about`) | ✅ implemented |
| Dynamic query answering (`tellme howto`) | ✅ implemented (RAG over cheatsheets via Ollama) |
| Forge-expert <1B model training pipeline | ❌ not implemented (Slice 3) |
| Launch-time model training | ❌ not implemented |
| Commit-triggered retraining | ❌ not implemented |
| Dependency list exposure | ✅ implemented |
| Existing cheatsheets (90+) | ✅ ready to be consumed |
| Forge skill mapping | ✅ skills are already copied into forge image |

## Recommendation

The `tellme` and `forge-expert` initiatives are closely related but decomposable into independent slices:

### Slice 1: `tellme about` shell script (static cheatsheet lookup) [COMPLETED]
- Create `images/default/cli/tellme` (or `scripts/tellme.sh` installed to PATH)
- `tellme about <topic>` searches `cheatsheets/INDEX.md` and returns matching sections
- `tellme about --list` shows all categories
- `tellme about <topic> --full` shows full cheatsheet content
- Include forge dependency list reference
- Mark with `@trace spec:forge-environment-discoverability`

### Slice 2: `tellme howto` with local inference [COMPLETED]
- Requires forge-expert model (Slice 3) or a simpler fallback:
  - Query ollama in the forge with RAG over cheatsheets
  - `tellme howto "<query>"` → `ollama run qwen2.5:0.5b "<context> <query>"`

### Slice 3: Forge-expert model training pipeline
- Train a <1B model (e.g., Qwen2.5-0.5B fine-tune) at launch time
- Seed with: cheatsheets, project README, git log summaries, dependency lists
- Retrain on commit via git hook or post-merge CI step

### Slice 4: Install tellme into forge Containerfile [COMPLETED]
- Add COPY + install step in `images/default/Containerfile`
- Welcome banner should advertise `tellme`

## Status

**This issue**: partially resolved — Slices 1, 2, and 4 have been implemented and validated against the discoverability litmus test suite. Only Slice 3 (dedicated fine-tuning pipeline for forge-expert) remains open.

## Acceptance Evidence (Slice 1 & 2)

- `tellme about <topic>` returns matching cheatsheet entries from INDEX.md
- `tellme about --list` enumerates all categories
- `tellme howto "<query>"` performs keyword search over cheatsheets and queries local Ollama using RAG
- Script exists and is executable in the forge PATH (installed via Containerfile and symlinked to `/usr/local/bin/tellme`)
- `@trace spec:forge-environment-discoverability` annotation present
- No regression in existing discoverability CLIs or welcome banner (all 107 litmus tests pass)
