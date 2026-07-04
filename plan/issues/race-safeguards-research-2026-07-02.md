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
