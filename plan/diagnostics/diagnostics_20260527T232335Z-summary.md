# Forge Diagnostics Summary — 2026-05-27T23:23:35Z

## Metadata

- **Source log**: `/tmp/tillandsias-runtime-litmus-20260527T231940Z-b06a5997-1e20d6d0-b06a5997/target/forge-diagnostics/diagnostics_20260527T232335Z.log`
- **Runtime log**: `plan/localwork/runtime-litmus/20260527T231940Z-b06a5997-1e20d6d0-b06a5997/run.log`
- **Forge version**: unknown
- **Completeness**: 0 / 0 checks passed (0%)

## Result

The diagnostics annex created two raw log files, but both were zero bytes. The
full runtime litmus reached `tillandsias . --opencode --diagnostics --prompt`
and then failed before an agent response could be captured.

## Failure

- `crates/tillandsias-headless/src/vault_bootstrap.rs:205`
- Panic: `Cannot start a runtime from within a runtime`
- Command phase: `tillandsias . --opencode --diagnostics --prompt "$LITMUS_PROMPT"`
- Exit code: 101

## Recommended Actions

- Fix the nested-runtime panic in the diagnostics/OpenCode launch path before
  treating forge completeness output as meaningful.
- After the panic is fixed, rerun the full installed runtime litmus on current
  `origin/linux-next` and re-distill the first non-empty diagnostics log.
