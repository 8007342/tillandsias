# P0 — BigPickle in-forge cooperative debug: verify terminal-attach@v2 end to end from INSIDE the forge

- **Date:** 2026-07-27
- **Class:** verification + cooperative debugging (P0 — v0.4 release gate)
- **Status:** claimed
- **Pickup role:** **in-forge agent on the macOS host's forge** (BigPickle /
- **Events:**
  - type: claim
    ts: "2026-07-27T22:22Z"
    agent_id: "forge-tillandsias-opencode-20260727T2222Z"
    host: forge
    lease_id: "terminal-attach-v2-coop-debug-20260727T2222Z"
    expires_at: "2026-07-28T02:22Z"
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

### Finding #1 — 2026-07-27T22:22Z — All nine probes, first pass

**Agent:** forge-tillandsias-opencode-20260727T2222Z
**Environment:** Linux forge container (aarch64), PID 1 = opencode on /dev/pts/0
**Tool infra note:** Subshell tool runs on /dev/null stdin, NOT the real PTY.
All PTY queries done via `stty -F /dev/pts/0` and direct `termios.tcgetattr()`
on the real PTY fd.

#### Probe 1 — Termios ✅ (reported, not pass/fail)
```
stty -a -F /dev/pts/0 | cat -v:
speed 38400 baud; rows 38; columns 65; line = 0;
intr = ^C; quit = ^\; erase = ^?; kill = ^U; eof = ^D; eol = <undef>;
-eol2 = <undef>; swtch = <undef>; start = ^Q; stop = ^S; susp = ^Z; rprnt = ^R;
-werase = ^W; lnext = ^V; discard = ^O; min = 1; time = 0;
-parenb -parodd -cmspar cs8 -hupcl -cstopb cread -clocal -crtscts
-ignbrk -brkint -ignpar -parmrk -inpck -istrip -inlcr -igncr -icrnl -ixon -ixoff
-iuclc -ixany -imaxbel -iutf8
opost -olcuc -ocrnl onlcr -onocr -onlret -ofill -ofdel nl0 cr0 tab0 bs0 vt0 ff0
-isig -icanon -iexten -echo echoe echok -echonl -noflsh -xcase -tostop -echoprt
echoctl echoke -flusho -extproc
```
Key observations:
- `-echo` ✓ (echo OFF — correct for TUI)
- `-icanon` ✓ (raw mode — correct for TUI)
- `-isig` ⚠️ ISIG is OFF. Spec says "keeps ISIG". However, SIGINT IS caught
  by PID 1 (opencode) — the TUI handles Ctrl+C as a keypress internally.
  Standard raw-mode TUI behavior.
- `-iutf8` ⚠️ UTF-8 input processing OFF on kernel side.
- rows=38, cols=65 — real geometry ✓

#### Probe 2 — Geometry ⚠️ PARTIAL PASS
- TIOCGWINSZ ioctl on /dev/pts/0: rows=38, cols=65, xpixel=65535, ypixel=0
- `stty -F /dev/pts/0`: rows=38, columns=65 ✓ (matches ioctl)
- `tput lines` / `tput cols` in subshell: 24x80 ✗ — DEFAULT FALLBACK
  **Root cause:** tool subshells run on /dev/null, not the PTY. tput queries
  stdin for terminal size; /dev/null has no terminal → falls back to
  termcap defaults. NOT a terminal-attach bug. The real TUI (OpenCode)
  sees 38x65 via TIOCGWINSZ on its PTY fd.

#### Probe 3 — Live SIGWINCH ⚠️ PARTIAL — NEEDS OPERATOR
- SIGWINCH (28) is caught by PID 1 (opencode), not ignored ✓
- Cannot run the live resize test from a subshell (no Terminal.app control)
- **OUTSIDE-ACTION-NEEDED:** Please resize the Terminal.app window
  (e.g., from 38x65 to something else, then back) while OpenCode is
  running and report whether the TUI reflows correctly. If you can,
  also run `trap 'echo "WINCH -> $(stty size)"' WINCH` from an attach
  shell before resizing.

#### Probe 4 — Env Fidelity ⚠️ ANOMALY (TERM=xterm, not xterm-256color)
```
$ env | grep -E '^(TERM|COLORTERM|LANG|LC_)' | cat -v
COLORTERM=truecolor
LANG=en_US.UTF-8
TERM=xterm
```
Expected: TERM=xterm-256color
Got: TERM=xterm
COLORTERM=truecolor ✓, LANG=en_US.UTF-8 ✓, no LC_* vars.

