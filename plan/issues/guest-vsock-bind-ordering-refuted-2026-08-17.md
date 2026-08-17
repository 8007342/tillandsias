# 795-jeym refuted: the guest daemon already binds before its provisioning work

Classification: `research/`
Host: windows (yolanda), branch `windows-next`
Date: 2026-08-17
Order: 795-jeym (mechanism refuted), children 798-q4m9 / 798-vxj5 / 798-emje

## Claim under test

795-jeym, p1, release-blocking:

> The guest daemon does its long provisioning work BEFORE it binds the vsock
> listener, which is the only defect still producing different verdicts on
> identical artifact + host.

It asked for the bind to be moved ahead of provisioning and for six accreted
exceptions to be deleted.

**The claim is false.** The bind is already first, by a wide margin, and five of
the six exceptions are load-bearing for reasons that have nothing to do with
bind ordering.

## Where the claim came from

Not from the code. From a comment. `crates/tillandsias-windows-tray/src/wsl_lifecycle.rs`
carried 757-4hdt's FIRST diagnosis:

> on a COLD first boot the daemon bootstraps Vault and builds the proxy image
> -- minutes of work, logged as "this may take several minutes" -- before it
> binds 42420

757-4hdt itself superseded that diagnosis two events later, when it found the
actual cause (`vsock_loopback` not loaded, so a CID-1 probe cannot observe a
listener that IS bound). The superseded text stayed in the comment, was read as
current, and a p1 release-blocker was filed to implement it. The comment is
corrected in the same commit as this issue.

## Evidence A — source

`run_headless_async` (`crates/tillandsias-headless/src/main.rs:13666-13750`)
reaches `maybe_spawn_vsock_listener` through non-blocking calls only:
`require_headless_service_account` (env reads + `is_dir`),
`install_shutdown_signal_handlers` (two `signal_hook::flag::register`),
`load_config` (a stub whose body is `Ok(())`, and the generated unit passes no
config path anyway), and five `tokio::spawn` calls that genuinely defer.
`spawn_metrics_sampler` / `spawn_metrics_http_server` do their `TcpListener::bind`
INSIDE the spawned block, not inline.

Inside `maybe_spawn_vsock_listener` (main.rs:13209-13608) there is **no `.await`
at all** between the start of the task and
`vsock_server::run_vsock_listener(...).await` at main.rs:13581. Every
intermediate item — advancer, watcher, liveness, login_probe,
local_projects_rescan, events_monitor, udp_monitor — is a bare `tokio::spawn`.
`VmStateHandle::new()` is four `broadcast::channel` allocations.

The daemon **never** bootstraps Vault or builds an image on its own startup
path. Every `ensure_vault_running` call site is either a CLI lane (`--init`
main.rs:708, `--reset-guest` main.rs:7459, `--opencode` main.rs:10418,
`--opencode-web` main.rs:11521), or a control-wire request handler
(vsock_server.rs:1464, strictly after bind AND after a host connect). The path
that does build the proxy image is `LivenessProbe::run_check` →
`RealSatisfier::satisfy` → `ensure_proxy_running` (container_deps.rs:309/318),
reached from the liveness task, which is gated on `VmPhase::Ready` (phase starts
`Starting`) and dispatched via `spawn_blocking`. It cannot precede the bind.

## Evidence B — four genuine cold boots

Runtime distro `tillandsias` terminated and restarted; timings from systemd's own
`ExecMainStartTimestampMonotonic` (the journal boot id does NOT rotate across a
WSL distro terminate/start, so `journalctl -b` silently reports the ORIGINAL
boot — that trap cost one measurement here and is why monotonic deltas are used).

| Cold boot | Bind observed after daemon start | Ready verdict | vsock_loopback | Daemon restarts |
|---|---|---|---|---|
| 2026-08-16 04:41:55 (vault image MISSING — truly cold) | **255 ms** | `vsock_listener=bound`, exit 0 | `missing` at preflight; probe's own modprobe loaded it | 0 |
| 2026-08-17 02:38:43 | **90 ms** | `vsock_listener=bound`, exit 0 | loaded | 0 |
| 2026-08-17 02:41:09 | **61 ms** | `vsock_listener=bound`, exit 0 | loaded | 0 |
| 2026-08-17 02:41:29 | **78 ms** | `vsock_listener=bound`, exit 0 | loaded | 0 |

**4/4 identical verdicts.** Not nondeterministic in this state.

The truly-cold boot is the decisive one, because provisioning demonstrably ran
long there:

```
04:41:55.120  Started tillandsias-headless.service
04:41:55.375  [tillandsias-ready] vsock_listener=bound port=42420      <- T+255ms
04:41:55.411  [liveness] tillandsias-vault not running — re-ensuring   <- provisioning STARTS, T+291ms
04:41:55.610  [tillandsias-vault] vault image missing — building on demand
04:42:07.18   vault image build completes                              <- T+12.1s
04:42:11.07   building image proxy (...); this may take several minutes
04:42:19.32   proxy image build completes                              <- T+24.2s
```

