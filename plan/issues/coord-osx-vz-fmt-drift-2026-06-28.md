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

## Update 2026-06-28T23:xx — blocker is now broader than fmt; converge osx-next first

`origin/osx-next` advanced to `0604acff` and has **diverged** from `linux-next`.
A re-attempted coordinator merge now hits real conflicts beyond the fmt drift:

- `crates/tillandsias-headless/src/main.rs` — 1 conflict hunk (osx lacks the
  order-120 `ensure_proxy_running` cleanup block; resolves "keep linux"),
- `plan/index.yaml` — **8 conflict regions** (both branches added packets; osx
  carries *older copies* of linux-authored issues with stale statuses),
- add/add on `init-dns-systemd-resolved`, `legacy-claw-image-orphan-cleanup`,
  `container-dependency-graph-research` (osx has older copies; linux is authoritative).

Force-resolving an 8-region ledger merge risks corrupting `plan/index.yaml` and
losing osx's genuinely-new work (`macos-tray-parity-gaps-2026-06-28.md`,
`smoke-curl-install-e2e-macos-...`). Aborted again — **do not force it.**

### Correct path (osx terminal does this): converge onto linux-next first

```bash
git checkout osx-next
git fetch origin --prune
git merge origin/linux-next        # bring in P0 fixes + the guest_transport facade
# resolve in osx's favor ONLY for osx-owned files (macos-tray, vm-layer vz/wsl/transport_macos);
# take linux's version for shared linux files (main.rs) and the plan ledger
#   (plan/index.yaml, the duplicated plan/issues/*) — linux is authoritative there.
cargo fmt --all                    # dissolves the vz.rs drift in the same pass
./build.sh --check
git commit && git push origin osx-next
```

After osx converges, the linux coordinator merge of osx-next is clean and brings
in the macOS work + `macos-tray-parity-gaps` with no ledger conflicts.

### Why this direction

linux-next is the integration trunk and carries the authoritative plan ledger +
the four-P0 credential fixes + the new transport facade (orders 123/124). Pulling
those onto osx-next (rather than pushing osx's stale ledger copies onto linux)
keeps the ledger single-authoritative and gives osx the facade it needs for
order 126 anyway.

## Note

Recurring sibling-fmt-drift + branch-divergence pattern. Bar-raise candidates
(not enabled): osx-side pre-commit `cargo fmt --check`; and osx merging
linux-next more frequently so its plan-ledger copies don't drift into add/add
conflicts (the $D_{max}=5$ drift rule in advance-work-from-plan exists for exactly
this).
