# macOS forge OpenCode terminal render — two root causes (geometry + lost events)

- **Date:** 2026-07-25
- **Class:** bug (host-side / builder-fix, `methodology/next-forge-better.yaml` out_of_forge_builder_fix)
- **Area:** macOS tray PTY attach (`screen` bridge + host-shell PTY router)
- **Status:** FIXED (both), pending live operator confirmation.
- **Provenance:** the "lost events" half was independently root-caused in-forge by BigPickle
  (OpenCode) but its writeup died with the forge before pushing (not on origin, not on `~/src`,
  and the git-mirror volume matched origin exactly — nothing was ever pushed). Reconstructed here
  from the operator's summary ("terminal size and encoding, some events are getting lost; quickie
  fix; requires a relaunch") plus the code.

The operator's persistent "börked terminal" (OpenCode rendering scrambled + garbled UTF-8) was
**two independent host-side bugs**, both requiring only a tray rebuild + relaunch (no forge rebuild):

## 1. Geometry: `screen <device>` never propagates winsize

`terminal_attach.rs::applescript_for_screen_attach` ran bare `screen <slave>`. GNU `screen`
attached to a device path treats it as a **serial line**, which has no winsize concept, so it
never stamps Terminal.app's window dimensions onto the PTY. The slave stayed at the host
`UnixPtyMaster::open(24, 80)` default → the tray's seed poll timed out at 24×80 → the guest forge
PTY was born at 80 cols → OpenCode's TUI clipped at 80 forever, and leftover build output bled into
the columns a wider window exposed.

**Fix:** before `screen`, stamp the slave winsize from Terminal.app's real size —
`_r=$(tput lines); _c=$(tput cols); stty -f <slave> rows $_r cols $_c` — so the seed poll reads the
true geometry. Verified live: seed went from 24×80 → **30×120**. (`action_host.rs` seed poll also
bumped 30→50 iterations for cold Terminal.app launches.)

Follow-up (not yet done): live mid-session **resize** still won't reflow (screen-serial won't
forward SIGWINCH); the launch size is correct.

## 2. Lost events: `PtyRouter::route` dropped terminal output

`PtyRouter::route` (`tillandsias-host-shell/src/pty/mod.rs`) delivered guest→host terminal output
via `let _ = tx.try_send(SessionEvent::Data(..))` into a **256-deep bounded** per-session channel —
discarding the result. When the consumer (screen → Terminal.app) drained slower than the guest
produced — **exactly a full-screen TUI redraw burst** — the channel filled and frames were silently
**dropped**. A dropped frame both scrambles the render AND splits a multi-byte UTF-8 sequence (the
"encoding" corruption the operator and in-forge agents kept fighting). The code comment even claimed
it "applies backpressure" — but `try_send`+discard does the opposite.

**Fix:** make `route` `async` and `send().await` (clone the `Sender`, release the mutex before the
await). A full channel now blocks the vsock reader, applying **real backpressure** through the guest
PTY to the writing process — proper terminal flow control: lossless, and bounded host memory (unlike
an unbounded channel, which a runaway forge process could OOM). Sole production caller is the macOS
`pty_vsock_bridge` reader task; the rest are unit tests (all updated + passing).

## Files

- `crates/tillandsias-macos-tray/src/terminal_attach.rs` (winsize seed)
- `crates/tillandsias-macos-tray/src/action_host.rs` (seed poll window)
- `crates/tillandsias-host-shell/src/pty/mod.rs` (`route` async + backpressure)
- `crates/tillandsias-macos-tray/src/pty_vsock_bridge.rs` (await `route`)