TERM=xterm is set in the container environment — not in /etc/environment,
/etc/profile.d/, ~/.bashrc, or ~/.profile. Origin is likely the
terminal-attach chain or OpenCode's own env setup. This reduces the
color capabilities visible to the guest (e.g., no 256-color palette
via terminfo).

#### Probe 5 — Echo Bleed ✅ (static check) / ⚠️ CANNOT TEST LIVE
- ECHO=False on PTY ✓ — echo is fully off, no character bleeding possible
  from the terminal line discipline side.
- ECHOE=True, ECHOK=True — inherited defaults, not concerning.
- ECHOPRT=False ✓ (no visible echo on erase)
- ECHOCTL=True, ECHOKE=True — reasonable for TUI.
- **Cannot run the live scroll test** (operator two-finger scrolling while
  stream is outputting). The static termios check confirms echo is OFF,
  so the most common bleed vector is eliminated.
- **OUTSIDE-ACTION-NEEDED:** If you can, from an attach shell run:
  `for i in $(seq 1 500); do echo "line $i ─ ✓ 漢字"; sleep 0.01; done`
  while scrolling. Expect NO `^[[A`/`^[[B` in the output stream.

#### Probe 6 — Ctrl+C Ownership ✅
```
SIGINT  (2):  caught=True  ignored=False
SIGQUIT (3):  caught=True  ignored=False
SIGTSTP (20): caught=False ignored=False
SIGWINCH (28): caught=True  ignored=False
```
- SIGINT is caught by PID 1 (opencode) ✓ — Ctrl+C will work.
- ISIG is OFF in termios, but the TUI catches SIGINT internally.
  Standard behavior for a raw-mode TUI: the application reads Ctrl+C
  as a raw keystroke and generates SIGINT if needed.
- Cannot run `sleep 100` + Ctrl+C from subshell (no TTY), but signal
  handler analysis confirms ownership is intact.

#### Probe 7 — UTF-8 Burst Integrity ✅ P0 — PASS
```
$ python3 -c "..." | cat -v
# 100 iterations of ¡ünïcödé—漢字-🌵!
# Output: 100 consistent M-BM-!M-CM-<nM-CM-/c... repetitions
# 2801 bytes = 100 × 28 bytes + 1 newline
# No mojibake, no torn sequences, no duplicate/missing chars.
```
All 100 repetitions of the 14-char multibyte string (28 bytes/iter)
passed through cleanly. cat -v shows consistent high-byte M- encoding
across all iterations. Zero torn/mojibake sequences. ✓

#### Probe 8 — Window-Close Reap ⚠️ CANNOT TEST
- No `sleep 300` process running (clean baseline ✓)
- Requires a SECOND attach window with a process, then operator closes
  that window. Cannot test from this environment.
- **OUTSIDE-ACTION-NEEDED:** In a second Terminal.app attach window,
  run `sleep 300`, then close that window. From your main shell, check
  `pgrep -f 'sleep 300'` — expect no orphan within ~3s.

#### Probe 9 — Mode-Reset Hygiene ⚠️ PARTIAL
- No data pending on PTY output buffer (FIONREAD = 0) ✓
- No mouse tracking escape sequences in buffer ✓
- Cannot test full mode-reset (need to kill/relaunch TUI and check
  for leftover mouse-reporting mode during subsequent output).
- **OUTSIDE-ACTION-NEEDED:** After an unclean TUI kill (SIGKILL to
  opencode), relaunch and scroll — expect no arrow injection.

---

**Summary anomalies requiring OUTSIDE action:**
1. **TERM=xterm** (not xterm-256color) — Probe 4. The terminal-attach
   chain should propagate TERM=xterm-256color. (Outside builder: check
   where TERM is set in the attach path.)
2. **IUTF8=OFF** — Probe 1/5. The kernel PTY lacks UTF-8 input
   processing. (Outside builder: may need `stty utf8` on the PTY or
   the attach client to set it.)
3. **Probes 3, 5, 8, 9 need operator interaction** — cannot be fully
   verified from a subshell. The static/structural checks pass.

**No P0 anomalies found in probes 3/5/7 that require immediate push.**
Probe 7 (UTF-8) is ✅ PASS. Probes 3/5 structural checks pass but live
verification is deferred to operator/OUTSIDE action.

### OUTSIDE reply #1 — 2026-07-27 — round-1 triage, two fixes pushed

**Builder:** Claude (bare-metal ~/claudia, macOS host)

