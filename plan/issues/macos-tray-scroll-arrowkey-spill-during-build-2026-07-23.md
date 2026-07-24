# macOS forge terminal: two-finger scroll spills literal `^[[A`/`^[[B` arrow-key sequences during a non-interactive build

- **Date:** 2026-07-23
- **Class:** bug (cosmetic output corruption) — macOS PTY / terminal-attach
- **Area:** macOS PTY / terminal-attach (Terminal.app `screen` ↔ vsock ↔ guest PTY)
- **Severity:** P3 — cosmetic. The build itself is unaffected (its bytes stream
  correctly); the spill is visual garbage over the log. But it violates the
  operator principle that an **output-only stream must never bleed input
  characters** (see below), so it is worth a real fix, not a shrug.
- **Owner host:** macOS (osx-next) — the echo bug is in the shared guest
  `pty_handler` (Unix), the terminal-side trigger is Terminal.app-specific.
- **Discovered by:** operator report during an attended macOS tray session — a
  container BUILD streaming output into the forge terminal.
- **Specs:** macos-native-tray.lifecycle.terminal-attach@v1,
  control-wire-pty-attach (Tasks 4.x), vsock-transport
- **Governance:** the DEFENSE-IN-DEPTH termios change alters guest PTY
  line-discipline *behavior*; the PRIMARY change alters the Terminal.app
  `screen`-attach launch. Both are attach-UX behavior → operator (Tlatoāni)
  sign-off before implementation.
- **Related:**
  - `plan/issues/macos-tray-attended-smoke-findings-2026-07-10.md` — m8 attended
    PTY findings; **F-J** (fast-failing agent attach loses its dying words to the
    popup's *alternate-screen teardown*; `TILLANDSIAS_PTY_DEBUG=1` tee in
    `pty_vsock_bridge.rs`) and **F-H** (the in-VM forge image build runs as a
    child of the attach session and streams into the same PTY on first use —
    that is exactly the non-interactive output phase in which this spill occurs).
  - Commit `8c6c8d05` "fix(pty): raw mode on host PTY + wire hardening for TUI
    apps" — put the **host** PTY into `cfmakeraw`. This packet documents why the
    same lever is **wrong for the guest** (it clears `ISIG` and would break
    Ctrl+C), and where the missing echo control actually belongs.
  - `plan/issues/opencode-tray-tui-escape-spill-2026-07-12.md` — related-BUT-
    DISTINCT escape spill (background npm installers sharing the TUI's TTY /
    live package rewrite). Different mechanism; listed so the two aren't
    conflated when triaging "the spilling-characters thing."

## Symptom (operator, attended macOS session)

The macOS tray forge terminal is Terminal.app running `screen /dev/ttysNNN`,
bridged over vsock to the in-guest forge (see
`crates/tillandsias-macos-tray/src/terminal_attach.rs:154` /
`spawn_terminal_pty_attach` `:267`). While a container **BUILD** is streaming
output (non-interactive — nothing is reading stdin), a **two-finger drag
(scroll)** over that window does NOT scroll the buffer. Instead, dozens of
literal escape sequences appear as text in the stream:

```
^[[A^[[A^[[A      (scroll up   → cursor-up    sent as input, echoed back)
^[[B^[[B^[[B      (scroll down → cursor-down  sent as input, echoed back)
^[[C / ^[[D       (right / left)
```

The `^[` caret-notation is the tell: that is how a TTY line discipline in
**cooked mode with `ECHOCTL`** renders an echoed ESC (0x1b) byte. So these bytes
are being **echoed** by a line discipline, not printed by the build.

## Mechanism (two conditions, both required; second is the verifiable defect)

Byte topology of one keystroke/scroll event:

```
Terminal.app (screen)
  → slave  /dev/ttysNNN
  → HOST UnixPtyMaster (raw: cfmakeraw)            unix.rs:114-146  [transparent]
  → vsock → pty_vsock_bridge reader/writer         pty_vsock_bridge.rs:218-325 [transparent]
  → GUEST pty master write (write_to_guest)         pty_handler.rs:272-326
  → GUEST pty slave line discipline  ← ECHO HERE    pty_handler.rs:448 (termios=None → cooked)
  → echoed bytes read back by the pump              pty_handler.rs:551-559
  → PtyData{ToHost} → vsock → host → screen → Terminal.app   (visible ^[[A…)
```

1. **Terminal.app translates the two-finger scroll into cursor-key sequences**
   and sends them *into* the PTY (alternate-scroll / mouse-reporting behavior)
   rather than scrolling its own scrollback. This is the *enabling* condition —
   see "Where the scroll→arrows comes from" below.

