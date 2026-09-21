#!/usr/bin/env bash
# @trace spec:ci-release
# @trace order:1308-9ej7
#
# Pin 1308-9ej7: a staged guest binary that CANNOT SERVE THE CONTROL WIRE is
# refused at STAGING TIME, not 524 seconds into a provision.
#
# PRE-FIX RESULT, measured on yolanda 2026-09-20: a guest built without
# `--features listen-vsock` compiled, staged, embedded, installed into the
# guest and RAN, printing the correct version at every step, and never bound
# the wire. The provision failed after 524 s on a handshake timeout, and only
# the guest's own runtime refusal named the cause. Every version-comparing
# check in the staging path passed on it, because the VERSION string is
# identical in both builds.
#
# WHY THE CHECK IS A NEGATIVE MARKER AND NOT A VOCABULARY PROBE, measured
# rather than assumed. Comparing a listen-vsock build against a feature-less
# control built from the same source:
#     tokio_vsock     good 2   control 2
#     VsockListener   good 3   control 3
#     vsock_loopback  good 2   control 2
#     AF_VSOCK        good 14  control 16   <- the control has MORE
#     vsock           good 206 control 206
# The vsock vocabulary links into both binaries; the feature gates the
# LISTENER, not the words. A probe asserting any of those tokens is PRESENT
# would pass the very binary it exists to catch. What discriminates is the
# binary's own self-declaration -- the refusal it prints at runtime when the
# feature is absent -- so the check asserts that string is ABSENT.
#
# AND IT PROVES ITS INSTRUMENT FIRST. `strings(1)` is not installed on the
# Windows hosts, and a reader that finds nothing is indistinguishable from a
# binary that contains nothing: subject and control both read 0 and the check
# passes by being blind. Every arm here asserts the reader can find a token
# known to be present before it trusts an absence.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

SRC="${TILLANDSIAS_GUEST_STAGING_SRC:-scripts/build-guest-binaries.sh}"
[ -f "$SRC" ] || { echo "blocked:guest-staging-wire-check:no-script:$SRC"; exit 1; }

fail=0
_ok()  { echo "ok: $1"; }
_bad() { echo "FAIL: $1"; fail=1; }

# Source only the helper definitions, so this fixture tests the REAL ones
# rather than a transcription that can drift.
HELPERS="$(mktemp)"; trap 'rm -f "$HELPERS"' EXIT
sed -n '/^_guest_strings()/,/^}/p;/^_guest_reader_works()/,/^}/p;/^_GUEST_NO_VSOCK_MARKER=/p;/^guest_binary_serves_wire()/,/^}/p' "$SRC" > "$HELPERS"
if ! grep -q 'guest_binary_serves_wire' "$HELPERS"; then
    _bad "the staging script defines no guest_binary_serves_wire -- the check this row asks for is absent"
    echo "FAIL:guest-staging-refuses-a-wireless-binary"; exit 1
fi
# shellcheck disable=SC1090
. "$HELPERS"
_ok "the staging script defines the wire-capability check"

TMP="$(mktemp -d)"; trap 'rm -f "$HELPERS"; rm -rf "$TMP"' EXIT

# Synthetic stand-ins: the check reads STRINGS, so a file carrying the marker
# is indistinguishable to it from a real feature-less binary. Using files
# rather than a 90-second cargo build keeps this an `instant` fixture; the
# real control pair was measured when the check was written and its numbers
# are in the header above.
printf 'tillandsias headless 56.9.19.2\nsome other text\n' > "$TMP/good.bin"
printf 'tillandsias headless 56.9.19.2\nFATAL: built WITHOUT the listen-vsock feature, so no listener can be bound\n' > "$TMP/bad.bin"
printf 'no relevant tokens whatsoever\n' > "$TMP/unreadable.bin"

# ARM 1 -- a wire-capable staging passes.
if guest_binary_serves_wire "$TMP/good.bin" >/dev/null 2>&1; then
    _ok "a staged binary without the marker is accepted"
else
    _bad "a wire-capable staged binary was refused"
fi

# ARM 2 -- THE DEFECT. A feature-less staging is refused, and the refusal
# names the remedy rather than merely failing.
out="$(guest_binary_serves_wire "$TMP/bad.bin" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ]; then
    _ok "a staged binary built without listen-vsock is REFUSED"
else
    _bad "a feature-less staged binary was accepted (rc=$rc) -- it would fail a provision 524s later"
fi
case "$out" in
    *"--features listen-vsock"*) _ok "the refusal names the remedy" ;;
    *) _bad "the refusal does not name --features listen-vsock: $out" ;;
esac

# ARM 3 -- THE BLIND-READER CASE, which is the one that would make every other
# arm vacuous. A file the reader cannot find its control token in must be
# UNMEASURED, never "good".
out="$(guest_binary_serves_wire "$TMP/unreadable.bin" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
    _ok "a binary the reader cannot read is UNMEASURED, not passed"
else
    _bad "a binary with no readable control token returned rc=$rc; a blind check must not report good"
fi

# ARM 4 -- THE READER WORKS WITHOUT strings(1). The Windows hosts have no
# strings, and that is why the staleness predicate used to report "stale"
# about binaries that had just been staged correctly.
#
# THIS ARM EXERCISES THE FALLBACK EXPRESSION ITSELF rather than faking a PATH.
# My first version set PATH=/nonexistent to hide strings -- which also hides
# grep, so the fallback could not run and the arm failed for a reason that had
# nothing to do with the code. A control that cannot work is not a control.
fallback_out="$(LC_ALL=C grep -a -o '[[:print:]]\{4,\}' "$TMP/good.bin" 2>/dev/null | grep -c tillandsias)"
if [ "${fallback_out:-0}" -ge 1 ]; then
    _ok "the strings-free fallback expression finds tokens (grep -a)"
else
    _bad "the grep -a fallback found nothing; the predicate would be blind where strings(1) is absent"
fi

# ...and the dispatcher must actually USE it when strings is unavailable.
# Shadowing `command` is not possible portably, so this asserts the branch
# exists in the source rather than simulating its absence -- stated plainly
# rather than dressed up as a behavioural check.
if grep -q 'grep -a -o' "$HELPERS"; then
    _ok "the reader carries a strings-free branch"
else
    _bad "the reader has no fallback branch; it depends on strings(1)"
fi

[ "$fail" -eq 0 ] && echo "ok:guest-staging-refuses-a-wireless-binary:all" || echo "FAIL:guest-staging-refuses-a-wireless-binary"
exit "$fail"
