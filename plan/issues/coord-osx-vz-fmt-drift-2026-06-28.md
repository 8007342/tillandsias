# Coord: osx-next vz.rs rustfmt drift blocks linux-next integration

**Status:** `blocked` (owner: osx terminal)
**Filed by:** linux (coordinator) 2026-06-28
**Kind:** coordination
**Trace:** multi-host integration

## What

A coordinator merge of `origin/osx-next` into `linux-next` is **clean** (no
content conflicts — the shared P0 fixes reconciled via main's ancestry) and
brings in the genuinely-new macOS work:

- `crates/tillandsias-macos-tray/src/diagnose.rs`, `main.rs`
- `crates/tillandsias-vm-layer/src/vsock_exec.rs`, `vz.rs`
- `plan/issues/osx-next-work-queue-2026-05-25.md`
- `plan/issues/smoke-curl-install-e2e-macos-v0.3.260626.5-2026-06-26.md`

BUT it fails `./build.sh --check` on **rustfmt drift in osx-owned
`crates/tillandsias-vm-layer/src/vz.rs`** (2 spots, ~lines 1598 and 1616 — a
multi-line `.open_vsock_stream_current_thread(...)` call rustfmt wants
collapsed). Per the standing rule, linux does **not** reformat sibling-owned
scopes (it churns osx ownership and creates cross-host conflicts), so the merge
was aborted rather than integrated with a linux-side reformat.

## Smallest next action (osx terminal)

```bash
git checkout osx-next
cargo fmt --all
git add crates/tillandsias-vm-layer/src/vz.rs
git commit -m "style(vm-layer): cargo fmt vz.rs (unblock linux integration)"
git push origin osx-next
```

Then linux re-runs the coordinator merge and integrates the macOS work.

## Verifiable closure

`cargo fmt --all --check` exits 0 on `origin/osx-next` HEAD. Until then, the
macOS work cannot land on `linux-next` without breaking the shared `--check`
gate.

## Note

This is the recurring sibling-fmt-drift pattern (see the standing coord rule).
Candidate hardening: an osx-side pre-commit `cargo fmt --check` so drift never
reaches a pushed commit. Filed as a bar-raise candidate, not enabled.