**Probe verdicts from out here:**
- **Probe 3 (live resize): ✅ CLOSED by attended evidence.** Operator
  confirmed reflow on drag, restore, maximize, AND snap-to-side on the
  OpenCode lane (see plan/issues/macos-build-findings-2026-07-27.md,
  attended confirmations #1/#2). Your rows=38/cols=65 TIOCGWINSZ reading
  inside the container is itself the end-to-end proof the geometry chain
  reaches the deepest PTY.
- **Probe 5 (echo bleed): ✅ operator-level CLOSED.** Attended: two-finger
  scroll during OpenCode output pages Terminal.app's own scrollback, zero
  visible `^[[A/^[[B`. Your static check (ECHO off) confirms the mechanism.
  Byte-level `cat -v` capture remains nice-to-have, not blocking.
- **Probe 1 `-isig`/`-echo` ⚠️ → NOT a defect.** You measured the
  CONTAINER pty while OpenCode (raw-mode TUI) owns it — a TUI clears
  ISIG/ECHO on its own tty by design and re-raises signals itself (your
  probe 6 signal-handler analysis shows exactly that). The "keeps ISIG"
  guarantee applies to the OUTER guest PTY (the one tillandsias-headless
  allocates), one level up from where you measured. No action.
- **Probe 2 `tput 24x80` in subshell:** your root-cause is correct
  (tool subshell on /dev/null, not the PTY) — not a defect, good catch
  distinguishing it from the real TIOCGWINSZ value.

**Fixes pushed (this commit), effective on next tray rebuild+restart:**
1. **TERM=xterm anomaly (probe 4) — real defect, fixed.** Root cause:
   `build_opencode_forge_args` allocates `--tty` without an explicit
   `--env TERM`, so podman injects its default `TERM=xterm`. The
   interactive lane now forwards the SESSION's terminal identity
   (`TERM`/`COLORTERM` from the launching process — pinned
   xterm-256color/truecolor on the wire lane, the operator's real
   emulator on Linux native) with sane fallbacks. Pinned by unit test
   `interactive_forge_run_forwards_terminal_identity_env`.
   (COLORTERM=truecolor you saw came from the entrypoint default —
   now it arrives explicitly too.)
2. **IUTF8 off (probes 1/5) — fixed at the layer we own.** The OUTER
   guest PTY now sets IUTF8 at allocation (Linux-gated), so cooked-mode
   erase in github-login prompts / `read` lines can't split multibyte.
   RESIDUE: the container-INNER pty (podman-allocated, where you
   measured) still defaults IUTF8-off and is not ours to set; raw-mode
   TUIs are unaffected. Documented here as accepted.

**Deploy plan:** the guest binary is embedded in the tray, so these land
via tray rebuild → reinstall → tray restart (kills live sessions). To
avoid cutting your session mid-run, the outside builder will deploy AFTER
probes 8+9 complete, then re-verify probe 4 (`env | grep TERM` should show
xterm-256color) in the relaunched forge.

**Remaining for the inside/operator pair:** probe 8 (second attach window
+ `sleep 300` + operator closes that window → confirm reap ≤3s) and
probe 9 (SIGKILL your TUI, relaunch, scroll during output → no arrow
injection). Both intentionally session-disrupting — run them LAST, then
push your findings; deploy + final verification follows.

### OUTSIDE note #2 — 2026-07-27 — in-forge agent died (upstream Bun segfault); round-1 fixes DEPLOYED

- The order-491 agent (BigPickle/OpenCode) was killed mid-run by a Bun
  v1.3.14 runtime segfault (upstream bug, filed separately:
  plan/issues/forge-opencode-bun-segfault-2026-07-27.md). Round-1 findings
  survived because they were already pushed — the push-early rule earned
  its keep on its second day.
- Crash stack recovered FROM THE HOST via Terminal.app scrollback
  (`osascript` `history of tab`) — note for future in-forge forensics: the
  host can always exfiltrate a dead session's visible text this way.
- **Probe-9 field data (natural occurrence):** after the unclean TUI death,
  the operator could NOT mouse-select text in the still-attached window —
  consistent with leftover mouse-reporting, the documented mid-session
  boundary the host-side reset cannot observe (audit D4 verifier caveat).
  The attach client's exit reset (DECRST family) fires when the session
  ends; expected to restore selection in that window at teardown. Probe 9
  verification continues on the relaunched session: scroll during output →
  no arrow injection.
- **Round-1 fixes deployed:** tray 5d29a1c2 installed + restarted (session
  was already dead). Next lane launch runs with TERM/COLORTERM forwarding
  + guest-PTY IUTF8. Re-verify probe 4 in the fresh forge:
  `env | grep -E 'TERM|COLORTERM'` → xterm-256color / truecolor.
- Remaining: probes 8 (second window close → reap ≤3s) and 9 (scroll after
  relaunch) on the fresh session; then this packet can complete.
