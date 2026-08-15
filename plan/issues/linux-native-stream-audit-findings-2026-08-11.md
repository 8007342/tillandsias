# Linux Native Stream Audit — Findings (order 156, AUDIT HALF)

**Filed 2026-08-11 | host linux-mutable | packet `linux-native-stream-audit` (order 156)**
**Scope:** read-only audit of `crates/tillandsias-headless/src/tray/` and the
headless local interface it calls (`local_projects`, `cloud_projects`,
`remote_projects`, `vault_bootstrap`, `control_dispatch`).
**Contract:** `plan/issues/observable-streams-contract-2026-06-30.md` (SC-01..SC-18,
boundaries B1..B6; the Linux native tray is **B3**).
**Master:** `plan/issues/socket-audit-master-2026-06-30.md`.

This is the AUDIT half only. No code changed. The refactors are filed as ready
child packets (see bottom). Packet 156 stays `ready`.

---

## 0. Headline

The Linux native tray path is **already event-driven for its three named status
surfaces** (VM status, login state, cloud projects). It is not a 30-second poll
pipeline like the Windows/macOS host trays (`notify_icon.rs:1958`,
`action_host.rs:1565`). Only **two real polling sites** remain, and neither is a
continuous status poll:

1. **Login-state Vault poll** — `tray/mod.rs` L3676-3688, a `for _ in 0..120 { …
   sleep(1s) }` presence poll after GitHubLogin. **Worst offender.** (SC-14, AP-1)
2. **Shutdown-signal poll** — `tray/mod.rs` L640-655 + L4081-4082, `AtomicBool` +
   250 ms sleep at three sites. (SC-16)

Everything else the tray does for status is push/event/on-demand.

---

## 1. Polling inventory

| # | Site (file:line) | What it polls | Interval / bound | Event source available? | Verdict |
|---|------------------|---------------|------------------|-------------------------|---------|
| P1 | `tray/mod.rs:3676-3688` | **Login state** — `vault_bootstrap::is_github_key_present()` after GitHubLogin click | `for _ in 0..120 { sleep(1s) }` (2-min window) | **Yes** — `vault-blocking-watch` (order 147, B6) → `watch<LoginState>` / `LoginStatePush` | **VIOLATION** — SC-14 / AP-1. Child **679-rp9m** |
| P2 | `tray/mod.rs:640-655` (`watch_shutdown_and_mark_stopping_blocking`); spawned at `:1270` | Shutdown `AtomicBool` (to flip phase→Stopping) | `while !load { sleep(250ms) }` | **Yes** — promote `install_shutdown_signal_handlers` (`main.rs:13184`) to publish `tokio::sync::Notify`/`watch<bool>` | **VIOLATION** — SC-16. Child **679-vdi6** |
| P3 | `tray/mod.rs:4081-4082` (runtime main-wait loop) | Shutdown `AtomicBool` (to break the loop and exit) | `while !load { tokio::time::sleep(250ms).await }` | **Yes** — same Notify/watch as P2 | **VIOLATION** — SC-16 (same fix as P2; folded into child **679-vdi6**) |
| N1 | `tray/cloud.rs` (whole module) | Cloud projects (GitHub repos) | 5-min **TTL cache**, refreshed **only on events** (launch, login success, `AboutToShow`) — no timer | n/a — already event-driven | **NOT A POLL** (compliant) |
| N2 | `tray/mod.rs:1055-1079` (`VmStatusRequest` handler) | VM/host phase | On-demand reply from `TrayPhaseHandle`; `podman_available_sync()` per request | n/a — tray is the source of truth, serves on request | **NOT A POLL** (SC-07 pass) |
| N3 | `tray/mod.rs:3980-4047` (startup login probe) | Login state (initial) | **One-shot** `spawn_task` at launch (`is_github_logged_in`) | n/a — one-shot, event-shaped | **NOT A POLL** (compliant) |
| N4 | `tray/mod.rs:452-467` (`AsyncTaskExecutor` worker) | Bounded task queue | `recv_timeout(100ms)` to re-check `is_running` | n/a — work-queue drain, not a status surface | **NOT A POLL** (acceptable; minor — see §4) |
| N5 | `remote_projects.rs:268-292` | Child `gh` process exit | `loop { try_wait; sleep(50ms) }` with deadline | n/a — subprocess reap w/ timeout, on-demand | **NOT A POLL** (acceptable; minor — see §4) |
| N6 | `tray/mod.rs:2543` (`handle_clone_project`, `#[allow(dead_code)]`) | none — one-shot `sleep(2s)` before menu rebuild | one-shot | n/a — dead code | **NOT A POLL** (dead code — see §4) |

**Real polling sites that violate the contract: 2** (P1; P2/P3 are one fix).
Grep confirms **zero** `tokio::time::interval`, zero periodic `tick`, and no
background status re-probe thread anywhere in the tray path.

---

