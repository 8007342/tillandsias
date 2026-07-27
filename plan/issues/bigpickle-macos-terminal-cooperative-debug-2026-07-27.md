# P0 — BigPickle in-forge cooperative debug: verify terminal-attach@v2 end to end from INSIDE the forge

- **Date:** 2026-07-27
- **Class:** verification + cooperative debugging (P0 — v0.4 release gate)
- **Status:** ready
- **Pickup role:** **in-forge agent on the macOS host's forge** (BigPickle /
  OpenCode running inside `tillandsias-<project>-forge`). Host-side builder
  (Claude, bare-metal `~/claudia` checkout) works the OUTSIDE half.
- **Branch:** osx-next
- **Parent:** plan/issues/macos-terminal-management-audit-2026-07-27.md
- **Why P0:** stable macOS tray terminal UX is the last gate before v0.4;
  the outside builder cannot observe the terminal from the harness's side —
  only an in-forge agent can.

## Context (cold-start)

The macOS tray terminal chain was rebuilt 2026-07-27 (terminal-attach@v2):
Terminal.app now runs the tray's own attach client (raw tty, SIGWINCH →
event-driven resize over a session socket, DECRST mode resets, detach →
PtyClose), the guest PTY clears its echo family (keeps ISIG), host→guest
input became lossless, and TERM/COLORTERM/LANG now flow. Seven audited
defects (D1–D7) are documented in the parent packet; D1–D4+D7 are fixed in
this build, D5/D6 have follow-up packets.

**Your terminal, as the in-forge agent, IS the system under test.**

## Protocol — cooperative loop with the outside builder

1. BigPickle (inside): run the probes below, write results into THIS file
   under "## Findings log", commit and **push osx-next immediately** —
   push early, push often: a prior forge died with an unpushed root-cause
   analysis (see macos-forge-opencode-terminal-render-2026-07-25.md
   provenance) and the work was lost.
2. Outside builder: pulls, fixes builder-side (tray/guest binary), rebuilds
   + reinstalls the tray, relaunches a fresh forge, updates this file with
   "OUTSIDE:" notes + what changed, pushes.
3. Repeat until every probe below is ✅, then flip this packet to completed
   and note residuals in new packets.

If you need the outside builder to act, write an "OUTSIDE-ACTION-NEEDED:"
line in the findings log and push — the builder polls this file between
its own build cycles (human-paced pulls, not automation).

## Probes (run from your normal in-forge shell — the deepest PTY)

Record exact output + a timestamp for each.

1. **Termios as the harness sees it:** `stty -a` — expect a sane pty
   (icanon/echo state is the CONTAINER pty's, managed by podman/your TUI;
   report whatever you see, especially `-echo`/`echo`, `isig`, `rows/cols`).
2. **Geometry truth:** `echo "$(tput lines)x$(tput cols)"` — must match the
   real Terminal.app window, NOT 24x80 (unless the window truly is).
3. **Live resize (THE headline fix):** run
   `trap 'echo "WINCH -> $(stty size)"' WINCH` in bash, then have the
   operator resize the Terminal.app window a few times. Expect one line per
   resize with the new size arriving within ~100ms. Then run your TUI
   (OpenCode) and confirm it reflows to every new size.
4. **Env fidelity:** `env | grep -E '^(TERM|COLORTERM|LANG|LC_)'` — expect
   TERM=xterm-256color, COLORTERM=truecolor, LANG set (C.UTF-8 or the
   container's en_US.UTF-8).
5. **Echo bleed (character bleeding regression check):** run a long
   output-only stream (`for i in $(seq 1 500); do echo "line $i ─ ✓ 漢字"; sleep 0.01; done`)
   while the operator two-finger scrolls over the window. Expect: NO
   literal `^[[A`/`^[[B` in the stream; Terminal.app scrolls its own
   scrollback during the stream.
6. **Ctrl+C ownership:** start `sleep 100`, press Ctrl+C — expect SIGINT
   kills it (ISIG intact through the whole chain).
7. **UTF-8 + burst integrity:** `cat` a large multibyte file (or
   `yes '¡ünïcödé—漢字-🌵!' | head -5000`) at full speed — expect zero
   mojibake/torn sequences (backpressure fix regression check).
8. **Window-close reap (operator-assisted, LAST):** in a SECOND attach
   window, start `sleep 300`, have the operator close that Terminal.app
   window, then from your shell check the process is reaped within ~3s
   (`pgrep -f 'sleep 300'` in the VM context if reachable, else note what
   you can observe). Expect: no orphaned session.
9. **Mode-reset hygiene:** exit and relaunch your TUI mid-session (or kill
   it uncleanly with SIGKILL), then produce output — expect no leftover
   mouse-reporting (scroll during the following output stream must not
   inject arrows).

## What to file per anomaly

Exact probe number, raw bytes/output (use `cat -v` for control chars),
window size before/after, wall-clock time, and whether it reproduces.
Anomalies in probes 3/5/7 are P0 — push immediately, don't batch.

## Findings log

(append below; newest last; push after every entry)
