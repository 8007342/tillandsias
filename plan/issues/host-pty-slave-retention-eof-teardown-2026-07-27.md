# Host PTY: split() retains the slave fd — EOF/teardown defeated; full fd-lifetime fix (D5 follow-up)

- **Date:** 2026-07-27 (split out of `macos-terminal-management-audit-2026-07-27.md`, defect D5)
- **Class:** bug (P2) — shared host-shell PTY layer (`#[cfg(unix)]`)
- **Status:** ready (mitigated, not fixed — see mitigation note)
- **Pickup role:** macOS host (needs a live Darwin termios probe); code is shared `cfg(unix)`

## Defect (CONFIRMED by adversarial verifier, 2026-07-27)

`UnixPtyReader(self.master.clone(), Some(self._slave))` at
`crates/tillandsias-host-shell/src/pty/unix.rs:304` moves the tray's retained
slave fd into the reader for the session's whole life:

- With one slave always open, Darwin master reads return EAGAIN (never
  EOF/EIO) after the terminal client exits → pump_io's input task pends
  forever (`pty/mod.rs:562-587`).
- The documented contract says the opposite: `pty/mod.rs:526-527` ("master.
  split() closed the retained slave"); the pre-attach EIO grace machinery
  (`pty/mod.rs:520-531, 573-584`) is unreachable-by-design in production.
- `PtySession::close` (`pty/mod.rs:474-479`) had zero production callers →
  guest child (the podman harness) leaked when the Terminal window closed.
- Git forensics: pre-`8c6c8d05` split() explicitly dropped the slave; the
  retention arrived silently in `8c6c8d05` (the cfmakeraw commit) with no
  mention in the message.

## Mitigation shipped 2026-07-27

The attach-client redesign gives the tray an explicit detach signal (session
socket disconnect) and the tray now sends `PtyClose` on it, so the
operator-visible leak (window close → orphaned guest harness) is closed.
The underlying fd-lifetime defect remains.

## Remaining work (this packet)

1. **Live probe FIRST (Darwin):** does pty-pair termios (the cfmakeraw raw
   mode set at open, unix.rs:138-147) survive a zero-slave window across
   slave close/reopen? The retention landed in the same commit as cfmakeraw
   and may be load-bearing — if termios resets to cooked on last-slave-close,
   dropping the slave resurrects the echo feedback loop / `[screen is
   terminating]` class of bugs that 8c6c8d05 fixed. Probe: open pair, set
   raw, close slave, reopen via slave_path, tcgetattr → compare flags.
2. If termios persists: change `split()` to construct the reader with `None`
   (slave drops), verify the 10s ATTACH_GRACE covers the pre-attach window
   with the attach-client (which opens the slave promptly — faster than the
   old osascript+screen path), and wire input-task EOF → send
   `ControlMessage::PtyClose` via the cloned transport + stop the output
   task (note: pump_io destructures the session, so close must go through
   the transport Arc, not a PtySession method).
3. If termios does NOT persist: re-apply cfmakeraw from the attach-client on
   the reopened slave (client already owns termios of its own tty; add the
   slave-side tcsetattr there), THEN do step 2.
4. Watch the flash-and-die regression window: ATTACH_GRACE starts at pump
   spawn; the attach path must keep Terminal-spawn → slave-open comfortably
   under it (regression guard: `macos-tray-github-login-blank-terminal-2026-06-21.md`).
5. Tests: add a unix.rs test asserting master read errors once the sole
   external slave closes; keep `pump_input_tolerates_pre_attach_eio` green.

## No-polling note

Dropping the slave reactivates the 50ms EIO sleep-retry loops
(`pty/mod.rs:580-582, 610-612`) as live production polling during the
pre-attach window. Acceptable only as a bounded bootstrap exception per
convergence.yaml; the end-state (attach-client byte transport over the
session socket, strategy C in the audit packet) removes the host PTY pair
and with it this whole class.