## 2. Channel-type findings

| Finding | Evidence | Verdict |
|---------|----------|---------|
| Only in-tray channel is a **bounded** `mpsc::sync_channel` | `tray/mod.rs:438` `mpsc::sync_channel::<…>(queue_size)`, `ASYNC_EXECUTOR_WORKERS=4` (`:430`) | **PASS** SC-04 — finite, documented capacity |
| **Zero** `mpsc::unbounded_channel` in the tray path | grep over `tray/` + local interface: no matches | **PASS** SC-04 / SC-17 — the "not mpsc::unbounded" exit criterion holds |
| Only `try_send` **surfaces the error to the caller** (not a silent drop) | `tray/mod.rs:480` `self.sender.try_send(...)` returns `Err`; callers log "task queue full" (e.g. `:2548`, `:4045`) | **PASS** SC-05 — not a terminal-sink silent drop |
| UI-state fan-out uses `Arc<Mutex<TrayUiState>>` + `bump_revision()` + DBusMenu `LayoutUpdated`, **not** `tokio::sync::watch` | `TrayService.state: Arc<Mutex<TrayUiState>>` (`:1297`); rebuild via `rebuild_after_state_change` | **OBSERVATION** — push-not-poll in behaviour, but not the `watch` primitive the B3 contract names ("must use tokio::sync::watch channels driven by the headless's internal event bus"). Not a polling violation; noted for the refactor half. |
| Control-socket fan-out is a `Vec<Arc<Mutex<UnixStream>>>` with **blocking** `write_all` | `broadcast_control_envelope` `:553-561` | **OBSERVATION** — blocking write = OS backpressure (SC-10/SC-15 satisfied by blocking), but std-blocking-on-threads, not tokio AsyncWrite streams (B3 ideal). Not a poll. |

---

## 3. SC-01..SC-18 verdict matrix (Linux native tray + headless local path)

| Code | Criterion (abridged) | Verdict | Evidence |
|------|----------------------|---------|----------|
| SC-01 | No `tokio::time::sleep` in an async fn that handles socket I/O | **PASS** | The one `tokio::time::sleep` (`:4082`) is the shutdown-wait in the runtime block, not a socket-I/O fn. Control-socket handlers are sync std-thread code. |
| SC-02 | No `loop { … sleep … }` within 20 lines of a socket read/write | **PASS (narrow) / N/A** | Login loop (`:3676`) and shutdown loops are not within 20 lines of a socket r/w; `remote_projects.rs:268` loop wraps a subprocess, not a socket. (Spirit-violation of AP-1 captured under SC-14/SC-16 below.) |
| SC-03 | No `std::io::{Read,Write}` on async-context types w/o `spawn_blocking` | **N/A / PASS** | `read/write_control_envelope` use std blocking I/O but on **dedicated std::threads** (accept loop `:1274`, per-conn `:1280`), never inside async tasks. |
| SC-04 | All channels documented finite capacity; `unbounded` == 0 | **PASS** | `mpsc::sync_channel(queue_size)` `:438`; no `unbounded_channel` anywhere in scope. |
| SC-05 | `try_send` documented terminal-sink drop, or `.send().await` | **PASS** | Only `try_send` (`:480`) returns `Err` to the caller who logs it — not a silent drop. |
| SC-06 | Control-wire reader is one long-lived task/connection, not per-request | **PARTIAL** | `Hello` registers a persistent subscriber (long-lived, held for broadcast). But request/reply variants (`VmStatusRequest`, `EnumerateLocalProjects`, `CloudRefreshRequest`) read **one** frame then return → connection closes (AP-3 one-shot shape on the server side). `handle_control_connection` `:925-1218`. |
| SC-07 | `VmStatusRequest` not sent after subscription handshake | **PASS** | The Linux tray never sends `VmStatusRequest` to itself; it reads `TrayPhaseHandle` in-process (`:1073`). No self-poll of VM status. |
| SC-08 | Headless holds connection open until client disconnect | **PARTIAL** | Held open for the `Hello`/subscriber (broadcast) path; closed after one frame for request/reply variants. Same site as SC-06. |
| SC-09 | Headless sends `VmStatusPush` within 500ms of a phase change | **VIOLATED** | The Linux path emits **no** server-push — `VmStatusPush`/`LoginStatePush`/`CloudProjectsPush` are never sent; status is reply-only. This is the B3/B4 refactor body (children of the master epic), recorded here as the structural gap, not a discrete poll site. |
| SC-10 | Slow consumer does not cause producer to drop frames | **PASS** | `broadcast_control_envelope` uses blocking `write_all` → OS backpressure; failed subscriber is dropped from the list, live frames not dropped. `:553-561`. |
| SC-11 | Idle tray CPU < 0.1% over 5 min | **PASS (numeric) / note** | Numerically fine (three 250ms wakeups/sec ≈ 12 wakeups/s, trivial). But the contract's "zero idle cost: no timer wakeups" property is **violated** by the shutdown polls → tracked under SC-16 / child 679-vdi6. |
| SC-12 | No `podman exec` in PTY/exec data path | **N/A / PASS** | The native tray has no PTY/exec data path (that's the vsock side). Podman is invoked for cloud `gh` / container ops, not as a PTY data stream. |
| SC-13 | No `std::process::Command::output()` from an async fn w/o `spawn_blocking` | **PASS** | Command/`gh`/podman calls run inside `spawn_task` std-thread workers, not async fns; `podman_available_sync()` runs on the per-connection std::thread. |
| SC-14 | Vault token changes via blocking-watch HTTP, not periodic GET | **VIOLATED** | `tray/mod.rs:3676-3688` polls `is_github_key_present()` up to 120× @ 1s — periodic presence GET. **Child 679-rp9m.** |
| SC-15 | Stream error paths propagate backpressure to source | **PASS** | Blocking writes propagate; `subscribers.retain(...)` drops dead peers on write failure `:555-560`. |
| SC-16 | No `AtomicBool + sleep` as a signaling primitive; use `Notify`/`watch` | **VIOLATED** | `watch_shutdown_and_mark_stopping_blocking` `:640-655` and main-wait loop `:4081-4082` — `AtomicBool` + 250ms sleep, 3 sites. **Child 679-vdi6.** |
| SC-17 | PTY outbound channels bounded (no `unbounded_channel` on PTY path) | **N/A** | No PTY path in the native tray. |
| SC-18 | `PtyRouter::route` must not silently drop frames | **N/A** | No PTY router in the native tray. |

**Summary: 9 verified / 3 violated (SC-09, SC-14, SC-16) / 2 partial (SC-06, SC-08) / 4 n-a (SC-02 narrow-pass counted as pass; SC-12, SC-17, SC-18 n-a).**
Counting the two partials as "verified-with-caveat" and SC-02 as pass:
**9 pass, 3 violated, 2 partial, 4 n/a.**

---

## 4. Noticed, not fixed (below the child-packet bar)

These are recorded for completeness; none is a status-polling violation and none
warrants its own refactor packet this cycle.

- **SC-06 / SC-08 partial (request/reply connections close after one frame)** —
  `handle_control_connection` (`:925`) serves one frame for `VmStatusRequest` /
  `EnumerateLocalProjects` / `CloudRefreshRequest` then closes. This is the
  server-side of AP-3, and the true fix is the **B4 persistent-listener** work
  (order 145, `vm-headless-persistent-listener`, which 156 already depends on) +
  the server-push variants (SC-09). Deliberately **not** re-filed as a 156 child:
  it is the master-epic's own body, not a Linux-tray-local poll. *(enhancement,
  owned upstream by B4)*
