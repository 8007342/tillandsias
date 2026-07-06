# Race safeguards research — concurrent launches, lifecycle races, shared-container churn

- **Date**: 2026-07-02
- **Host**: windows (windows-next)
- **Status**: research inventory — feeds orders 151–154
- **Operator directive**: "users racing events" is a valid future use. Audit the implementation
  for race safeguards everywhere: concurrent launches of the app, multiple container launches,
  quit/relaunch cycles, etc.

## Incidents observed live (2026-07-02 windows e2e)

These are not hypothetical — each happened during one afternoon of interactive use:

| # | Race | Observed effect |
|---|------|-----------------|
| I1 | Tray **Quit → relaunch within seconds**. Quit drains via `wsl --terminate`; the relaunch's provisioning "start poke" ran while the WSL utility VM was mid-teardown. | `wsl start poke exited 0xffffffff`, then the whole WSL service wedged: `WSL/Service/E_UNEXPECTED` on every `wsl.exe` call until `wsl --shutdown`. Tray stuck in Failed. |
| I2 | **Vault lease acquire vs proxy dependency**: `RemoteVaultLease::acquire` can rebuild + recreate the Vault container (image source digest moved), which rotates TLS secrets and tears the squid proxy down — while the flow that acquired the lease is about to launch a container that needs the proxy. | Clone container died with `Could not resolve proxy: proxy`. Fixed tactically by calling `ensure_proxy_running` AFTER the lease acquire (commit fef437fa), but the underlying "ensure-X may destroy Y mid-flow" pattern is unaudited. |
| I3 | **Vault health-wait vs container restart**: `podman wait --condition=healthy tillandsias-vault` returned `container is stopped` (treated as Permanent failure) during the vault container's own restart window; vault was healthy 30s later. | Whole launch flow aborted spuriously. |
| I4 | **VM terminate vs in-flight background work**: tray Quit killed an in-VM `cargo build` (and would kill image builds) with no warning; transient systemd units vanish. | Silent loss of long-running work; monitors misread stale artifacts as success. |
| I5 | **squid Exited(139)** left the VM degraded for ~22h because nothing restarts shared containers; every gh-dependent flow failed quietly until a manual restart. | Self-heal added to the gh helpers (fef437fa) — but see R6: self-heal can now race the drain path. |

## Race surfaces to audit (inventory)

### Host side (Windows tray / host-shell; macOS analog applies)

- **R1 — Quit/relaunch lifecycle (I1)**: the start poke needs retry-with-backoff and a
  "WSL service sane?" preflight; the drain path should be observable (lockfile/event) so a
  relaunching instance waits for teardown to finish instead of racing it. Recovery path for
  `E_UNEXPECTED` (guided `wsl --shutdown`) should be automatic or one-click.
- **R2 — Concurrent tray instances**: the headless has a `SingletonGuard`; does the Windows
  tray? Two instances would double-poll the wire, double-deliver credentials, and race
  provisioning. (Installer only does `Stop-Process` best-effort.)
- **R3 — Concurrent PTY launches from one tray**: two project clicks (or double-click) spawn
  two orchestrated `--cloud` flows in parallel. See R5 — their cleanup/bring-up phases
  destroy each other's shared containers.

### In-VM (headless / enclave)

- **R4 — ensure_* idempotency under concurrency**: `ensure_proxy_running`,
  `ensure_vault_running`, `ensure_enclave_network`, `ensure_versioned_images` are all
  check-then-act (TOCTOU). Two concurrent callers both see "not running" → both
  `podman run --name tillandsias-proxy` → name conflict; both `podman build` the same tag →
  wasted duplicate builds. Need per-resource advisory locks (flock on /run/tillandsias/…)
  or a single-writer supervisor.
- **R5 — cleanup_stack_containers vs shared containers**: every `run_*_mode` launch removes
  `tillandsias-proxy` and `tillandsias-inference` (SHARED) plus the per-project git/forge.
  A second concurrent (or merely subsequent-while-first-is-running) launch kills the first
  session's proxy/inference out from under it — this is also I2's root pattern. Shared
  containers need refcounting or "ensure, never cleanup" semantics; only per-project
  containers should be cleaned per-launch.
- **R6 — drain vs self-heal**: the gh helpers now resurrect a dead proxy. During
  VmShutdown/drain, a 30s status/login poll could re-create containers the drain just
  stopped. Self-heal must consult the VmPhase (skip when Draining/Stopping).
- **R7 — vault lifecycle (I2, I3)**: recreating vault must be mutually exclusive with lease
  holders (rwlock semantics: leases take read, recreate takes write), and the health wait
  must tolerate the restart window (retry "container is stopped" for a bounded period).
- **R8 — clone target collisions**: two `--cloud owner/repo` resolves for the same repo race
  `target.exists()` → two clones into one directory. Clone into a temp dir + atomic rename,
  or flock the target.
- **R9 — first-boot fetch vs update**: `fetch-headless.sh` exits if the binary exists but a
  concurrent manual `install` over a running binary can hit ETXTBSY / partial-write; use
  install-to-temp + rename (install(1) already does, but the fetch script curls directly to
  DEST).

