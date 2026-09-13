#!/usr/bin/env bash
# @trace order:1139-xe5m, spec:accel-capability-probe
#
# REGIME: hermetic in the cache, LIVE on the host. XDG_CACHE_HOME is redirected
# into a temp dir so no arm can read or write this host's real capabilities.json
# (order 815-gdjk made that variable the ONE cache-root resolution, which is why
# redirecting it is sufficient). The probe itself really runs and really reads
# this machine — deliberately: the defect was in what the PRODUCT emits, and a
# fixture that hand-built documents would pin the library while the command an
# operator runs stayed ambiguous. The unit tests beside `load_or_probe_at` pin
# the library half.
#
# NO ABSOLUTE TIMESTAMP IS ENCODED ANYWHERE HERE. The whole subject is a
# timestamp being replayed, so the arms compare run-1's value against run-2's
# rather than against any value written into this file.
#
# THE CLOSURE, from the row: a served envelope must be distinguishable from a
# measured one by reading THE ENVELOPE ALONE — no filesystem access, no second
# run, no knowledge of the producing host. Arm 5 is the one that pins it, and it
# pins it the hard way: the two envelopes must differ in `accel_source` AND IN
# NOTHING ELSE, which is simultaneously the proof that the field discriminates
# and the proof that nothing else does.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

pass=0; fail=0
ok()   { printf 'ok:   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); }

BIN="${TILLANDSIAS_BIN:-$ROOT/target/debug/tillandsias}"
if [ ! -x "$BIN" ]; then
    # Not a skip that asserts nothing: there is no product to ask, and saying so
    # by name is the only honest answer. `./build.sh --check` builds this binary,
    # so inside the gate this branch does not run.
    echo "could-not-run:capabilities-envelope-source:no-binary:$BIN"
    exit 3
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cap-envelope-source.XXXXXX")" || exit 3
trap 'rm -rf "$TMP"' EXIT
CACHE="$TMP/tillandsias/capabilities.json"

run() { XDG_CACHE_HOME="$TMP" "$BIN" --capabilities 2>/dev/null; }
line() { printf '%s\n' "$1" | head -1; }
key()  { printf '%s\n' "$1" | head -1 | tr ' ' '\n' | sed -n "s/^$2=//p"; }

# ── 1. cold: nothing cached, so the probe must run and say it did ───────────
out1="$(run)"; rc1=$?
[ "$rc1" -eq 0 ] || bad "cold run exited $rc1"
src1="$(key "$out1" accel_source)"
if [ "$src1" = "measured" ]; then
    ok "a cold run reports accel_source=measured"
else
    bad "a cold run reported accel_source='$src1', want measured"
fi

# ── 2. warm: the cache is served, and the envelope says SERVED ──────────────
out2="$(run)"
src2="$(key "$out2" accel_source)"
if [ "$src2" = "served" ]; then
    ok "a second run reports accel_source=served"
else
    bad "a second run reported accel_source='$src2', want served"
fi

# ── 3. the replay is real — this is the defect, asserted, not assumed ───────
#    Without it arm 2 could pass on a probe that re-measured and mislabelled.
ts1="$(printf '%s\n' "$out1" | sed -n 's/.*"timestamp": "\([^"]*\)".*/\1/p' | head -1)"
ts2="$(printf '%s\n' "$out2" | sed -n 's/.*"timestamp": "\([^"]*\)".*/\1/p' | head -1)"
if [ -n "$ts1" ] && [ "$ts1" = "$ts2" ]; then
    ok "the served document replays the producing run's timestamp verbatim"
else
    bad "expected run 2 to replay run 1's timestamp; got '$ts1' then '$ts2'"
fi

# ── 4. the STORED document claims neither ───────────────────────────────────
#    Persisting `measured` would replay the claim with the document forever.
stored="$(sed -n 's/.*"envelope_source": *\(.*\)/\1/p' "$CACHE" | head -1)"
case "$stored" in
    null*) ok "the stored cache document says envelope_source: null" ;;
    "")    bad "the stored cache document has no envelope_source key at all" ;;
    *)     bad "the stored cache document claims envelope_source: $stored" ;;
esac

# ── 5. THE CLOSURE: the envelope alone, and nothing else, discriminates ─────
e1="$(line "$out1")"; e2="$(line "$out2")"
d1="$(printf '%s\n' "$e1" | tr ' ' '\n' | /usr/bin/grep -v '^accel_source=')"
d2="$(printf '%s\n' "$e2" | tr ' ' '\n' | /usr/bin/grep -v '^accel_source=')"
if [ "$e1" = "$e2" ]; then
    bad "the measured and served envelopes are byte-identical — nothing discriminates"
elif [ "$d1" = "$d2" ]; then
    ok "the two envelopes differ in accel_source and in no other key"
else
    bad "the two envelopes differ outside accel_source; the comparison proves nothing about the field"
fi

# ── 6. --fresh still measures with a cache present (852-dk9z stays true) ────
out3="$(XDG_CACHE_HOME="$TMP" "$BIN" --capabilities --fresh 2>/dev/null)"
src3="$(key "$out3" accel_source)"
if [ "$src3" = "measured" ]; then
    ok "--fresh reports measured even with a warm cache"
else
    bad "--fresh reported accel_source='$src3', want measured"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: capabilities-envelope-names-its-source $pass/$total (1139-xe5m)"
    exit 0
fi
echo "FAIL: capabilities-envelope-names-its-source $pass/$total (1139-xe5m)"
exit 1
