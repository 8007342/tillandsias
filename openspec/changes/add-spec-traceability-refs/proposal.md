## Why

No way to trace backwards from code or logs to the spec that justified a decision. Troubleshooting agents guess which spec applies. When code is modified, no way to know which specs are impacted. Adding lightweight `@trace` references and structured `spec` log fields completes the observability chain: logs → code → spec → ground truth.

## What Changes

- Add `// @trace spec:<capability>` comments to ~15 module headers and ~20 critical code blocks
- Add `# @trace spec:<capability>` comments to key bash scripts
- Add `spec` field to tracing spans on ~8 instrumented functions
- Add `spec` field to ~15 key `info!`/`error!` log events
- Patch OpenSpec skills to instruct agents to add traces during implementation

## Capabilities

### New Capabilities

- `spec-traceability`: Lightweight, CRDT-like references linking code and logs back to specs and knowledge cheatsheets

### Modified Capabilities

(none — this is additive, no existing behavior changes)

## Impact

- `src-tauri/src/*.rs` — comment annotations and tracing field additions
- `crates/tillandsias-podman/src/*.rs` — comment annotations
- `crates/tillandsias-scanner/src/*.rs` — comment annotations
- `scripts/*.sh` — bash comment annotations
- `.claude/skills/openspec-apply-change/SKILL.md` — agent instruction patch