## Suggested safeguard vocabulary (for the implementation packets)

1. **Advisory file locks** per shared resource under `/run/tillandsias/locks/` (flock, held
   across check+act) — cheap, works across processes, no daemon needed.
2. **Refcount or supervisor ownership for shared containers** (proxy, inference, router,
   vault): launches take a reference; cleanup only removes per-project containers; a
   supervisor (the vsock headless service is the natural owner) reconciles shared ones.
3. **Phase-aware side effects**: anything that (re)creates containers checks VmPhase and
   refuses during Draining/Stopping.
4. **Retry-with-backoff + classify-transient** at every wait: `wsl` start pokes,
   `podman wait --condition=healthy`, network ensure calls.
5. **Atomic filesystem operations** for clone/install targets (temp + rename).
6. **Litmus per race**: each fixed race gets a litmus that provokes the concurrency
   (parallel invocations) and asserts the safeguard.

## Relation to existing work

- Order 150 (wire-tray-cloud-attach) fixed I2/I5 tactically; R4–R7 generalize.
- Orders 142–149 (observable streams) replace polling with push — R6's phase-awareness
  should be designed into the push refactor rather than bolted onto polls.
- The headless `SingletonGuard` (spec:singleton-guard) is prior art for R2.

## Disposition — ratified 2026-07-06 (order 160, agent linux-ccr-fable5-20260706T1734Z)

Every disposition below was re-verified against the tree at `linux-next@4835931e`
(file:line references are to that state), not against the 2026-07-02 snapshot.
Verdict grammar per item: `adopt:<safeguard>` (implementation packet owns it),
`partial:<what-remains>` (some mitigation landed since the inventory), or
`accept-as-is:<rationale>`.

### Shared-container ownership model (headline decision)

**Decided: ensure-only + supervisor reconciliation. Refcounting is REJECTED.**

- Shared containers (`tillandsias-proxy`, `tillandsias-inference`, vault,
  router) are never removed by per-launch cleanup; only per-project containers
  (`tillandsias-git-<p>`, `tillandsias-<p>-forge`, `tillandsias-browser-<p>`)
  are cleaned per launch.
- The prior art already on the tree — `cleanup_shared_stack_if_no_running_forge`
  (`crates/tillandsias-headless/src/main.rs:2956`) — IS this model: shared
  teardown only when zero forge containers remain running. The impl packet's
  job is convergence, not invention (see R5).
- The vsock headless service is the supervising owner: it is the only component
  allowed to reconcile (recreate/heal) shared containers, and every reconcile
  consults `VmPhase` first (see R6).
- Refcount rejected because count state must itself survive crashes to be
  correct — a crashed launch that never decrements wedges the count, and the
  "zero running forges" probe already derives the same fact from live podman
  state with no bookkeeping to corrupt.

### Per-surface dispositions

- **R1 (quit/relaunch WSL lifecycle)** — `partial:drain-observability+recovery`.
  Retry-with-backoff now exists on the ready-connect path:
  `try_connect_until_ready` bounds each attempt at 30 s and backs off 5 s
  (`crates/tillandsias-windows-tray/src/wsl_lifecycle.rs:680` doc + loop).
  Still missing: an observable drain marker so a relaunch waits for teardown
  instead of racing it, a "WSL service sane?" preflight, and automatic/one-click
  `E_UNEXPECTED` → `wsl --shutdown` recovery. Owner: host-lifecycle-race-safeguards.
- **R2 (concurrent tray instances)** — `adopt:single-instance-guard`.
  Verified absent: no CreateMutex/singleton in
  `crates/tillandsias-windows-tray/src/` or `crates/tillandsias-macos-tray/src/`
  (only unrelated AppKit-singleton SAFETY comments). Prior art to mirror:
  `crates/tillandsias-core/src/singleton.rs` (headless `SingletonGuard`).
  Owner: host-lifecycle-race-safeguards; macOS analog explicitly in scope.
- **R3 (concurrent PTY launches)** — `adopt:launch-serialization`.
  `PROVISIONING_ACTIVE` (`notify_icon.rs:1921`) guards only provisioning
  retriggers; project-click PTY launches have no equivalent guard. Adopt the
  same swap-true-or-ignore pattern (or a queue) per project.
  Owner: host-lifecycle-race-safeguards.
- **R4 (ensure_* TOCTOU)** — `adopt:advisory-flock-per-resource`.
  Verified still check-then-act with zero locking: `ensure_proxy_running`
  (`main.rs:2069`) probes `container_running`, then `podman rm --ignore`, then
  `podman run --name` — two concurrent callers still race to the name conflict.
  No `flock` usage exists anywhere in `crates/tillandsias-headless/src/`.
  Adopt flocks under `/run/tillandsias/locks/<resource>` held across check+act.
  Owner: enclave-container-lifecycle-races.
