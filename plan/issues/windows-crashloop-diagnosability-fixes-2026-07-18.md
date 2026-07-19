# Windows crash-loop diagnosability + resilience fixes (operator-directed cycle)

- Date: 2026-07-18
- Host: windows (windows-next)
- Source: operator (The Tlatoāni) directive after a live field test — the
  latest release crash-looped on startup on an end-user Windows machine.
  Observed: tray UX reached "Downloading Fedora" (first time seen off the
  dev box — progress!), then a startup crash loop with terminal windows
  popping open, some blank. "Without diagnostics there wasn't much to do."
- Related: `guest-crashloop-detection-and-ephemeral-reset-2026-07-17.md`,
  `vault-unseal-secret-regenerated-on-reensure-2026-07-17.md`,
  `keepalive-terminal-visibility-2026-07-02.md`, order 385 (terminal
  reaping), spec `windows-event-logging` (reactivated this cycle).

## What landed this cycle (windows-next)

### 1. Windows Event Log relay — REACTIVATED as a real implementation

`crates/tillandsias-windows-tray/src/eventlog.rs`: `WindowsEventLogLayer`
relaying INFO/WARN/ERROR to the Application Event Log (source
"Tillandsias") via real `RegisterEventSourceW`/`ReportEventW` calls.

- Finding: the OLD archived implementation (Tauri era, `a6c99d42`,
  removed with `src-tauri/` in `9b4e845d`) was HOLLOW — its
  `write_to_event_log` was a documented no-op that never called the Win32
  API, despite the change being archived as "27 tasks complete". The class
  of false-completion the parity issue warned about.
- Operator delta vs the old spec: ALL INFO relays (was: accountability
  INFO only) — provisioning phases flow at INFO and must be discoverable.
- Wired in `notify_icon::init_tracing` (now layered registry), initialized
  in `main` BEFORE the singleton guard; panic hook added so panics land in
  tray.log + Event Log.
- `TrayProgress::report_phase` now mirrors UX phases into `tracing::info!`
  (download %-ticks stay DEBUG — no Event Log spam).
- Installer: best-effort `New-EventLog` registration piggybacked on the
  single Hyper-V UAC prompt (or direct when elevated); `-Purge` removes
  the source registration best-effort.
- Spec `openspec/specs/windows-event-logging/spec.md`: suspended → active,
  rewritten for the native tray. Cheatsheet
  `cheatsheets/runtime/windows-event-viewer.md` refreshed (unregistered
  sources still receive events; `Get-EventLog` vs `Get-WinEvent` pitfall).
- Verified live: `eventlog_end_to_end_writes_to_application_log`
  (`#[ignore]`, opt-in) emits through the full stack and reads the event
  back with `Get-EventLog`. PASSED on this host 2026-07-18.

### 2. Singleton guard: two real Windows bugs fixed (tillandsias-core)

- `fs2` contention misclassification: busy-lock errors on Windows are
  `ERROR_LOCK_VIOLATION` (raw 33), NOT `ErrorKind::WouldBlock`; every
  busy path returned a hard error. The pre-existing test
  `try_acquire_returns_none_when_lock_is_busy` FAILED on Windows at HEAD
  — proof the bug shipped. Fixed with `is_lock_contended()` comparing
  against `fs2::lock_contended_error()`.
- Unbounded blocking wait: `acquire()` fell through to a forever-blocking
  `lock_exclusive()` after the (no-op on Windows) owner-terminate — a
  second GUI tray instance wedged invisibly. Now a bounded 100ms poll to
  the caller's deadline, then a clean logged refusal. Pinned by
  `acquire_times_out_instead_of_blocking_forever`.
- Startup refusals now log via tracing (→ Event Log), not `eprintln!`
  (invisible in a GUI-subsystem binary).

### 3. Console-window flashes: three unflagged spawns fixed

`notify_icon.rs` `--diagnose`/`collect_report` path spawned `cmd /c ver`,
`where.exe wt.exe`, and `wsl.exe -l -q` without `CREATE_NO_WINDOW` — each
flashes a blank console when invoked from the GUI tray. All three now go
through `tillandsias_vm_layer::no_window_sync`. (Keepalive and interactive
terminals were already correct: hidden by default, console only with
`--debug` or the user-facing terminal.)

### 4. Control-wire connect retries: fixed 5s → capped exponential backoff

The two identical 36×5s fixed loops in `wsl_lifecycle.rs` are now one
`connect_with_backoff()` with a 1,2,4,8,16,30…30s schedule (cap 30s,
10 attempts, ≈181s total — the same ~3-minute envelope), logging each
backoff at INFO (→ Event Log trail). Pinned by
`connect_backoff_schedule_is_capped_exponential`. Other retry sites
audited: fetch.rs download (already exponential 1→16s), wsl.rs start-poke
(already exponential 500ms→), vsock_client BACKOFF_SCHEDULE (already
capped exponential). Weakest loop is gone.

## Residual (NOT closed by this cycle)

- Root cause of the field crash loop remains UNDIAGNOSED — that machine
  had no diagnostics. The Event Log relay exists precisely so the next
  occurrence is attributable. Ask the affected user for
  Event Viewer > Application > Source "Tillandsias" output after the next
  release install.
- `guest-crashloop-detection` (bounded restart counter + `crash-loop:*`
  verdict + one-click ephemeral reset) and the vault re-ensure P1 remain
  open (pickup_role: linux) — they are the convergence layer; this cycle
  delivered the observability + host-side hygiene layer.
- `terminate_process` is still a no-op on Windows (now with a bounded wait
  around it, so it can no longer hang the tray). A real
  OpenProcess/TerminateProcess implementation stays open as enhancement.

## Verifiable closures

- `cargo test -p tillandsias-core --lib singleton` — 2 tests green on
  Windows (one was failing at HEAD).
- `cargo test -p tillandsias-windows-tray` — includes backoff-schedule pin
  and eventlog mapping/format pins.
- `cargo test -p tillandsias-windows-tray -- --ignored eventlog` — live
  Event Log write + readback (Windows hosts only; writes the real log).