The listener was bound **36 ms before provisioning began** and **24 seconds
before it finished**. 795-jeym's exit criterion 1 — "connects successfully at a
point where provisioning is demonstrably still in flight" — is satisfied by the
code as it already stands. Cold boots 2 and 3 show the same shape at a smaller
scale (bind at +78 ms, vault re-ensure at +366 ms, proxy re-ensure at +4.4 s).

## The six exceptions: five are load-bearing

Removing an exception requires stating why it is no longer load-bearing. Only
one qualifies, and it is not removable yet.

1. **Separate systemd unit — KEEP.** It exists because an `ExecStartPost`
   failure stops the subject; 757-4hdt measured five kills of a healthy daemon.
   That hazard is a property of the WIRING, not of bind timing: a control
   process kills its subject whenever it fails for *any* reason, including the
   module race that actually fires. Deleting it recreates the measured breach.
2. **900s deadline — REDUCIBLE, but not yet.** It is not a bind-latency budget
   (measured worst case 255 ms, so 900s is ~3500x). What it actually covers is
   the `vsock_loopback` load racing the probe. Shortening it before that
   dependency is deterministic converts a slow pass into a fast INDETERMINATE.
   Sequenced as 798-vxj5, after 798-emje.
3. **`--no-block` — KEEP for now.** It exists so provisioning does not wait on
   the assertion; its necessity is a function of the deadline's length, so it
   retires WITH the deadline, not before.
4. **`modprobe` in the probe — KEEP.** This is the actual fix for the actual
   defect and it still does work: on the truly-cold boot the daemon logged
   `vsock_loopback missing` and the probe nonetheless succeeded 249 ms later,
   which can only be its own modprobe. Deleting it reintroduces 757-4hdt's
   false alarm on a healthy system.
5. **INDETERMINATE verdict — KEEP.** The packet invited an argument either way.
   It distinguishes a real third state: "this probe cannot observe the property
   from here" versus "nothing is listening". Folding it into PASS recreates
   735-ewzp's always-passing probe; folding it into FAIL is a false alarm about
   a working system. Both mirrors have already been shipped once each.
6. **ENETUNREACH branch — KEEP.** It is the discriminator that produces (5).
   757-4hdt falsified all three states by execution (bound/0, NOT-BOUND/1,
   INDETERMINATE/2).

## What the residual actually is

The intent behind 795-jeym is live even though its mechanism is dead
(`philosophy.obsolete_mechanism_live_intent` → `mechanism_dead_intent_live`:
REWRITE, never close). Two real mechanisms can delay the bind, neither of which
is "provisioning work runs first":

- **Tokio worker starvation.** The vsock task is spawned LAST (main.rs:13750),
  behind five tasks queued at main.rs:13697-13713. Two of those run genuinely
  blocking code on tokio *worker* threads rather than `spawn_blocking`:
  `run_disk_usage_check` (main.rs:13713) shells out to `bash manage-cache.sh`
  and, on a first boot, materializes every embedded runtime asset to disk via
  `ensure_runtime_assets`; `run_trace_budget_enforcement` (main.rs:13709) reads
  the entire `tillandsias.log` and serde_json-parses every line with no yield
  points. On a 1-vCPU guest the single worker drains the injection queue in
  order, so both sit AHEAD of the bind. This host has multiple vCPUs, which is
  why the effect is not visible in the measurements above — and is exactly the
  "verified where it was written" shape this milestone keeps filing. → 798-q4m9
- **The fetch unit's `Requires=` gate.** `tillandsias-headless.service` declares
  `Requires=`/`After=tillandsias-headless-fetch.service` with
  `TimeoutStartSec=300s`. On the download variant of `fetch-headless.sh` that
  is up to ~135 s of retry overhead plus transfer before the process that binds
  is launched at all. Any clock started at `systemctl enable --now` time rather
  than at daemon-start time attributes that window to bind latency — a
  plausible contributor to the original 15 s reading. → 798-q4m9 (measurement
  half)
- **`vsock_loopback` load races the probe.** This is the variable that actually
  differed between 757-4hdt's FAIL and PASS runs on identical artifact+host:
  the FAIL logged `preflight vsock_loopback missing`, the PASS logged `loaded`.
  → 798-emje

## Release consequence

The stated cause of v0.4.260815.1's promotion-FAIL is wrong. The tag's FAIL is
still a real recorded FAIL and this issue does not promote anything — but the
remediation it is waiting on is not a daemon reordering, and a release held for
that reason is held for a fix that would delete working defenses. The
coordinator holding the cut should re-read the hold against 798-emje, not
795-jeym.

## Method note worth keeping

`journalctl -b` inside a WSL2 guest does not mean "this boot". WSL does not
rotate the journal boot id when a distro is terminated and restarted, so `-b`
returns the ORIGINAL boot and describes the wrong run without saying so. The
first cold-cycle measurement here was silently a re-read of the previous day's
boot. Use `ExecMainStartTimestampMonotonic` deltas or `--since`.
