# Forge Continuous Enhancement — Automation Assessment

## Source

Drained from `plan.yaml` `future_intentions` item 2:
> "Enable iterative forge enhancement via the `/forge-continuous-enhancement` skill running inside the tillandsias repository."

## Current State

- `/forge-continuous-enhancement` skill exists at `.opencode/skills/forge-continuous-enhancement/SKILL.md`
- Skill registered in `methodology.yaml` (line 83-84)
- Skill successfully executed inside the forge during destructive E2E smoke test (see `plan/index.yaml` line 3678: `tillandsias . --opencode --prompt "Use the /forge-continuous-enhancement skill" -> forge_exit=0`)
- Related outer-loop `/diagnose-forge` skill runs via `big_pickle_template` in `plan.yaml`
- Forge diagnostics automation (step 21.5) and improvement loop (step 21.6) are completed
- Plan `step 58` (future-intentions-drain) is `ready` on `linux-next`

## Gap Analysis

| Aspect | Status |
|---|---|
| Skill file exists | ✅ |
| Registered in methodology | ✅ |
| Runs inside forge smoke | ✅ |
| Scheduled periodic execution | ❌ Not part of meta-orchestration loop |
| Autonomous proposal→implementation pipeline | ✅ Covered by `/diagnose-forge` + `/advance-work-from-plan` |
| Telemetry/logging feedback loop | ⚠️ Partial (relies on forge diagnostics annex) |

## Recommendation

The `/forge-continuous-enhancement` skill is an **inner-forge** skill: it runs *inside* the forge container to improve the forge itself. The outer orchestration already has:
- `/diagnose-forge` for extracting gaps from diagnostics output
- Meta-orchestration's e2e gates which exercise the forge launch path
- `/advance-work-from-plan` for claimed implementation work

**Gap**: No dedicated meta-orchestration cycle launches the forge specifically for continuous enhancement. The e2e smoke gate only exercises FCE as a side effect of a full build/install/reset cycle.

**Proposed action**: Either:
1. (Small) Add a lightweight FCE-only probe to the meta-orchestration worker drain: after a local-build e2e pass, launch `tillandsias . --opencode --prompt "Use the /forge-continuous-enhancement skill"` with a 10-min timeout and capture findings.
2. (Keep as-is) Since `big_pickle_template` already runs `/diagnose-forge` periodically, the outer improvement loop covers the same ground without an extra forge launch.

**Status**: ready for assignment
**Owner**: linux
**Capability tags**: [forge, opencode, containers, automation]
**Estimated effort**: 1h for option 1 (add probe), or mark superseded
