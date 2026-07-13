# macOS OpenCode lane: window resize never propagates — TUI stays in the initial-size region

- Date: 2026-07-12
- Class: bug (P2, macOS PTY bridge UX)
- discovered_by: operator attended m8 smoke (macOS arm64, osx-next
  `374cb0b8` tray)
- Related: `opencode-tray-tui-escape-spill-2026-07-12.md` (Linux lane TUI
  defect — different symptom, same surface), macOS PTY attach path
  (Terminal.app → `screen /dev/ttysN` → tray PTY master → vsock wire →
  guest container PTY).

## Symptom

OpenCode TUI in the tray-launched lane works — colors render, mouse
clicks register (expand/collapse of text blocks works) — but after
resizing the Terminal window the TUI keeps drawing inside the ORIGINAL
window-size rectangle; only that region refreshes. Session remained
usable but cramped for a full in-forge meta-orchestration cycle.

## Reading

Data path and even mouse-event forwarding are intact in both directions;
what never arrives is the winsize update. On this path a resize must
travel Terminal.app → screen (SIGWINCH) → slave tty TIOCSWINSZ → tray PTY
master → control wire message → guest PTY ioctl. `screen` DOES forward
resizes to the attached tty, so the missing hop is most likely
tray-side: no kqueue/SIGWINCH-equivalent watch on the PTY master winsize
(macOS: TIOCGWINSZ polling or SIGWINCH on the session leader won't fire
in the tray — it needs to read the packet/ioctl from the master or watch
the slave) → wire resize verb never sent. Check whether the control wire
even has a resize verb; if not, that is the packet.

## Repro

Any tray-launched lane with a TUI → resize the Terminal window → redraw
region stays at the initial size. Deterministic in the attended session.