- **R5 (cleanup vs shared containers)** — `partial:converge-remaining-sites`.
  The forge-aware guard exists and is used at 3 sites (`main.rs:4467, 5831,
  7495`), but `cleanup_stack_containers` — which unconditionally removes the
  SHARED proxy + inference (`main.rs:2942-2954`) — is still called directly
  from `run_status_check` (`main.rs:4415`), `run_opencode_mode`
  (`main.rs:5713`), `monitor_and_cleanup_browser` (`main.rs:6761`), and one
  further launch path (`main.rs:7157`). Slice: split shared vs per-project
  removal into two functions; route every call site through the guard; the
  unconditional shared-removal function must not survive the refactor.
  Owner: enclave-container-lifecycle-races.
- **R6 (drain vs self-heal)** — `adopt:phase-gated-side-effects`.
  Verified unmitigated: the clone path re-ensures the proxy
  (`remote_projects.rs:571` → `ensure_proxy_running`) with no `VmPhase`
  consultation; phase state lives only in the vsock `ServerState`
  (`vsock_server.rs:119`). Adopt: container-(re)creating helpers accept a
  phase probe and refuse during `Draining`/`Stopping`; standalone CLI paths
  (no server) pass a permissive probe. Owner: enclave-container-lifecycle-races.
- **R7 (vault lifecycle)** — `adopt:rwlock+transient-classified-wait`.
  Verified unmitigated on both halves: (a) `RemoteVaultLease::acquire`
  (`remote_projects.rs:176`) calls `ensure_vault_running` + mints an AppRole
  lease with no mutual exclusion against a concurrent vault recreate — the I2
  ordering fix (proxy ensured AFTER lease, `remote_projects.rs:565-571`) is
  tactical only; (b) `PodmanClient::wait_healthy` (`client.rs:964`) maps every
  failure to `CommandFailure` with no transient window — I3's "container is
  stopped" during a restart is still terminal. Adopt: leases take read /
  recreate takes write on a vault lifecycle lock; wait_healthy retries
  "container is stopped" AND "no such container" (Silverblue evidence:
  `vault_bootstrap.rs:1488`) for a bounded window.
  Owner: enclave-container-lifecycle-races.
- **R8 (clone target collisions)** — `adopt:temp+atomic-rename`.
  Verified unmitigated: `clone_project_from_github_with_debug`
  (`remote_projects.rs:531`) clones straight into the final target; no lock,
  no temp dir. Adopt clone-into-`<root>/.tmp-<repo>-<nonce>` + `rename` (same
  mount, 9p/drvfs-safe). Owner: checkout-and-fetch-atomicity.
- **R9 (fetch/install atomicity)** — `partial:two-embedded-scripts-remain`.
  The canonical guest bootstrap is FIXED: `images/vm/bootstrap/20-tillandsias.sh`
  curls to `$TMP` then `install -D` (unlink+create avoids ETXTBSY). But both
  host-embedded copies of `fetch-headless.sh` still curl `--output "$DEST"`
  directly onto the live path: `wsl_lifecycle.rs:368` (windows write scope) and
  `vz.rs:460` (macos write scope). Slice per owning host; consider deduping the
  script into one shared constant so it cannot drift three ways again.
  Owner: checkout-and-fetch-atomicity (linux script done; windows/macos slices
  to host-lifecycle owners per write scope).

### Impl packet scope confirmation (exit criterion 3)

The inventory's "orders 152-154" pointer is STALE — order numbers collided when
the stream packets were filed. The actual implementation packets are:

- `host-lifecycle-race-safeguards` (order 161) — CONFIRMED as scoped, plus:
  R3 serialization explicitly includes the same-project double-click case, and
  the R2 guard must ship on BOTH windows and macos trays.
- `enclave-container-lifecycle-races` (order 162) — CONFIRMED, amended: R5 is
  convergence of the 4 remaining direct `cleanup_stack_containers` call sites
  onto the already-landed forge-aware guard (not a from-scratch design); R7's
  transient window must classify "no such container" as transient too.
- `checkout-and-fetch-atomicity` (order 163) — CONFIRMED, amended: R9's linux
  bootstrap slice is already done; residual is the two host-embedded fetch
  scripts (windows `wsl_lifecycle.rs:368`, macos `vz.rs:460`) plus script dedup.

Safeguard vocabulary items 1-6 (advisory flocks, ensure-only ownership,
phase-aware side effects, retry-with-backoff+classify-transient, atomic fs ops,
one provoking litmus per fixed race) are ratified unchanged.

## Implementation checkpoint — macOS R9 slice 2026-07-06

macOS residual R9 is complete on `osx-next@3e1637ad`: the VZ cloud-init
`fetch-headless.sh` network fallback now downloads to `mktemp`, cleans it with a
trap, and `install -D -m 0755`s into `/usr/local/bin/tillandsias-headless`
instead of curling directly onto the live binary. Added
`vz_fetch_script_installs_download_via_temp_file` to pin the behavior. Evidence:
`cargo test -p tillandsias-vm-layer` 30/30 and `./build.sh --check` passed on
macOS. Windows residual R9 (`wsl_lifecycle.rs`) remains for the Windows owner.