2. **The guest PTY is in cooked mode with `ECHO` on**, so those unconsumed input
   bytes are echoed straight back out as `^[[A`/`^[[B` and pumped to the host as
   output. **This is the defect that makes the spill visible**, and it is
   provable from source:

   - The guest allocates its PTY at
     `crates/tillandsias-headless/src/pty_handler.rs:448`:
     `let result = openpty(Some(&winsize), None)?;` — the **second arg is the
     termios and it is `None`**, so the slave gets the **kernel default line
     discipline: `ICANON | ECHO | ECHOCTL | ISIG` all ON** (cooked). Nothing in
     `pty_handler.rs` ever calls `tcsetattr`/`cfmakeraw` on it (confirmed: the
     only termios code in the crate tree is the HOST side).
   - The slave becomes the child's controlling tty + stdin/stdout/stderr via the
     `pre_exec` `dup2` (`pty_handler.rs:193-197`), child spawned at `:216`.
   - The HOST PTY is already `cfmakeraw` (`unix.rs:114-146`), i.e. a
     **transparent, non-echoing conduit** — so the echo is definitively NOT
     happening on the host. `pty_vsock_bridge.rs` only frames/relays bytes
     (`:218-325`) — no echo there either. **The echo is unambiguously the guest
     PTY's cooked-mode line discipline.**

During a non-interactive build, nothing reads the slave, so scroll-generated
arrow keys sit in the input queue and the line discipline echoes them — exactly
the reported `^[[A/^[[B` bleed.

### Why the build still works / why Ctrl+C still works today
The arrow keys are harmless to the build (nothing reads them). Ctrl+C works
because the **guest** PTY keeps `ISIG` on: a 0x03 byte typed in Terminal.app
passes transparently through the raw host PTY and vsock, and the guest line
discipline delivers `SIGINT` to the build's foreground process group. **Ctrl+C
does NOT require any process to be actively reading stdin** — `ISIG` acts at the
line-discipline level. Any fix here MUST preserve that.

### Termios state today (the crux)
| PTY | Where | ECHO | ISIG | Role | Correct? |
|-----|-------|------|------|------|----------|
| HOST | `unix.rs:114-146` (`cfmakeraw`) | OFF | OFF | transparent conduit (Ctrl+C is a passthrough byte, must NOT be interpreted here) | yes |
| GUEST | `pty_handler.rs:448` (termios `None`) | **ON ← bug** | ON (needed for Ctrl+C) | endpoint / signal owner | ECHO wrong |

The guest is the *endpoint* (owns signals) — it correctly keeps `ISIG`, but it
should NOT echo an output-only stream. Note this is the mirror-image of the
host: the host is `cfmakeraw` precisely because it must be signal-**transparent**
(that is why `8c6c8d05` turned `ISIG` off there); copying `cfmakeraw` to the
guest would wrongly turn `ISIG` off on the signal **owner** and break Ctrl+C.

## Where the scroll→arrows comes from (the enabling condition)

Grepping the whole repo for mouse-reporting / alternate-scroll / alt-screen
setup (`?1000 ?1002 ?1006 ?1007 ?1049`, `DECSET`, `altscreen`, `screenrc`,
`mouse`) returns **zero hits** — *we* never enable mouse reporting. So the
scroll→arrows is Terminal.app-side, from one of:

- **(most likely) a leftover mode from a prior full-screen TUI agent leaf.** m8
  finding F-J documents agent leaves (Claude/OpenCode/Codex) using the alternate
  screen + mouse tracking and exiting through an *alternate-screen teardown* that
  already eats text. A TUI that crashes/exits without emitting the `DECRST`
  reset (`\e[?1002l\e[?1006l\e[?1049l`) leaves Terminal.app in a mode where the
  wheel/scroll is reported as cursor keys; a subsequent build stream inherits it.
- **(possible) Terminal.app's built-in alternate-scroll** while the window is on
  the alternate screen buffer (some `screen`/termcap configurations advertise
  `smcup`/`rmcup`).

Pinning the exact trigger needs a live repro that captures the private-mode
state (`\e[?1002$p` etc.) at the moment of the build stream. But the fix does
not have to wait on that: per the operator principle, we stop scroll from ever
reaching the PTY (primary) AND stop the guest from echoing an output-only stream
(defense-in-depth). Either alone kills the visible spill; together they are
robust to whichever trigger is live.

## Recommended fix (ranked; smallest robust set)

Operator principle to encode: **an output-only stream must NEVER bleed input
characters (arrow keys or anything), harmless or not.**

### PRIMARY — stop the scroll reaching the PTY at all (operator wants scrollback)
The operator actually wants two-finger scroll to page back through the **build
log**, i.e. Terminal.app should scroll its **own** buffer. Make the output-only
phase keep Terminal.app in the normal buffer with mouse-reporting off:

