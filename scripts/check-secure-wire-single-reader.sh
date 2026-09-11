#!/usr/bin/env bash
# @trace order:972-umik
#
# check-secure-wire-single-reader.sh — TILLANDSIAS_SECURE_CONTROL_WIRE has ONE
# reader, and this ratchets the number of files that name it down, never up.
#
# WHY A RATCHET AND NOT A REFUSAL. Three of the six original readers sit behind
# `#[cfg(target_os = ...)]` for platforms this host cannot compile:
# macos-tray/action_host.rs and macos-tray/diagnose.rs are macOS-only,
# windows-tray/hvsocket.rs is Windows-only. A Linux host can convert and VERIFY
# three of six; the rest need the hosts that can build them. Refusing outright
# would red the trunk on work no single host can finish, which is how a gate
# gets switched off.
#
# WHAT THE DIVERGENCE COST, measured 2026-09-04. Six readers, THREE behaviours:
# four parsers erred loudly on an unknown value; vm-layer/vz.rs mapped
# everything but "on" silently to "off" AND wrote that into the guest's systemd
# unit; windows-tray/hvsocket.rs compared bytes case-SENSITIVELY, so `On` was
# silently plaintext. An operator writing `1`, because every other flag takes
# it, got a loud refusal on four surfaces and an insecure client on a fifth.
#
# THE DECISION IS ATOMIC. The default flips from Off to On in the commit that
# converts the LAST reader — not before. Flipping one side of a handshake is
# not a smaller version of flipping both: on 2026-09-05 the listener alone was
# flipped (e6a80609f) and every client, still defaulting to plaintext, was
# refused by the server it had just been told to trust. Reverted at 08a7d3cc7.
# BASELINE REACHED 0 AND THE FLIP LANDED (commit B). The proof is a sabotage
# arm, not a green: a peer left on plaintext is refused by the now-secure
# default (windows-tray/hvsocket.rs), verified discriminating by a negative
# control in which the same peer completes a real handshake and the arm reds.
#
# Grammar (one line on stdout):
#   ok:secure-wire-single-reader:<n> of <baseline>
#   violation:secure-wire-readers-grew:<n> of <baseline>
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Files still reading the variable outside the one owning module. It must never
# rise. 972-umik commit B lowered it to its final value: ZERO. Every reader is
# converted, so the ratchet is now a REFUSAL and not a tolerance.
#
# WHY IT DID NOT STAY AT 3. The baseline existed because three readers sat
# behind cfgs for platforms a Linux host cannot compile, and refusing outright
# would have redded the trunk on work no single host could finish. That reason
# is SPENT: macbookair converted the two macOS readers (311aa27d5) and yolanda
# converted windows-tray/hvsocket.rs (7623213e2). A tolerance kept past the
# condition that justified it is not caution, it is a hole.
#
# MEASURED BEFORE CHANGING IT (yolanda, commit B): with the default flipped to
# On and the hvsocket converter reverted by hand, the count went 0 -> 1 and the
# script still exited 0. So the exact regression this packet exists to prevent --
# one end defaulting to plaintext while the other refuses it, the e6a80609f
# outage -- passed the gate silently. The flip and this line are the same
# decision and must land together.
BASELINE="${TILLANDSIAS_SECURE_WIRE_READER_BASELINE:-0}"

ENV_NAME="TILLANDSIAS_SECURE_CONTROL_WIRE"
OWNER="crates/tillandsias-control-wire/src/secure_wire_mode.rs"

# Count FILES, not occurrences: the unit that matters is the number of places
# that decide, and one file deciding twice is still one decision site. A log
# line or a doc comment naming the variable is not a reader, so match only a
# std::env read of it.
readers="$(grep -rl --include=*.rs -E "env::var\\(\"$ENV_NAME\"\\)|env::var\\($ENV_NAME\\)" crates/ 2>/dev/null \
            | grep -v "^$OWNER\$" | LC_ALL=C sort)"
count="$(printf '%s\n' "$readers" | grep -c . || true)"

if [ "$count" -gt "$BASELINE" ]; then
    echo "violation:secure-wire-readers-grew:$count of $BASELINE"
    {
        echo "  A new file reads $ENV_NAME directly. It has ONE reader:"
        echo "  tillandsias_control_wire::secure_wire_mode. Six copies with three"
        echo "  behaviours shipped a plaintext client to anyone who capitalised a"
        echo "  word (972-umik); a seventh would reopen that."
        echo "  AND THE DEFAULT IS NOW ON: a reader with its own parser defaults"
        echo "  to PLAINTEXT against a server that refuses it, which is not a"
        echo "  silent insecurity but the e6a80609f OUTAGE. Call"
        echo "  tillandsias_control_wire::secure_wire_mode::secure_wire_mode()."
        echo "  Readers found:"
        printf '%s\n' "$readers" | sed 's/^/    /'
    } >&2
    exit 1
fi

if [ "$count" -gt 0 ] && [ "$count" -le "$BASELINE" ]; then
    echo "  $count reader(s) remain under a raised baseline of $BASELINE:" >&2
    printf '%s\n' "$readers" | sed 's/^/    /' >&2
fi

echo "ok:secure-wire-single-reader:$count of $BASELINE"
