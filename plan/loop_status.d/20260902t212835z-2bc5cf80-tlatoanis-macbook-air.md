## Cycle 2026-09-02T21:28Z — tlatoanis-macbook-air (osx-next)

702-6jza, the packet no other host can verify. Claimed, both items advanced,
released to ready (not closed).

(a) D1 VERIFIED VISUALLY. The attach client boots no VM and touches no AppKit,
so D1 is testable without a forge: a throwaway PTY harness + the real tray
binary as --attach-pty in a real Terminal.app window, two arms differing in one
line. With SCREEN_HOME: GUESTROW01 at window row 1, screen clean. Without it:
prior content bleeds through every row plus six untouched banner lines below.

CORRECTION TO THE PACKET, recorded on the row. next_action predicted the
"offset returns" on falsification. It does not — MODE_RESET's DECRST 1049
already homes the cursor, and SCREEN_HOME's job is the ERASE. The failure mode
is bleed-through, not vertical offset. An agent looking for a shifted first row
would have found none and could have called the fix inert. Also: never seed
such a test with `clear` — on Terminal.app that uses the alt screen, so
MODE_RESET alone erases the banner and the test reads as a false negative. My
first attempt did exactly that.

(b) D2 IMPLEMENTED. Measured here: a real window is 39x131, the default profile
30x120, so the 24x80 fallback was wrong on both axes. The tray now tags the
window it opens (uniqueness inherited from the per-attach session socket) and
reads its real geometry back on the timeout path. `tty of tab` cannot serve —
it is the window's own tty, never the slave we allocated (five tabs, five ttys,
none of them the slave).

The headless negative control is structural: osascript with no GUI session can
block forever, so an unbounded query would turn a launch that merely LOOKED
wrong into one that hangs. Guarded twice — the query runs only when the spawn
actually succeeded (its Result is now the discriminator rather than logged and
dropped), and it is bounded with kill_on_drop.

20 unit tests including a zero-dimension negative control (it parses, and would
seed a degenerate PTY worse than the 24x80 it replaces), plus a macOS-only
#[ignore] test that drives the REAL generated AppleScript against the REAL
Terminal.app instead of asserting on strings.

NOT CLOSED: the D2 mechanism is proven, an end-to-end forge attach inside a
booted VM is not. Needs a host that can boot the macOS VM.

Gate green (168s). 935-6fzk not started.
