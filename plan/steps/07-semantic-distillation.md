# Step 7: Semantic Distillation and Tombstone Sweep

Status: COMPLETED

## Summary

Completed the final distillation pass to retire stale specs and mark historical implementation references with tombstones.

## Completed Tasks

### Task 1: Spec-Empty-Bindings Distillation

Identified and marked deprecated specs with empty litmus bindings as obsolete with replacement references:

- `agent-cheatsheets` → superseded by `cheatsheet-source-layer`
- `browser-isolation-launcher` → superseded by `browser-isolation-core`
- `browser-mcp-server` → superseded by `host-browser-mcp`
- `build-lock` → superseded by `build-script-architecture`
- `cheatsheet-mcp-server` → superseded by `cheatsheet-tooling`
- `cheatsheet-methodology-evolution` → superseded by `cheatsheet-source-layer`
- `direct-podman-calls` → superseded by `podman-orchestration`
- `enforce-trace-presence` → superseded by `methodology-accountability`
- `fix-podman-machine-host-aliases` → obsolete (cross-platform deferred)
- `fix-windows-extended-path` → obsolete (cross-platform deferred)
- `forge-cache-architecture` → superseded by `forge-cache-dual`

Artifact: `openspec/litmus-bindings.yaml`

### Task 2: History-Only Specs Distillation

Identified and marked orphaned active specs with no code traces (src-tauri-era):

- `singleton-guard` - Lock file enforcement for single-instance tray mode (src-tauri/src/singleton.rs removed)
- `tray-cli-coexistence` - Tray and CLI coexistence logic (src-tauri removed)
- `tray-projects-rename` - Project renaming in tray UI (src-tauri removed)
- `update-system` - System update logic (src-tauri removed)

All marked as `obsolete` with `tombstone: obsolete:src-tauri-deferred`.

Artifact: `openspec/litmus-bindings.yaml`

### Task 3: Event Register Finalization

Updated methodology event registry to mark event 008 (active-contract-trace-sweep) as distilled:

- Distilled into: `openspec/litmus-bindings.yaml`, `TRACES.md`
- Resolution: Deprecated specs with empty bindings now marked obsolete. Src-tauri-era orphaned specs identified and obsoleted. Trace index regenerated with 100% coverage for active specs.

Artifact: `methodology/event/index.yaml`

### Task 4: Frontier Pruning

Updated plan state:

- Step 7 (semantic-distillation-sweep): marked as `completed`
- Step 8 (implementation-gaps-backlog): promoted to `ready` (all dependencies complete)
- All 4 distillation tasks marked as `completed`

Artifact: `plan/index.yaml`

## Exit Criteria Met

✓ All stale specs are obsoleted or tombstoned with replacement references

✓ Only intentional implementation gaps remain active (74 active specs with traces or justified boundaries)

✓ Trace index regenerated with 100% coverage for active implementations

✓ Methodology event intake finalized and resolved

✓ Plan frontier advanced to step 8

## Verification

```bash
# Count obsolete specs with tombstones
grep -c "tombstone:" openspec/litmus-bindings.yaml

# Verify trace coverage for active specs
./scripts/generate-traces.sh  # 100% coverage achieved

# Confirm event distillation
grep "status: distilled" methodology/event/index.yaml | wc -l
```

## Next Steps

Step 8 (implementation-gaps-backlog) is now ready for execution. This step will identify remaining implementation gaps across the active 74 specs and prepare focused implementation tasks.

Key branches:
- Browser isolation and secure OpenCode Web implementation
- Tray lifecycle, init path, and cache semantics
- Onboarding, discoverability, and repo bootstrap docs
- Observability, logging, and evidence surfaces

## References

- Event 008: `methodology/event/008-active-contract-trace-sweep.yaml`
- Bindings registry: `openspec/litmus-bindings.yaml`
- Trace index: `TRACES.md`
- Plan: `plan/index.yaml`