- **UI fan-out is `Arc<Mutex>` + revision, not `watch`** (§2) — behaviourally
  push-not-poll; converting to `tokio::sync::watch` per the B3 contract is a
  *stylistic/optimization* refactor with no current correctness or CPU cost.
  Left as an observation. *(optimization)*
- **`AsyncTaskExecutor` worker `recv_timeout(100ms)`** (`:458`) — a bounded
  work-queue drain that re-checks the `is_running` flag; standard shutdown-able
  worker pattern, not a status poll. Could use a `Notify` for a cleaner stop but
  it is not on any transport/status path. *(optimization, low value)*
- **`remote_projects.rs:268-292` subprocess-wait loop** (`try_wait` + 50ms sleep
  + deadline) — an on-demand child-process reaper with a timeout, invoked only
  during a cloud refresh; not a background poll. Could use `wait_timeout`/async
  process wait. *(optimization, low value)*
- **`handle_clone_project` `sleep(2s)`** (`:2543`) — `#[allow(dead_code)]` legacy;
  a one-shot cosmetic delay, not a loop. Remove with the dead code whenever the
  legacy clone path is pruned. *(cleanup)*

---

## 5. Classification of the fixable findings

| Finding | Child packet | Class |
|---------|--------------|-------|
| P1 — login-state Vault poll (SC-14, AP-1) | **679-rp9m** `linux-tray-login-vault-poll-to-event` | **enhancement** (event-driven login confirmation; correctness of the contract surface) |
| P2/P3 — shutdown `AtomicBool`+sleep (SC-16) | **679-vdi6** `linux-tray-shutdown-atomicbool-sleep-to-notify` | **optimization** (idle-cost / correct signaling primitive) |

Both children carry `release_target: socket-audit-master`,
`depends_on: [linux-native-stream-audit, …]`, and verifiable exit criteria
(no-poll-remains + subscribe-to-event + a litmus assertion). Filed in fragment
`plan/index.d/20260811t045000z-156-audit-children-linux-mutable.yaml`, which also
carries the `progress` event on packet 156. Packet 156 remains `ready`.
