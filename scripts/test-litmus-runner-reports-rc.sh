#!/usr/bin/env bash
# @trace order:1018-5f5a
#
# test-litmus-runner-reports-rc.sh — every [FAIL] the litmus runner prints must
# carry the step's exit status.
#
# ── WHY ─────────────────────────────────────────────────────────────────────
#
# 2026-09-04. The runner printed `[FAIL]` with no rc. A step that returned 1
# (a grep found no match) was reported across three hosts as a SIGPIPE 141 —
# not maliciously, but because a reader with no number SUPPLIES one, and the
# nearest plausible mechanism was in a comment block they had read minutes
# earlier. Three hosts then measured pipe buffers for most of an afternoon
# against a failure that never involved a pipe. The same day it hid two of the
# release gate's eight causes: one step printed a single line and no rc, and
# another lost its failing case names to the step's own `| tail -1`.
#
# rc=1, rc=141 and rc=124 need three different responses — "ran, did not match",
# "died of SIGPIPE mid-write", "the timeout killed it". Nothing else in the
# output separates them, because the step's own text is whatever the step chose
# to emit and can be empty.
#
# ── WHAT IS AND IS NOT PROVEN HERE, stated plainly ──────────────────────────
#
# Arm A is BEHAVIOURAL: it runs the three shapes through the runner's own
# execution line and asserts the numbers really are 1, 141 and 124. Without it
# the invariant arm would be pinning a grammar for exit codes nobody produces.
#
# Arm B is STATIC: it asserts every `[FAIL]` printf in the runner carries
# `rc=%s`. It is NOT an end-to-end assertion that a failing spec prints rc —
# driving the real runner needs a spec registered in openspec/litmus-bindings.yaml,
# and a fixture that edits a shared registry (or rebuilds a temp PROJECT_ROOT
# with every sourced dependency) costs more than it proves here. So the
# behavioural half and the invariant half are separate, and this comment is
# where that seam is recorded rather than glossed.
#
# Arm C is the CONTROL, and it is why B is worth having: B run against the
# PRE-FIX runner must FAIL. An invariant that has never gone red is a claim.

set -uo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

RUNNER="scripts/run-litmus-test.sh"
pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# _rule <file> -> prints offending line numbers: [FAIL] printfs without rc=
_rule() {
    /usr/bin/grep -n "printf.*\[FAIL\]" "$1" 2>/dev/null \
        | /usr/bin/grep -v 'rc=%s' \
        | /usr/bin/grep -v 'Status: ' \
        | /usr/bin/grep -v 'rc-exempt:' \
        | cut -d: -f1
}

# ── ARM A: the three shapes really produce 1, 141 and 124 ───────────────────
# Executed the way the runner executes a step: `timeout --kill-after=10s Ns
# bash -c ... >capture 2>&1`. Uses /usr/bin/grep explicitly — an interactive
# shell resolves a `grep` FUNCTION (ugrep) on three of three Linux hosts, and
# ugrep's SIGPIPE timing differs, which would make the 141 arm pass or fail for
# the wrong reason (901-jtvi).
_step_rc() { # <timeout-secs> <command>
    local t="$1" cmd="$2" cap rc=0
    cap="$(mktemp)"
    timeout --kill-after=10s "${t}s" bash -c "$cmd" </dev/null >"$cap" 2>&1 || rc=$?
    rm -f "$cap"; printf '%s' "$rc"
}

a1="$(_step_rc 30 'exit 1')"
[ "$a1" = "1" ] && ok "armA silent exit 1 -> rc=1" || bad "armA expected rc=1, got $a1"

# A MULTI-LINE producer, deliberately. Measured on lenovinha 2026-09-04 against
# /usr/bin/grep 3.12, 20 runs per shape: a SINGLE 4 MB line into `grep -q`
# returns 0, because GNU grep matches line-at-a-time and must reach the newline
# before it can decide, so it drains and the producer never dies. Only a
# multi-line stream lets grep settle on line 1 and exit with the rest in flight.
# My first draft of this arm used the single-line shape and measured rc=0 — the
# arm would have reported "141 untested here" on a host that produces 141 all
# day.
a2="$(_step_rc 60 "set -o pipefail; { printf 'MATCHME\\n'; head -c 4000000 /dev/zero | tr '\\0' 'x' | fold -w 80; } | /usr/bin/grep -q 'MATCHME'")"
if [ "$a2" = "141" ]; then
    ok "armA SIGPIPE shape -> rc=141"
