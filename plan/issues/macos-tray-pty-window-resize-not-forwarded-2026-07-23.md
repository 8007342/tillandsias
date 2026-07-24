# macOS forge terminal: window resize / SIGWINCH never forwarded — guest TUI stays at the attach-time size (80x24)

- **Date:** 2026-07-23
- **Class:** bug (P2) — macOS PTY / terminal-attach
- **Area:** macOS PTY / terminal-attach (Terminal.app `screen` ↔ host `UnixPtyMaster` ↔ vsock ↔ guest PTY)
- **Severity:** P2 — the in-guest agent TUI renders clipped/börked at a fixed
  80x24 rectangle regardless of the real (usually larger) Terminal.app window,
  and never repaints on resize. Session stays usable but cramped.
- **Owner host:** macOS (osx-next) — the missing piece is the host-side detector;
  the guest + wire are already correct.
- **Discovered by:** operator report (agent TUI renders at a fixed window size,
  = the size at attach time; resizing Terminal.app does nothing) — reproduces the
  m8 attended-smoke observation.
- **Specs:** macos-native-tray.lifecycle.terminal-attach@v1,
  control-wire-pty-attach §3.5 (PtyResize), vsock-transport

## Theme: PTY-attach fidelity (input modes AND window size)

This is the second half of a single theme with
`plan/issues/macos-tray-scroll-arrowkey-spill-during-build-2026-07-23.md`: **the
tray's PTY bridge must faithfully forward terminal STATE.**
- That packet: **input modes** — echo/ISIG/mouse-scroll fidelity (an output-only
  stream must not bleed/echo input).
- This packet: **window size** — SIGWINCH / rows×cols fidelity (the guest child
  must track the real terminal geometry).
Both are gaps in the same `Terminal.app → screen /dev/ttysNNN → UnixPtyMaster →
vsock → guest PTY` bridge.

## Related / prior art
- `plan/issues/macos-opencode-pty-resize-not-propagated-2026-07-12.md` — m8
  attended smoke logged this exact symptom (OpenCode TUI keeps drawing in the
  original-size rectangle after resize) and left the open question *"Check
  whether the control wire even has a resize verb; if not, that is the packet."*
  **This packet answers it:** the wire verb EXISTS and the guest APPLIES it — the
  gap is the missing HOST detector. That issue also records the operator
  observation that **`screen` DOES forward resizes to the attached tty**, which
  is the load-bearing assumption for the fix below.
- `plan/issues/macos-tray-attended-smoke-findings-2026-07-10.md` — m8 PTY
  findings surface / the same attach path.
- Commit `8c6c8d05` (host PTY `cfmakeraw`) — the host-PTY hardening precedent in
  the same `unix.rs`; this packet adds the *reverse* ioctl (`TIOCGWINSZ`) that
  the same layer is currently missing.

## Symptom
The in-guest agent TUI (OpenCode/Claude/etc.) renders inside a fixed rectangle
= the window size present at attach time. Resizing the Terminal.app window does
**not** propagate: the guest child never receives new rows/cols nor a SIGWINCH,
so it never repaints to the new geometry — the display stays clipped/cramped.

## Mechanism — the wire + guest are ready; the HOST never emits a resize

The intended resize path (control-wire-pty-attach §3.5) is:
```
Terminal.app window resize
  → screen (SIGWINCH from Terminal.app's pty)
  → screen TIOCSWINSZ on /dev/ttysNNN (the host UnixPtyMaster SLAVE)   [per 07-12 obs.]
  → HOST detects new winsize  ← ★ MISSING HOP ★
  → PtySession::resize(rows,cols) → ControlMessage::PtyResize on the bridge
  → guest applies TIOCSWINSZ + kernel raises SIGWINCH to the child     [works]
  → TUI repaints
```

What exists vs. what's missing, with file:line:

- **Guest side — PRESENT & CORRECT.** `PtySessionStore::resize`
  (`crates/tillandsias-headless/src/pty_handler.rs:329-341`) does `TIOCSWINSZ`
  on the session master fd (`set_winsize`, `:455-471`); setting the size on the
  tty makes the kernel raise `SIGWINCH` to the child's foreground process group,
  so the TUI repaints. Inbound `PtyResize` is routed to it at
  `crates/tillandsias-headless/src/vsock_server.rs:1095-1100`. **This half never
  fires because nothing sends the envelope.**
