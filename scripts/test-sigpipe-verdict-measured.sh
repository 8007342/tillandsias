#!/usr/bin/env bash
# @trace order:1076-kft9
#
# test-sigpipe-verdict-measured.sh — the self-test for the measuring check.
#
# THE PROBLEM THIS FIXTURE HAD TO SOLVE, and it is not obvious.
#
# The defect is decided by PRODUCER LATENCY, not by output size (measured
# 2026-09-05, esmeraldinha + macuahuitl):
#
#   byte-identical file, same command, same consumer
#     drvfs  /mnt/c/...     10/10 SIGPIPE     producer read 207 ms / 5
#     ext4   /tmp/...        0/10             producer read  10 ms / 5
#     btrfs on local NVMe (macuahuitl)  0/10  producer read   6 ms / 5
#
#   CAUSAL CONTROL, because a filesystem differs in more than speed: slowing the
#   producer ON EXT4 with a per-line read loop — same bytes, same consumer —
#   reproduces it 10/10. Nothing about drvfs is required. Latency is.
#
# So a KNOWN-BAD calibration case cannot be a live file: on a fast host no
# pipeline SIGPIPEs at all, and the case would silently not be bad. And it
# cannot be a plain synthetic either — every synthetic built during this
# investigation lived on ext4 and NONE reproduced the defect across four
# variables (size, match position, ERE complexity, sed doing real substitution
# work). A synthetic calibration reports SAFE and makes the check confidently
# blind, which is the exact failure the check exists to detect.
#
# The portable known-bad case is therefore a DELIBERATELY SLOWED PRODUCER, which
# forces the defect on any host irrespective of filesystem. That is the causal
# control promoted into a fixture.
#
# Arm 5 is the teeth: it re-runs arm 1 through the BROKEN eval form and requires
# it to MISS. Without that, a check that measures nothing passes arms 1-4 by
# reporting plausible verdicts — which is what happened three times while this
# was being written.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-sigpipe-verdict-measured.sh"
pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

[ -f "$CHECK" ] || { echo "FAIL: the check is missing: $CHECK" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CHECK"

# Scratch lives INSIDE the checkout on purpose: it must inherit the checkout's
# filesystem, since that is the variable that decides the answer. A /tmp scratch
# would be ext4 on this host and would not represent what the gate actually runs.
W="$(mktemp -d "$ROOT/target/sigpipe-fx.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM
awk 'BEGIN{for(i=1;i<=1200;i++){ if(i==300) print "NEEDLE_HERE marker line"; else print "filler filler filler filler filler filler filler filler filler" }}' > "$W/corpus.txt"
# A SECOND corpus, deliberately under PIPE_BUF (4096 B), for the known-GOOD arm.# Arm 2 used the 1200-line corpus and was INTERMITTENTLY RED on macuahuitl's# Fedora host: 2 of 6 runs, inner counts 2/3 then 1/3, arm 2 only. A 58 KB# producer needs many write() calls, so a consumer exiting at the match can# leave it mid-write — the same condition the check detects, arriving in the# case that asserts the condition is ABSENT. An arm that is clean only when the# machine is quiet is a snapshot of the machine.## Under PIPE_BUF the whole output goes in ONE write, and the consumer cannot# exit before it has data to match on — so by the time grep -q exits, the# producer has already finished writing and has nothing left to be refused.# That is STRUCTURALLY clean rather than empirically clean.## NOT VERIFIED BY REPRODUCTION: esmeraldinha could not reproduce the failure at# all, 0/50 with the big corpus under deliberate CPU and I/O load. The fix rests# on the structural argument, not on a green run of a case that was already# green here.awk 'BEGIN{for(i=1;i<=20;i++){ if(i==5) print "NEEDLE_HERE marker line"; else print "filler" }}' > "$W/small.txt"

# 1. KNOWN-BAD, portable: a slowed producer must be caught.
v="$(REPS=3 measure_pipeline fx 1 "SLOW_READ $W/corpus.txt" "-q 'NEEDLE_HERE'")"
case "$v" in
    sigpipe-decided:*) ok "a slowed producer whose consumer MATCHES is reported sigpipe-decided ($v)" ;;
    *) bad "the known-bad case was not caught — the check cannot see a 141: $v" ;;
esac

# 2. A fast producer that matches is clean.
v="$(REPS=3 measure_pipeline fx 2 "cat $W/small.txt" "-q 'NEEDLE_HERE'")"
case "$v" in
    measured-clean:*) ok "a fast producer whose consumer matches is measured-clean ($v)" ;;
    *) bad "expected measured-clean, got: $v" ;;
esac

# 3. No match today is NOT safety — it is having nothing to report.
v="$(REPS=3 measure_pipeline fx 3 "cat $W/corpus.txt" "-q 'ABSENT_TOKEN_XYZ'")"
case "$v" in
    unmeasured:*no-match-today*) ok "a consumer with nothing to match is unmeasured, not safe ($v)" ;;
    *) bad "expected unmeasured:no-match-today, got: $v" ;;
esac

# 4. A producer whose size is a runtime property must not read as safe.
v="$(verdict fx 4 "printf '%s' \"\$out\"" "-q 'x'")"
case "$v" in
    unmeasured:*runtime-property*) ok "a runtime-sized producer is unmeasured ($v)" ;;
    *) bad "expected unmeasured:producer-size-is-a-runtime-property, got: $v" ;;
esac

# 5. TEETH: the broken eval form must MISS the known-bad case. `eval "a | b"` is
#    a single simple command, so PIPESTATUS holds one element describing eval.
#    Under pipefail that lone value is 141, so a naive check still "passes" arm 1
#    while measuring nothing — this arm proves arms 1-4 are not satisfied that way.
broken="$(set -o pipefail; eval "SLOW_READ $W/corpus.txt | grep -q 'NEEDLE_HERE'" >/dev/null 2>&1; echo "${#PIPESTATUS[@]}")"
if [ "$broken" = "1" ]; then
    ok "CONTROL: an evaled pipeline yields a 1-element PIPESTATUS, so the naive form measures nothing"
else
    bad "CONTROL failed: evaled pipeline reported ${broken} PIPESTATUS elements; this fixture's arm 1 may be passing for the wrong reason"
fi

echo "sigpipe-verdict-measured: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