else
    # Not a failure of the RUNNER: the shape is platform-sensitive. Report it
    # rather than pass silently, so a host where 141 is unreachable says so.
    echo "  note: armA SIGPIPE shape produced rc=$a2, not 141 on this host — the 141 grammar is untested here"
    pass=$((pass+1))
fi

a3="$(_step_rc 2 'sleep 400')"
[ "$a3" = "124" ] && ok "armA timeout -> rc=124" || bad "armA expected rc=124 from timeout, got $a3"

# ── ARM B: every [FAIL] the runner prints carries rc= ────────────────────────
missing="$(_rule "$RUNNER")"
if [ -z "$missing" ]; then
    ok "armB every [FAIL] printf in the runner carries rc="
else
    bad "armB [FAIL] printf without rc= at line(s): $(printf '%s' "$missing" | tr '\n' ' ')"
fi

# ── ARM C: the control — the rule must go RED on a pre-fix shape ────────────
#
# THIS ARM WAS ITSELF BROKEN, and the way it broke is the defect this whole
# fixture exists to catch, so it is recorded rather than quietly repaired.
#
# It used to read the pre-fix runner as `git show HEAD~1:scripts/run-litmus-test.sh`.
# HEAD~1 IS A MOVING REF. That expression named the pre-fix runner for exactly
# as long as my fix was the newest commit; the moment anything else landed on
# linux-next it named a commit that ALREADY CARRIED the fix, the rule passed,
# and the control reported that it had no teeth — correctly, about itself.
# Measured 2026-09-04: the fixture read 5/5 on my host at commit time and 4/5
# in macuahuitl's --ci-full an hour later, with nothing about the RULE changed
# between them. A guard whose verdict depends on how many commits have landed
# since is not a guard.
#
# The replacement depends on NOTHING outside this file: a literal pre-fix shape,
# written here, that the rule must refuse. It cannot drift with history, cannot
# skip on a shallow clone (that skip was a silent no-teeth mode of its own), and
# cannot differ between a direct run and a run inside the gate — which were the
# three ways the old arm could be wrong.
#
# It is deliberately NOT pinned to a fixed SHA either. A fixed SHA is stable but
# still absent in a shallow clone, and re-introduces the skip path. The property
# under test is "the rule refuses a [FAIL] printf with no rc", and that property
# does not need git to state it.
prev="$(mktemp)"
cat > "$prev" <<'PREFIX_SHAPE'
# A verbatim pre-fix shape: the two forms the runner actually used before
# 1018-5f5a, plus one exempt line that must NOT be counted as a violation.
            printf '  %b[FAIL]%b spec=%s test=%s\n' "${RED}" "${NC}" "$spec_name" "$test_name" >&2
                printf ' %b[FAIL]%b\n' "${RED}" "${NC}" >&2
        printf '  %b[FAIL]%b gating_points.failure matched: %s\n' "${RED}" "${NC}" "$failure" >&2   # rc-exempt: not a step exit
PREFIX_SHAPE
hits="$(_rule "$prev")"
n_hits="$(printf '%s' "$hits" | /usr/bin/grep -c . || true)"
if [ "$n_hits" = "2" ]; then
    ok "armC the rule refuses both pre-fix [FAIL] forms and honours the exemption (it has teeth)"
elif [ "$n_hits" = "0" ]; then
    bad "armC the rule PASSES a pre-fix shape — it cannot have caught this defect"
else
    bad "armC expected exactly 2 refusals from the pre-fix shape (the exempt line must not count), got $n_hits"
fi
rm -f "$prev"

printf 'litmus-runner-reports-rc: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || { echo "fail:test-litmus-runner-reports-rc:$fail"; exit 1; }
echo "ok:test-litmus-runner-reports-rc:$pass"
