# Linux Audit of Recent Agent Work — 2026-07-09

**Date:** 2026-07-09
**Classification:** audit (capture per meta-orchestration reduction engine)
**Host:** linux (macuahuitl, mutable)
**Agent:** linux-macuahuitl-fable5-20260709T1923Z
**Scope:** commits since 2026-07-07 on linux-next; plan/index.yaml lease/status
coherence; operator-directed ("agents are sometimes a bit off").

## Findings

### F1 — FIXED: unit tests mutated host container state (order 227/228 test debt)

`container_deps::tests::ensure_git_login_returns_up_gitloginready` invoked
`ensure_git_login(false)` and `real_satisfier_match_arms_cover_all_services`
looped `RealSatisfier::satisfy()` over ALL services. `RealSatisfier` dispatches
to the real `ensure_*` functions, so on a host with podman these unit tests
could create the enclave/egress networks, write the CA bundle, and start
Vault/proxy containers as a side effect of `cargo test`. On a pristine host
they mutate state; on a busy host they race live operations; on the forge they
silently exercise error paths. Both tests' own comments claimed they were
compile-time checks.

**Fix (this audit):** both tests reduced to genuine compile-time/rejection-arm
assertions (fn-pointer coercion typecheck; GitLogin-rejection only). Suite went
from 0.31s to 0.00s, confirming podman round-trips were happening.
Exhaustiveness of the satisfy match is already a compile error (no wildcard
arm), so the runtime loop added no coverage.

### F2 — FIXED: order-228 liveness probe ran blocking podman calls on async workers

The liveness task (`maybe_spawn_vsock_listener`, main.rs) called
`LivenessProbe::run_check()` directly inside `tokio::spawn`. `run_check` shells
out (`container_running`, `RealSatisfier::satisfy`) — blocking calls that could
stall a tokio worker for seconds while sharing the runtime with the vsock
listener. **Fix (this audit):** wrapped in `tokio::task::spawn_blocking`.

### F3 — OPEN: liveness probe re-ensure races user-initiated container operations

The probe auto-re-ensures Vault/Proxy every 30s during `VmPhase::Ready` with no
lock or lease coordination. Concurrent with a user login (vault lease held), a
`--init`, or the selective reset, the re-ensure can interleave create/start
calls. This is precisely the ready work in orders 232 (flock per resource), 233
(shared-cleanup guard), 234 (VmPhase consultation — partially honored: the
probe does gate on Ready), 235 (vault recreate mutex). The probe landing FIRST
inverts the intended order — the safeguards should be prioritized now.
**Action:** orders 232-235 elevated as next Linux implementation block after
the current audit packets.

### F4 — OPEN → order 252: launch paths bypass the dependency model

Order 229's drift litmus documents `ensure_enclave_for_project` and
`run_forge_agent_cli_mode` as known gaps (bypass container_deps). Filed as
shaped packet order 252 with an exit criterion of emptying the litmus gap
allowlist.

### F5 — RECONCILED: ledger lag between code and plan

- Order 122 (parent of 227/228/229) still `ready` although all five slices are
  done → folded to `done` with evidence.
- Order 237 `in_progress` with a lease that expired 2026-07-08T04:03Z → lease
  voided (operator-authorized sole-builder audit), status `ready`, residual
  scope stated (activate injected mirror gitconfig by default; auth research
  stays in order 238).
- Orders 230/231 `ready` while depends_on order 153 is not `done` → clarified
  with dependency_note: slice 1 of 153 (persistent listener + Subscribe +
  VmStatusPush broadcast) already landed in vsock_server.rs; LoginState /
  CloudProjects topics are SubscribeAck'd but never delivered — exactly the
  scope of 230/231. They are genuinely claimable.
- Leases with future expires_at on orders 228/229/242 belong to packets already
  `done` (completed events present) — implicitly released, no action.

### F6 — NOTE: duplicate `order:` numbers in plan/index.yaml

Orders 144, 160, 161, 196, 197, 201, 224 are each used by two or three
packets. `packet_id` is the stable ID so nothing breaks, but order-based
references in prose are ambiguous. Recommendation (not done here to avoid
cross-host churn): future packets take the next free number from the tail;
never renumber existing packets.

### F7 — FIXED: order-228 liveness task never aborted at listener shutdown

`maybe_spawn_vsock_listener` aborts advancer/watcher/events_monitor when the
listener exits, but the order-228 liveness task was left out — it outlived the
listener and kept polling during shutdown. Fixed in commit 744f4749 (both the
liveness task and the new order-230 login probe are now aborted with the
others).

### F8 — OPEN → order 254: listen-vsock feature combo is never linted/tested in CI

`./build.sh --check` clippies default features only. Running clippy + tests
with `--features listen-vsock` (2026-07-09) surfaced 13 accumulated warnings
and 2 pty_handler tests that drifted from their implementations (child_env's
enclave NO_PROXY injection; the order-141 exec allowlist rejecting the test's
`/bin/sh -c` argv). Shaped as order 254.

### F9 — technique: piped build gates false-green (2026-07-09 meta-orch cycle)

Twice this session `./build.sh --check 2>&1 | tail -1` reported a green-looking
tail while the real exit was 101, and once a warm-cache rerun inverted the
verdict right after a source merge — the windows-tray collapsible-if reached
`origin/linux-next` before a clean rerun caught it (mediated in 034c31f6).
Rule captured: integration-gate verdicts must come from the command's OWN exit
code captured explicitly (`cmd > log 2>&1; echo exit=$?`), never from a piped
tail, and the post-merge gate run must not share a cargo invocation with a
concurrent fmt/test. (Capture per the reduction-engine contract; technique
note, no packet — the gate snippet in the skill already propagates exit codes
when not piped.)

## Verification

- `./build.sh --check` — clippy + check pass after F1/F2 fixes.
- `cargo test -p tillandsias-headless container_deps` — 15/15 pass (0.00s).
- Sibling integration state: `origin/osx-next` and `origin/windows-next` are
  both ancestors of `origin/linux-next` (fully integrated; no merge duty this
  cycle).
