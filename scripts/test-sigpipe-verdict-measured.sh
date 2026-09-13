#!/usr/bin/env bash
# @trace order:1076-kft9
#
# test-sigpipe-verdict-measured.sh — the self-test for the measuring check.
#
# THE PROBLEM THIS FIXTURE HAD TO SOLVE, and it is not obvious.
#
# THE CONDITION IS WHETHER THE PRODUCER STILL HAS BYTES TO WRITE WHEN THE
# CONSUMER EXITS. `grep -q` exits at its first match; a producer that has
# finished writing is never refused, and one that has not is. Everything below
# is a route to that condition, not a separate mechanism.
#
# ROUTE 1, PRODUCER LATENCY — a slow producer is still writing when the consumer
# leaves (measured 2026-09-05, esmeraldinha + macuahuitl):
#
#   byte-identical file, same command, same consumer
#     drvfs  /mnt/c/...     10/10 SIGPIPE     producer read 207 ms / 5
#     ext4   /tmp/...        0/10             producer read  10 ms / 5
#     btrfs on local NVMe (macuahuitl)  0/10  producer read   6 ms / 5
#
#   CAUSAL CONTROL, because a filesystem differs in more than speed: slowing the
#   producer ON EXT4 with a per-line read loop — same bytes, same consumer —
#   reproduces it 10/10. Nothing about drvfs is required.
#
# ROUTE 2, MATCH POSITION — a FAST producer with a large unwritten remainder
# (macneo, 2026-09-06, from a live escape in scripts/litmus-covering-specs.sh):
#
#     seq 1 20000 | grep -qxF "1"       rc=141   match is the FIRST line
#     seq 1 20000 | grep -qxF "20000"   rc=0     producer had finished
#
# This CORRECTS the earlier claim, kept here because the fixture was built on it,
# that the defect is decided by latency and that no plain synthetic reproduces
# it. A synthetic does reproduce it, deterministically, with no sleep and no
# filesystem, provided the match is early enough that output remains. That is
# why lib-sigpipe-verdict.sh can afford to run a calibration before EVERY clean
# verdict — route 2 is cheap where route 1 is not.
#
# A KNOWN-BAD calibration case still cannot be a LIVE FILE: on a fast host whose
# match happens to be late, no pipeline SIGPIPEs and the case would silently
# stop being bad. Arm 1 keeps the deliberately slowed producer, which forces the
# defect irrespective of filesystem — the causal control promoted into a
# fixture, and now one of two independent routes rather than the only one.
#
# Arm 5 is the teeth: it re-runs arm 1 through the BROKEN eval form and requires
# it to MISS. Without that, a check that measures nothing passes arms 1-4 by
# reporting plausible verdicts — which is what happened three times while this
# was being written.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/lib-sigpipe-verdict.sh"
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

# 2. NO 141 OBSERVED IS NOT A CLEAN BILL. This arm used to assert
#    `measured-clean:` for a fast producer under PIPE_BUF, and that verdict no
#    longer exists. 0 of REPS means NOT OBSERVED: the identical pipeline reads
#    40/40 on one locus and 0/40 on another, and no rep count separates "safe"
#    from "unsafe with a low observation rate" without a reference at this
#    site's own producer size and consumer — which is the site itself.
v="$(REPS=3 measure_pipeline fx 2 "cat $W/small.txt" "-q 'NEEDLE_HERE'")"
case "$v" in
    unmeasured:*not-observed*) ok "no 141 observed reads unmeasured, NOT clean ($v)" ;;
    measured-clean:*)          bad "the clean verdict is back — it is the only verdict that can be false: $v" ;;
    *)                         bad "expected unmeasured:not-observed, got: $v" ;;
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
