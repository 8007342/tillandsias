# macOS terminal management audit — the chain skips the terminal contract; attach-client redesign

- **Date:** 2026-07-27
- **Class:** audit + fix decision (P0 umbrella) — macOS PTY / terminal-attach
- **Provenance:** 14-agent adversarial audit workflow (6 leg readers over
  macos-tray / host-shell+linux-ref / guest-headless / wire / windows-ref /
  specs+prior-art, 1 synthesis, 7 verifiers), run 2026-07-27 on osx-next
  working tree (includes ea2fbc8d backpressure + 3d1cba4c winsize seed).
  All 7 defects CONFIRMED by independent refutation-oriented verifiers.
- **Operator sign-off:** The Tlatoāni, 2026-07-27, this session — explicit
  directive: "let's make sure we handle terminal management properly …
  audit the implementation, file ./plan findings and implement the required
  fixes, then do a full build with provisioning from scratch (destructive
  ok)". This records the tray-ux-governed approval for the attach-UX
  changes below (tray-ux spec.md:20-46), including replacing the
  `screen`-based attach.
- **Related prior art (all subsumed or advanced by this packet):**
  - `macos-opencode-pty-resize-not-propagated-2026-07-12.md`
  - `macos-tray-pty-window-resize-not-forwarded-2026-07-23.md`
  - `macos-tray-scroll-arrowkey-spill-during-build-2026-07-23.md`
  - `macos-forge-opencode-terminal-render-2026-07-25.md`

## Root insight (why macOS "skips terminal management")

Linux native and Windows/WSL2 are stable because **neither implements
terminal management in-repo — both delegate the whole contract to a real
terminal client living inside the window** (podman inherits the emulator's
tty; wt.exe+wsl.exe bridge ConPTY events natively). macOS instead interposes
`screen <slave>` — a **serial-line attach with no winsize concept, no resize
forwarding, no mode hygiene** — against a host PTY whose termios/winsize
nothing maintains, plus a guest PTY left in kernel-default cooked mode.
Terminal state (echo, winsize, mode resets, env) is therefore not "piped
through the channel" because **no process in the macOS chain owns it**.

## Confirmed defects (all verdicts CONFIRMED; anchors = osx-next @ ea2fbc8d)

| ID | Sev | Defect | Anchor |
|----|-----|--------|--------|
| D1 | P0 | Live resize structurally dead: `screen`-serial never re-stamps winsize after the one-shot `stty` seed; the tray's 400ms master-`TIOCGWINSZ` poll watches a value with no writer (`UnixPtyMaster::resize` has zero production callers); tray is a GUI process, gets no SIGWINCH. Both the 400ms poll and the 100ms seed loop also violate the hard no-polling policy. Wire `PtyResize` verb + guest handler are correct and dormant (WSL2-proven). | action_host.rs:1204-1221, 1241-1260; terminal_attach.rs:173-176; unix.rs:173-192 |
| D2 | P1 | Guest PTY allocated `openpty(Some(&winsize), None)` → cooked, `ECHO\|ECHOCTL` on; no `tcsetattr` anywhere in tillandsias-headless. Unconsumed input (scroll→arrow keys) echoes back as literal `^[[A`/`^[[B` over output-only streams — **the character bleeding**. Latent on all platforms, expressed on macOS. | pty_handler.rs:448 |
| D3 | P2 | Host→guest input drop-then-die: `ChannelPtyTransport::send` maps `Full`==`Closed`; pump_io input task `return`s on first `Full` (32-deep queue) → terminal silently read-only forever; resize sender same conflation. Asymmetric un-fixed twin of ea2fbc8d. | pty/mod.rs:283-289, 567-571; action_host.rs:1251-1253 |
| D4 | P2 | Zero DECRST mode-reset at attach/detach boundaries (mouse 1000/1002/1003/1006/1007, alt-screen 1049) — the enabling condition turning two-finger scroll into arrow-key input. Verifier caveat: boundary resets are hygiene; D2 is the lever that kills the visible spill (mid-session TUI-crash boundary is not host-observable). | terminal_attach.rs:173-177 |
| D5 | P2 | `split()` retains the slave fd (`Some(self._slave)`, contradicting the documented contract) → master reads never EOF after the window dies; `PtySession::close` has zero production callers; guest child (podman harness) leaks on window close. Verifier: retention may be load-bearing for raw-termios persistence (landed WITH cfmakeraw in 8c6c8d05) — do NOT flip without a live termios-persistence probe. | unix.rs:304; pty/mod.rs:474-479, 520-531 |
| D6 | P2 | Guest `write_to_guest` awaits `master.writable()` unboundedly INLINE in the single connection select loop → a full slave input queue (nothing reading during cooked build phases; kernel buffer ≈12KB < one 64,000-byte frame) wedges output, resize, close, and control replies for the whole connection. Violates the ≤250ms control-plane fairness bound. | pty_handler.rs:284-325 @ vsock_server.rs:1079 |
| D7 | P2 | Env sends exactly `TERM=xterm-256color`; delta spec default list requires TERM, LANG, LC_ALL, COLORTERM. Direct guest children run in POSIX C locale (no IUTF8 → backspace can split UTF-8) and lose truecolor detection. | pty/mod.rs:249 |