- **Wire + host helper — PRESENT.** `PtySession::resize`
  (`crates/tillandsias-host-shell/src/pty/mod.rs:441-448`) sends
  `ControlMessage::PtyResize{session_id,rows,cols}`. `UnixPtyMaster::resize`
  (`crates/tillandsias-host-shell/src/pty/unix.rs:173-181`) can `TIOCSWINSZ` the
  host master too. The design intent is documented at
  `unix.rs:82-84` ("sender should also call `PtySession::resize` on the wire so
  the in-VM child gets matching SIGWINCH").
- **Host detector — ABSENT (the defect).** Repo-wide grep confirms:
  - **zero `TIOCGWINSZ`** anywhere — nothing ever *reads* a window size
    (`unix.rs` declares only `TIOCSWINSZ` at `:277/:279/:300`; there is no
    `ioctl_getwinsz`).
  - **zero SIGWINCH handlers** in the tray/host-shell (the `SIGWINCH` matches in
    `unix.rs:84,171` are comments). The tray is a GUI process and does NOT hold
    Terminal.app's window as its controlling tty, so it receives no SIGWINCH
    for it — the only host-observable channel is `TIOCGWINSZ` on the host PTY
    master, which nothing polls.
  - **zero production callers of `PtySession::resize`** — the only `.resize(`
    call sites are unit tests (`mod.rs:658,950,977,984`) and the bridge test
    (`pty_vsock_bridge.rs:454`).
- **The attach flow hardcodes the size and then discards the handle.**
  `run_pty_attach` (`crates/tillandsias-macos-tray/src/action_host.rs:1163-1200`):
  - `:1191` `UnixPtyMaster::open(24, 80)` — host PTY fixed at **80x24**.
  - `:1194` `launch_spec(&intent, project.as_deref(), 24, 80)` — guest `PtyOpen`
    fixed at **80x24** (the true Terminal.app size is unknown here — the window
    is opened *later* by `spawn_terminal_pty_attach` via osascript).
  - `:1198` `pump_io(session, master)` **moves** the `PtySession` in and returns;
    nothing retains a handle to ever call `session.resize(...)`.
  - `pump_io` (`crates/tillandsias-host-shell/src/pty/mod.rs:496-544`) spawns an
    input task (local keystrokes → guest) and an output task (guest → terminal)
    but **no winsize-watch task** — the `transport` that could carry a
    `PtyResize` is captured only by the byte-input loop.

Net: the guest starts at 80x24 and stays there forever; a real resize is never
detected and never sent.

## Recommended minimal end-to-end fix (host-side only; guest needs no change)

1. **Add a winsize reader to the host PTY layer.** In
   `crates/tillandsias-host-shell/src/pty/unix.rs` (next to the existing
   `TIOCSWINSZ`/`ioctl_setwinsz` at `:277-300`) add `TIOCGWINSZ` +
   `ioctl_getwinsz` and a `UnixPtyMaster::winsize() -> io::Result<(u16,u16)>`
   getter. Expose it on the `PtyMaster` trait (`pty/mod.rs`) so the generic
   `pump_io` can read it (or pass the concrete master).

2. **Spawn a resize-watch task in `pump_io`.**
   `crates/tillandsias-host-shell/src/pty/mod.rs:496` (alongside the input/output
   tasks): (a) on start, read the true winsize and send one
   `ControlMessage::PtyResize{session_id, rows, cols}` via the shared
   `transport` (reconciles the hardcoded 80x24 to the real Terminal.app size once
   `screen` has attached and propagated it); (b) then poll `master.winsize()` on
   a light cadence (~200-300 ms) and re-send only on change. This reuses the
   existing wire verb and the already-correct guest handler — no new protocol.
   Bound: the task ends when the session closes (same lifecycle as the byte
   pumps), so no unbounded loop
   (`vm-provisioning-lifecycle.invariant.launch-no-unbounded-loop`).

3. **Drop / reconcile the hardcoded initial size.** The `24, 80` literals at
   `action_host.rs:1191` and `:1194` are only a bootstrap default now; step 2's
   startup send makes the guest converge to the real size. (Optional nicety:
   if a true size is knowable pre-attach, thread it into `open`/`launch_spec`.)

**Guest side: no change.** `pty_handler.rs:329` already applies `TIOCSWINSZ`
(kernel → SIGWINCH → TUI repaint). This packet only feeds it.

### Why polling, not a signal
The tray does not own Terminal.app's window as a controlling tty, so no
`SIGWINCH` is delivered to the host for it, and a `TIOCGWINSZ` on a *non-
controlling* master has no readiness/notification edge — a short poll is the
minimal robust host-side detector. (A kqueue/`EVFILT` on the master does not
surface winsize changes.)

## Load-bearing assumption to VERIFY first (reproduce the break, then confirm the hop)
The fix relies on **`screen /dev/ttysNNN` issuing `TIOCSWINSZ` on the serial
device when its Terminal.app window resizes**, so the host master's
`TIOCGWINSZ` observes the new size. The 07-12 packet asserts this from operator
observation, but screen's serial/tty-attach mode winsize propagation is
historically version-dependent — confirm with a live probe (log
`master.winsize()` across a manual resize) before building step 2. **If screen
does NOT propagate**, the `screen`-based bridge cannot carry winsize in-band and
a deeper change is required (e.g. a control-wire size channel driven from a
terminal that reports geometry, or replacing the `screen` attach) — that would be
a follow-up packet, not this minimal fix.

## Verifiable closure
1. Host unit: a fake master whose `winsize()` changes across polls makes
   `pump_io` emit exactly one `PtyResize` per change (and one at startup).
2. Guest unit already covers `PtyResize → TIOCSWINSZ` (extend to assert the
   child receives `SIGWINCH`).
3. Attended macOS: attach an agent TUI in a non-80x24 window → it fills the real
   window immediately (startup reconcile) → resize the window → TUI repaints to
   the new geometry within a poll interval. Closes
   `macos-opencode-pty-resize-not-propagated-2026-07-12.md`.

## Non-goals
Do not add a new resize protocol — the `PtyResize` verb + guest handler already
exist and are correct. Do not touch the host `cfmakeraw` raw-mode (`8c6c8d05`).
Guest-side needs no code change.
