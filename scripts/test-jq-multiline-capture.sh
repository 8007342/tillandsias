#!/usr/bin/env bash
# @trace order:1049-s35z
#
# Fixture: a jq capture that can yield more than one line must strip CR, and
# the checker that enforces it must be able to fail.
#
# THE MEASUREMENT THIS PINS, taken on yolanda 2026-09-05 with od -c rather than
# grep, because MSYS grep folds the CR into the line ending and hides it:
#
#   single value through $()        -> len 1, no CR             SAFE
#   two rows read line by line      -> first line "one" is len 4: o n e \r
#
# jq.exe writes CRLF; command substitution strips only the FINAL line ending.
# So exposure is a property of MULTI-LINE capture, not of using jq — which is
# why one call site broke the litmus runner while 62 siblings were fine.
#
# ARMS 1 AND 2 ARE BEHAVIOURAL AND THEY ARE THE POINT. They run jq for real and
# measure the bytes, so the fixture proves the PREMISE rather than asserting
# it. If a future jq or shell stops emitting CRLF, these arms go green-by-fact
# and the whole packet is moot — which is information, not a failure.
#
# ARM 2 IS THE TWO-ROW CONTROL. With ONE row there is nothing to distinguish a
# fixed site from an unfixed one, because the only line is the last line and it
# never carries a CR. Any per-site verification of this defect that uses a
# one-row fixture proves nothing. That is not hypothetical: the two sites in
# test-hardware-fingerprint.sh are correct today ONLY because both fixtures
# happen to hold exactly one GPU row — correct because of their data, not
# because anyone decided it. A second GPU row breaks them on Windows alone.
#
# ARM 5 IS THE NEGATIVE CONTROL ON THE CHECKER. A checker that cannot red is
# decoration, so an unstripped multi-line site is planted in a scratch tree and
# the checker must catch it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-jq-multiline-capture-strips-cr.sh"
[ -f "$CHECK" ] || { echo "SKIP: checker not present" >&2; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: no jq(1)" >&2; exit 0; }

W="$(mktemp -d)"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT INT TERM

pass=0
fail=0
_result() { # name expected actual
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "  FAIL $1: expected [$2] got [$3]" >&2
    fi
}

echo "== 1049-s35z: multi-line jq captures strip CR"

JSON='{"a":["one","two"]}'

# ---- ARM 1: a SINGLE-value capture is safe without any stripping ------------
# This is why the sweep is a handful of sites and not sixty-three.
one="$(printf '%s' "$JSON" | jq -r '.a[0]')"
_result "arm1-single-value-capture-has-no-CR" "3" "${#one}"

# ---- ARM 2: TWO ROWS — the first line carries the CR ------------------------
first=""
while IFS= read -r l; do first="$l"; break; done < <(printf '%s' "$JSON" | jq -r '.a[]')
# On a host whose jq emits LF this is 3 and the defect does not exist here;
# on one that emits CRLF it is 4. Report which, rather than asserting one.
if [ "${#first}" = "4" ]; then regime=crlf; else regime=lf; fi
echo "  regime: jq emits ${regime} on this host (first-of-two-rows len=${#first})"

# ---- ARM 3: `tr -d '\r'` makes the two-row case safe in EITHER regime -------
firsts=""
while IFS= read -r l; do firsts="$l"; break; done < <(printf '%s' "$JSON" | jq -r '.a[]' | tr -d '\r')
_result "arm3-tr-d-r-makes-the-first-of-two-rows-clean" "3" "${#firsts}"

# ---- ARM 4: a pipeline that REDUCES before capture is safe -----------------
# I wrote this arm expecting `| head -1` to be the WORST case, reasoning that it
# selects the first line and the first line keeps its CR. That reasoning is true
# about the LINE and wrong about the VALUE, and this arm is what refuted it:
# head reduces the stream to ONE line before capture, and command substitution
# then strips that line's ending, CR included. Measured len 3, not 4.
#
# Kept as an arm rather than deleted, because the wrong version is the intuitive
# one and the next reader will have it too.
headed="$(printf '%s' "$JSON" | jq -r '.a[]' | head -1)"
_result "arm4-head-1-reduces-before-capture-so-it-is-safe" "3" "${#headed}"

# ---- ARM 5: NEGATIVE CONTROL — the checker must catch an unstripped site ----
mkdir -p "$W/scripts"
cat > "$W/scripts/offender.sh" <<'OFF'
#!/usr/bin/env bash
names="$(cat data.json | jq -r '.models[].name')"
echo "$names"
OFF
out="$(cd "$ROOT" && bash "$CHECK" "$W/scripts" 2>/dev/null)"
case "$out" in
    violation:jq-multiline-capture-unstripped:*) caught=yes ;;
    *) caught=no ;;
esac
_result "arm5-control-checker-catches-an-unstripped-site" "yes" "$caught"

# ...and must NOT flag the same site once it strips.
cat > "$W/scripts/offender.sh" <<'FIXED'
#!/usr/bin/env bash
names="$(cat data.json | jq -r '.models[].name' | tr -d '\r')"
echo "$names"
FIXED
out2="$(cd "$ROOT" && bash "$CHECK" "$W/scripts" 2>/dev/null)"
case "$out2" in
    ok:jq-multiline-capture-strips-cr:*) cleared=yes ;;
    *) cleared=no ;;
esac
_result "arm5-control-checker-clears-a-stripped-site" "yes" "$cleared"

# ---- ARM 6: a reducer is exempt, because it yields ONE line -----------------
cat > "$W/scripts/offender.sh" <<'RED'
#!/usr/bin/env bash
biggest="$(cat data.json | jq -r '[.models[].size] | max')"
echo "$biggest"
RED
out3="$(cd "$ROOT" && bash "$CHECK" "$W/scripts" 2>/dev/null)"
case "$out3" in
    ok:*) exempt=yes ;;
    *) exempt=no ;;
esac
_result "arm6-a-reducing-filter-is-not-flagged" "yes" "$exempt"

# ---- ARM 7: the real tree is clean -----------------------------------------
out4="$(cd "$ROOT" && bash "$CHECK" scripts 2>/dev/null)"
case "$out4" in
    ok:jq-multiline-capture-strips-cr:*) tree=ok ;;
    *) tree="$out4" ;;
esac
_result "arm7-the-workspace-is-clean" "ok" "$tree"

echo "PASS: $pass  FAIL: $fail"
if [ "$fail" -gt 0 ]; then
    echo "violation:jq-multiline-capture:$fail arm(s) failed"
    exit 1
fi
echo "ok:jq-multiline-capture:$pass arm(s)"