Full leg maps, matrix, and verifier evidence: workflow output archived in the
session; condensed matrix below.

Raw mode / echo / live-resize / mode-reset / env matrix (macOS today):
host pair raw-at-open only; guest cooked+ECHO (BROKEN); live winsize
structurally dead (BROKEN); boundary resets ABSENT; env TERM-only (BROKEN).
Linux/Windows: every dimension PRESENT by delegation, zero in-repo termios.

## Decision (this checkpoint implements)

**Strategy B — attach-client subcommand replaces `screen`** (mirrors the
proven wsl.exe helper-in-the-window pattern; evaluated against (A) keep
screen + polls — rejected: non-functional AND policy-violating; and (C)
full byte-transport over the tray socket dropping the host PTY pair —
correct end-state, staged as follow-up, not needed for any confirmed defect):

1. **D1+D4**: new `tillandsias-tray --attach-pty <slave> --session-sock <sock>`
   mode (dispatch before the AppKit singleton guard, like `--diagnose`).
   The client: saves+cfmakeraw's its OWN Terminal.app tty (restore on exit);
   pumps stdin↔slave byte-transparently; on start sends `Hello{rows,cols}`
   and on each real SIGWINCH stamps `TIOCSWINSZ` on the slave and sends
   `Resize{rows,cols}` over the per-session unix socket (event-driven, no
   polling anywhere); emits scoped DECRST reset at entry/exit; prints the
   end-of-session banner (order 269 F-G preserved). Tray side: mints the
   socket before spawning Terminal.app, gates `PtyOpen` on `Hello` (deletes
   the 100ms seed loop), forwards `Resize` via the resize sender (deletes
   the 400ms poll), and treats client disconnect as detach → sends
   `PtyClose` so the guest reaps the child (closes the D5 leak-on-window-
   close user story without touching the risky slave-retention semantics).
2. **D2**: guest slave termios — clear echo family
   (`ECHO|ECHOE|ECHOK|ECHONL|ECHOCTL`), keep `ISIG` (and everything else)
   ON. Scoped: skip for the `--github-login` argv (cooked typed input relies
   on kernel echo). Rejected options stay rejected: no `cfmakeraw` on guest,
   no stdin→/dev/null, no host termios change, no blanket `ti@:te@`.
3. **D3**: lossless host→guest — add an awaited send path used by pump_io's
   input loop and the resize sender (mirror of ea2fbc8d); sync `send()`
   keeps its behavior for open/close and existing tests.
4. **D7**: launch_spec env → forward-with-fallback TERM (xterm-256color),
   COLORTERM (truecolor), LANG (C.UTF-8 — NOT en_US.UTF-8: the VM rootfs
   lacks glibc-langpack-en; NOT LC_ALL: too heavy per verifier).
