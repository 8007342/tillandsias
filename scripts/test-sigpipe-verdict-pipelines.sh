#!/usr/bin/env bash
# @trace spec:ci-release, plan 792-ksr8
#
# Fixture for the SIGPIPE-under-pipefail verdict defect and the diff-scoped
# gate that refuses newly-added instances of it.
#
# Two halves, and the first is the reason the second exists:
#   MECHANISM — reproduce the race itself, plus the two controls that prove it
#               is SIGPIPE and not something else. Without the controls a
#               flaky failure is just a flaky failure.
#   GATE      — the diff-scoped guard refuses an added dangerous pipeline,
#               passes an added safe one, honours a recorded exemption, and
#               never touches the legacy corpus.
#
# Run: scripts/test-sigpipe-verdict-pipelines.sh   (exit 0 = pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/check-sigpipe-verdict-pipelines-added.sh"
fail=0

pass() { echo "ok: $1"; }
bad()  { echo "FAIL: $1" >&2; fail=1; }

# ── MECHANISM ───────────────────────────────────────────────────────────────
# A large producer into an EARLY match under pipefail: the producer is still
# writing when grep exits, takes SIGPIPE, and pipefail promotes 141.
mech_early="$(bash -c '
set -uo pipefail
big=$(seq 1 200000)
f=0
for i in $(seq 1 20); do printf "%s\n" "$big" | grep -qx "1"; [ $? -ne 0 ] && f=$((f+1)); done
echo "$f"')"
if [ "$mech_early" -ge 15 ]; then
    pass "MECHANISM early match under pipefail fails ${mech_early}/20 despite matching"
else
    bad "MECHANISM did not reproduce (only ${mech_early}/20) — the race may be host-dependent"
fi

# CONTROL 1: the same match at the END of the stream. The producer finishes
# before grep exits, so there is nothing to signal.
mech_late="$(bash -c '
set -uo pipefail
big=$(seq 1 200000)
f=0
for i in $(seq 1 20); do printf "%s\n" "$big" | grep -qx "200000"; [ $? -ne 0 ] && f=$((f+1)); done
echo "$f"')"
if [ "$mech_late" -eq 0 ]; then
    pass "CONTROL late match is clean 0/20 (proves it is the early exit, not grep)"
else
    bad "CONTROL late match failed ${mech_late}/20 — mechanism is not what we think"
fi

# CONTROL 2: the same early match with pipefail OFF. 141 is no longer promoted.
mech_nopf="$(bash -c '
set -uo pipefail
big=$(seq 1 200000)
set +o pipefail
f=0
for i in $(seq 1 20); do printf "%s\n" "$big" | grep -qx "1"; [ $? -ne 0 ] && f=$((f+1)); done
echo "$f"')"
if [ "$mech_nopf" -eq 0 ]; then
    pass "CONTROL early match without pipefail is clean 0/20 (proves pipefail promotes it)"
else
    bad "CONTROL pipefail-off failed ${mech_nopf}/20 — mechanism is not what we think"
fi

# CONTROL 3: the recommended rewrite is immune under the same conditions.
mech_fix="$(bash -c '
set -uo pipefail
big=$(seq 1 200000)
f=0
for i in $(seq 1 20); do grep -qx "1" <<<"$big"; [ $? -ne 0 ] && f=$((f+1)); done
echo "$f"')"
if [ "$mech_fix" -eq 0 ]; then
    pass "FIX here-string is clean 0/20 under the conditions that break the pipe"
else
    bad "FIX here-string failed ${mech_fix}/20 — the recommended rewrite does not hold"
fi

# ── GATE ────────────────────────────────────────────────────────────────────
# A throwaway repo with a real base ref, so the gate's diff scoping is
# exercised for real rather than simulated.
tdir="$(mktemp -d)"
trap "rm -rf '$tdir'" EXIT
repo="$tdir/repo"
mkdir -p "$repo/scripts"
git -C "$repo" init -q
git -C "$repo" config user.email f@localhost
git -C "$repo" config user.name f
printf '#!/usr/bin/env bash\nset -uo pipefail\necho base\n' > "$repo/scripts/victim.sh"
git -C "$repo" add -A
git -C "$repo" commit -qm base
git -C "$repo" branch -f testbase HEAD

run_gate() { # <expect-rc> <label>
    local want="$1" label="$2" out rc
    out="$(TILLANDSIAS_SIGPIPE_ROOT="$repo" TILLANDSIAS_SIGPIPE_BASE=testbase bash "$GATE" 2>&1)"
    rc=$?
    if [ "$rc" -eq "$want" ]; then
        pass "$label"
    else
        bad "$label — want rc=$want got rc=$rc [$out]"
    fi
}