- **File:line:** `crates/tillandsias-macos-tray/src/terminal_attach.rs:154-169`
  (`applescript_for_screen_attach`, launched by `spawn_terminal_pty_attach`
  `:267`). At session start, before/around the `screen` launch, assert a
  mouse/alt-screen **reset** (`printf '\e[?1000l\e[?1002l\e[?1006l\e[?1007l\e[?1049l'`)
  and/or launch `screen -c <rc>` with the normal-buffer kept so native scroll
  works during output-only streaming.
- **Tradeoff / must-not:** do NOT *permanently* disable the alternate screen or
  mouse (a blanket `termcapinfo xterm* 'ti@:te@'` in a screenrc is therefore
  **rejected**) — the interactive TUI agents legitimately use alt-screen + mouse
  and re-enable their own modes when they take over. The reset must be scoped to
  the output-only phase (assert it at the output-only→interactive boundary; the
  interactive TUI's own `DECSET` on startup restores its modes).

### DEFENSE-IN-DEPTH — guest PTY `ECHO` off (keep `ISIG` on) for output-only phases
Even with the primary fix, the endpoint should never echo an output-only stream.

- **File:line:** `crates/tillandsias-headless/src/pty_handler.rs:448` (the
  `openpty(Some(&winsize), None)` call) — supply a termios (or `tcsetattr` the
  slave immediately after allocation, before the `pre_exec`/spawn at `:193-216`,
  while `openpty_owned` still holds the slave fd `:440-453`) that clears the
  echo family (`ECHO | ECHOE | ECHOK | ECHONL | ECHOCTL`) while **keeping
  `ISIG`** (and, being output-only, `ICANON` is moot).
- **Target termios during output-only phases:** `ECHO` **off** (stops the
  bleed) + `ISIG` **on** (Ctrl+C still delivers SIGINT to the foreground pgrp).
- **Do NOT use `cfmakeraw` here** — it clears `ISIG` (that is exactly why the
  host uses it and the host must NOT own signals) and would break Ctrl+C on the
  signal-owning endpoint. This is the one-line lesson vs. `8c6c8d05`: `cfmakeraw`
  is correct for the transparent conduit, wrong for the endpoint.
- **Interactive tools are unaffected:** when an agent/TUI or `podman exec -it`
  takes over, it puts its side into raw mode itself and manages its own echo, so
  clearing the default PTY `ECHO` does not regress interactive sessions (readline
  and the TUIs do their own echo). This mirrors the conduit-vs-endpoint reasoning
  of `8c6c8d05`, applied at the guest allocation.

### Explicitly REJECTED options
- **`cfmakeraw` on the guest PTY** — clears `ISIG`, breaks Ctrl+C on the endpoint
  that owns signals (see above).
- **Redirect the build's stdin to `/dev/null`** — WRONG lever. The echo happens
  in the **PTY line discipline, before any process reads the slave**; pointing a
  process's fd 0 at `/dev/null` does not stop the *driver* from echoing bytes
  written into the slave's input queue (and note `pty_handler`'s `pre_exec`
  already `dup2`s the slave over fds 0–2 anyway, `:193-197`). It also muddies
  signal handling. `termios ECHO off` is the correct control point.
- **A host-PTY termios change** — the host PTY is already `cfmakeraw`
  (`unix.rs:114-146`); the echo is not there. No host change helps.
- **Blanket `screenrc`/copy-mode (`ti@:te@`) disabling the alt-screen** — would
  break the interactive TUI agents' alt-screen + mouse. Rejected in favor of the
  phase-scoped reset above.

## Verifiable closure (reproduce the break first)
1. **Guest-echo unit fixture:** open a guest PTY session running an output-only
   command (e.g. a long `printf` loop), write an ESC-`[`-`A` sequence into the
   master via `write_to_guest`, and assert the pump does **NOT** emit those bytes
   back (`ToHost`) — after the fix. First reproduce: assert it DOES echo today.
2. **Ctrl+C preserved:** with `ECHO` off + `ISIG` on, write 0x03 into the master
   and assert the child receives `SIGINT` (foreground pgrp), i.e. the fix did not
   regress interrupt.
3. **Attended macOS repro:** during a first-use forge build stream (F-H phase),
   two-finger scroll → Terminal.app scrolls the build log with **no `^[[A/^[[B`
   spill**; then an interactive agent leaf still gets working mouse/alt-screen.

## Non-goals
Do not change the host PTY raw-mode (`8c6c8d05` is correct). Do not permanently
disable alt-screen/mouse for interactive TUI agents. Do not attempt to make the
build "consume" the arrow keys — the point is that an output-only stream must not
receive or echo them.