5. Spec: `macos-native-tray.lifecycle.terminal-attach` bumped to @v2
   describing the attach-client contract.

## Deferred (own packets, filed alongside)

- **D5 full fd-lifetime fix** → `plan/issues/host-pty-slave-retention-eof-teardown-2026-07-27.md`
  (needs live termios-persistence probe first; client-detach covers the
  operator-visible leak meanwhile).
- **D6 guest write wedge** → `plan/issues/guest-pty-write-wedge-2026-07-27.md`
  (guest-side refactor + wedge deadline; D4/D2 remove the common trigger).
- **Live verification items** (Terminal.app exec of bundled binary,
  controlling-tty acquisition, scroll semantics post-DECRST, resize
  end-to-end into the container, github-login echo scoping check) →
  `plan/issues/bigpickle-macos-terminal-cooperative-debug-2026-07-27.md` (P0,
  in-forge cooperative debugging protocol).

## Exit criteria for this packet

- OpenCode/Claude/Codex TUIs in the macOS tray lane: correct size at first
  frame (no 24x80 fallback in the normal path), live reflow on window
  resize, no `^[[A`/`^[[B` bleed during build streams, Ctrl+C reaches the
  harness, window close reaps the guest child.
- Zero polling loops in the attach path (grep: no `sleep.*loop` winsize
  watchers in action_host.rs).
- All existing unit tests green + new pins for: attach-client AppleScript
  body, Hello/Resize framing, guest echo-off termios, lossless input send.

## Review round (2026-07-27, pre-checkpoint)

A 16-agent adversarial review of the implementation diff confirmed 9
findings (12 further overflow items were duplicates); all were fixed in the
same checkpoint:

- **Env pinning:** `launch_spec` env is PINNED (TERM=xterm-256color,
  COLORTERM=truecolor, LANG=C.UTF-8), NOT forwarded from the tray process —
  the tray's inherited env describes whatever launched the tray, never the
  tray-spawned window; forwarding en_US.UTF-8/xterm-kitty would reintroduce
  the exact D7 locale/terminfo failures. Recorded deviation from the
  control-wire-pty-attach delta forward-list (its forward-from-host premise
  is wrong for GUI trays); LC_ALL stays unset.
- **Unconditional detach teardown:** the session-control task now sends the
  bounded (5s) in-band `PtyClose` and then ALWAYS aborts the per-attach
  bridge — covering the never-attached lane (TCC-denied osascript, window
  closed pre-connect) and the wedged-writer-queue lane (D6): dropping the
  vsock connection drives the guest's connection-scoped `shutdown_all`
  reap out-of-band. Resize forwards are bounded (5s) for the same reason.
- **Socket-file cleanup** on the PtyOpen error path (was leaked per failed
  attach).
- **Attach client:** 1s write-timeout on the session socket (a blocking
  write sat in the event loop); one post-registration winsize re-read
  closes the Hello→SIGWINCH-registration TOCTOU gap (Terminal.app settles
  geometry asynchronously after `do script`).
- **D2 echo scope amended:** the bare-VM `/bin/bash -l` debug shell keeps
  kernel echo (readline restores startup termios before each foreground
  command, so its cooked non-readline children would type blind).
  ACCEPTED RESIDUE: a cooked `read` prompt inside a `-lc` provisioning
  stream types blind — that lane is output-only by design. Windows lanes
  unaffected (wt.exe/wsl.exe path never sends PtyOpen).
- **Docs/specs:** iTerm2 invariant rescoped to the stub-window flow;
  13 stale terminal-attach@v1 traces bumped to @v2; orphaned master-side
  winsize machinery deleted (with a do-not-reintroduce note); stale
  `screen`-era comments rewritten; cheatsheets/runtime/macos-pty-attach.md
  rewritten for @v2.

Refuted (no change): client stale-slave-fd ordering, guest echo overreach
on podman lanes, session-socket framing resync.