# 1. Legacy corpus untouched: no diff at all -> clean.
run_gate 0 "GATE no change passes"

# 2. An ADDED dangerous pipeline is refused.
printf '#!/usr/bin/env bash\nset -uo pipefail\nif cat /etc/hosts | grep -q root; then :; fi\n' > "$repo/scripts/victim.sh"
run_gate 1 "GATE MUTATION added unbounded-producer verdict pipeline is refused"

# 2b. ORDER 1070-a4gc: a PLAIN RECURSIVE GREP is an unbounded producer too.
# The producer list recognised `git grep` and not `grep -r`, so this exact shape
# was invisible even when newly added — and it is not a hypothetical shape: it
# is what made validate-traces.sh report the three best-traced specs as
# UNCOVERED (1069-c9w6), because `grep -q` closed the pipe, the still-traversing
# `grep -rl` took SIGPIPE, pipefail propagated 141, and the `if` took the else
# branch. The metric was inverted and host-dependent, and this guard could not
# see the line that did it.
#
# MEASURED PRE-FIX: this case passes rc=0 against the guard as it stood, which
# is the arm having no teeth. Post-fix it is refused.
printf '#!/usr/bin/env bash\nset -uo pipefail\nif grep -rl needle . | grep -q .; then :; fi\n' > "$repo/scripts/victim.sh"
run_gate 1 "GATE MUTATION added recursive-grep verdict pipeline is refused (1070-a4gc)"

# 2c. NEGATIVE CONTROL for 2b: a recursive grep whose output is CAPTURED first
# is the recommended rewrite and must stay clean, or the widened producer list
# would refuse the fix it recommends.
printf '#!/usr/bin/env bash\nset -uo pipefail\nhits="$(grep -rl needle .)"\ncase "$hits" in *needle*) :;; esac\n' > "$repo/scripts/victim.sh"
run_gate 0 "GATE recursive grep captured into a variable stays clean (1070-a4gc)"

# 3. The recommended rewrite of the same check passes.
printf '#!/usr/bin/env bash\nset -uo pipefail\nout="$(cat /etc/hosts)"\nif grep -q root <<<"$out"; then :; fi\n' > "$repo/scripts/victim.sh"
run_gate 0 "GATE the here-string rewrite of the same check passes"

# 4. A recorded exemption is honoured.
printf '#!/usr/bin/env bash\nset -uo pipefail\nif cat /etc/hosts | grep -q root; then :; fi # sigpipe-ok: bounded\n' > "$repo/scripts/victim.sh"
run_gate 0 "GATE a recorded sigpipe-ok exemption is honoured"

# 5. NEGATIVE CONTROL — a bounded producer must NOT be refused, or the gate
#    would be the false-alarm generator this packet argued against.
printf '#!/usr/bin/env bash\nset -uo pipefail\nif printf %%s "$PWD" | grep -q x; then :; fi\n' > "$repo/scripts/victim.sh"
run_gate 0 "GATE NEGATIVE bounded printf producer is not refused"

# 6. A file WITHOUT pipefail cannot have the defect, so it is not refused.
printf '#!/usr/bin/env bash\nset -u\nif cat /etc/hosts | grep -q root; then :; fi\n' > "$repo/scripts/victim.sh"
run_gate 0 "GATE NEGATIVE no pipefail means no defect, not refused"

# 7. Unavailable base ref SKIPS rather than refuses (634-39ik polarity: this
#    guard only ever ADDS enforcement).
printf '#!/usr/bin/env bash\nset -uo pipefail\nif cat /etc/hosts | grep -q root; then :; fi\n' > "$repo/scripts/victim.sh"
out7="$(TILLANDSIAS_SIGPIPE_ROOT="$repo" TILLANDSIAS_SIGPIPE_BASE=no-such-ref bash "$GATE" 2>/dev/null)"
if [ "$out7" = "ok:sigpipe-verdict-added:base-unavailable" ]; then
    pass "GATE unavailable base ref skips (enforcement only ever adds)"
else
    bad "GATE unavailable base ref did not skip [$out7]"
fi

if [ "$fail" -eq 0 ]; then
    echo "ok:sigpipe-verdict-pipelines-fixture:11"
    exit 0
fi
echo "fail:sigpipe-verdict-pipelines-fixture"
exit 1
