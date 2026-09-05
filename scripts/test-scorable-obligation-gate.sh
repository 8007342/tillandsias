#!/usr/bin/env bash
# test-scorable-obligation-gate.sh — prove the enforcement gate refuses.
# @trace order:977-448j
#
# CRITERION 3 IS WHY THIS USES ITS OWN FIXTURES. The coordinator split
# enforcement from backfill precisely because the backfill can SUCCEED while
# covering almost nothing (it did: 2.6%), and enforcement must not be able to
# inherit that as evidence it works. So every arm below runs against a
# purpose-built temp repository — this suite never reads the real ledger, and a
# sparse backfill cannot make it pass or fail.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# FIXTURE TOKENS ARE ASSEMBLED, NOT WRITTEN (721-77yu). A literal `litmus:<name>`
# in this file reads to check-litmus-pins as a verification CLAIM, and these are
# input DATA for a temp repository — the checker cannot tell the two apart from
# the text, and it is right not to guess. Building the token from a variable
# keeps the fixture self-contained (criterion 3: this suite must not depend on
# the real ledger) without asserting a pin that does not resolve.
L="litmus"
# Assembled for the same reason as L above: a literal cargo invocation in
# this file is fixture DATA, not a claim this suite makes about the workspace.
C="cargo test"
GATE="$PWD/scripts/check-scorable-obligation-added.sh"
pass=0; fail=0

run_in_fixture() { # <fragment-body> -> prints verdict
    local body="$1"
    local d; d="$(mktemp -d "${TMPDIR:-/tmp}/scorable-fx.XXXXXX")"
    (
        cd "$d" || exit 2
        git init -q . && git config user.email t@t && git config user.name t
        mkdir -p plan/index.d scripts
        cp "$GATE" scripts/
        git add -A && git commit -qm base
        git branch -q base-ref
        printf '%s' "$body" > plan/index.d/20260101t000000z-fixture.yaml
        git add -A && git commit -qm new
        bash scripts/check-scorable-obligation-added.sh base-ref 2>&1
    )
    rm -rf "$d"
}

check() { # name expected actual
    # Compare the VERDICT line only. The gate prints its machine-readable line
    # on stdout and its human detail on stderr, and both are captured — so an
    # exact match against the whole stream would break the moment a detail line
    # is added. Keeping the two apart is the same discipline the post-commit
    # hook learned: verdict for the machine, explanation appended for the human.
    local got
    got="$(printf %s "$3" | grep -E "^(ok|violation|skip):" | head -1)"
    if [ "$got" = "$2" ]; then pass=$((pass+1)); else
        fail=$((fail+1)); echo "FAIL: $1"; echo "  want=[$2] got=[$got]"
    fi
}

# 1. THE REFUSAL. A new packet with no closure and no stated reason is exactly
#    the row rung 4 could not score, and it must not land silently.
check "silent new packet is refused" "violation:scorable-obligation-missing:1" \
  "$(run_in_fixture 'packets:
  - packet_id: silent-row
    order: 999-aaaa
    status: ready
    title: a row that says nothing about how it could be scored
')"

# 2. A litmus pin is accepted — the pin rung 4 actually used.
check "litmus pin accepted" "ok:scorable-obligations:1 checked" \
  "$(run_in_fixture "packets:
  - packet_id: pinned-row
    order: 999-bbbb
    status: ready
    verifiable_closure: |
      ${L}:some-test passes
")"

# 3. A STATED refusal is accepted. Not a loophole: some rows genuinely close by
#    other means, and a gate that demanded a litmus test of all of them would be
#    unsatisfiable — an unsatisfiable gate is switched off. What is refused is
#    SILENCE, which is neither auditable nor greppable.
check "stated unscoreable accepted" "ok:scorable-obligations:1 checked" \
  "$(run_in_fixture 'packets:
  - packet_id: honest-row
    order: 999-cccc
    status: ready
    unscoreable: closes on an operator decision; no mechanical pin exists
')"

# 4. NEGATIVE CONTROL ON THE ACCEPTANCE PATH. Without this, a gate that accepted
#    everything would satisfy arms 2 and 3. Two packets, one pinned and one
#    silent, must report exactly ONE violation — so acceptance is per-row rather
#    than a blanket pass.
check "mixed fragment counts only the silent row" "violation:scorable-obligation-missing:1" \
  "$(run_in_fixture "packets:
  - packet_id: pinned-row
    order: 999-dddd
    status: ready
    verifiable_closure: ${L}:some-test
  - packet_id: silent-row
    order: 999-eeee
    status: ready
    title: no pin here
")"

# 5. AN EVENTS-ONLY FRAGMENT ADDS NO OBLIGATION and must not be demanded of.
#    Most fragments this fleet writes are events; a gate that redded them would
#    fire on almost every push and be switched off within a day.
check "events-only fragment is not demanded of" "skip:no-new-packets" \
  "$(run_in_fixture 'events:
  - packet_id: some-existing-row
    event:
      type: note
      ts: "2026-01-01T00:00:00Z"
      host: fixture
      summary: an ordinary progress note
')"


# 6. CRITERION 2: the two conditions must be DISTINGUISHABLE. A row that is
#    scorable but tombstones an obligation is not missing anything — it has left
#    the monotone band, so its score must not be compared with the previous run.
#    That is a NOTE, not a violation: tombstoning is required by the operator's
#    rule when a requirement's meaning changes, and redding it would punish
#    correct behaviour. What must never happen is the two collapsing into one
#    verdict, because they demand opposite responses.
out6="$(run_in_fixture "packets:
  - packet_id: rotating-row
    order: 999-ffff
    status: ready
    verifiable_closure: ${L}:some-test
    notes: this row will tombstone req-old and replace it
")"
case "$out6" in
    *"regime-broken:1"*) pass=$((pass+1)) ;;
    *) fail=$((fail+1)); echo "FAIL: regime break not named distinctly"; echo "  got=[$out6]" ;;
esac
case "$out6" in
    *violation:*) fail=$((fail+1)); echo "FAIL: a legitimate tombstone was redded as a violation" ;;
    *) pass=$((pass+1)) ;;
esac


# 8. A SCRIPT VERDICT IS A MECHANICAL PIN TOO. Added after this gate refused the
#    first real packet filed through it (994-8r3w), whose closure names a script
#    rather than a litmus test. The refusal was correct about the letter and
#    wrong about the intent: a gate that makes the honest path harder than the
#    `unscoreable:` escape hatch teaches authors to take the hatch.
check "script-named closure accepted" "ok:scorable-obligations:1 checked" \
  "$(run_in_fixture 'packets:
  - packet_id: script-pinned-row
    order: 999-gggg
    status: ready
    verifiable_closure: |
      scripts/check-something.sh reports ok
')"

# 1033-ev5r: a closure naming a cargo invocation is scorable for the same
# reason a script one is — a command with an exit code that any reader can run.
# The gate refused such a row, whose author's only alternatives were a
# do-nothing scripts/ wrapper around cargo or a dishonest `unscoreable:`. Both
# are worse records than the cargo line.
check "cargo-named closure accepted" "ok:scorable-obligations:1 checked" \
  "$(run_in_fixture 'packets:
  - packet_id: cargo-pinned-row
    order: 999-hhhh
    status: ready
    verifiable_closure: |
      '"${C}"' -p some-crate --test some_target passes green at a clean HEAD.
')"

# NEGATIVE CONTROL FOR THE WIDENING. Without this, the arm above proves only
# that SOMETHING passes — a gate that accepted every fragment would satisfy it.
# Prose that merely MENTIONS testing, with no runnable command, must still be
# refused, or the widening has removed the gate rather than widened it.
check "prose about testing is still refused" "violation:scorable-obligation-missing:1" \
  "$(run_in_fixture 'packets:
  - packet_id: prose-only-row
    order: 999-iiii
    status: ready
    verifiable_closure: |
      Someone should test this properly and confirm the behaviour is right.
')"

# 1036-w2kd. LENOVINHA'S TWO SENTENCES, the second-host review of 1033-ev5r.
# These are the negative controls the widening actually needed and did not get:
# the original "prose about testing" arm avoided the literal string, so it
# exercised the shape that was ALREADY refused rather than the one the widening
# newly admitted. A sabotage arm that cannot reach the new code path proves
# nothing about it.
check "prose merely MENTIONING the tool is refused" "violation:scorable-obligation-missing:1" \
  "$(run_in_fixture 'packets:
  - packet_id: mentions-cargo-in-prose
    order: 999-jjjj
    status: ready
    verifiable_closure: |
      We have not run '"${C}"' on this yet; someone should before v0.6.
')"

# The nastier of the two: a closure saying IN PLAIN ENGLISH that the row is
# unscoreable, which passed the gate whose entire purpose is to make that
# statement explicit and greppable.
check "prose saying the row is unscoreable is refused" "violation:scorable-obligation-missing:1" \
  "$(run_in_fixture 'packets:
  - packet_id: says-unscoreable-in-prose
    order: 999-kkkk
    status: ready
    verifiable_closure: |
      This is hard to verify; '"${C}"' would not cover it, so judgement is required.
')"

# THE HOLE WAS NOT NEW, which is why the fix anchors all four patterns rather
# than narrowing the one that was added. `*scripts/*.sh*` admitted the same
# shape long before `cargo test` did; `cargo test` merely appears in prose far
# more often.
check "prose mentioning a script is refused too" "violation:scorable-obligation-missing:1" \
  "$(run_in_fixture 'packets:
  - packet_id: mentions-script-in-prose
    order: 999-llll
    status: ready
    verifiable_closure: |
      We never wrote scripts/foo.sh for this and probably should.
')"

# POSITIVE CONTROL FOR THE ANCHORING ITSELF. Without this, the three arms above
# are satisfied by a gate that refuses everything.
check "a closure LEADING with the command still passes" "ok:scorable-obligations:1 checked" \
  "$(run_in_fixture 'packets:
  - packet_id: leads-with-command
    order: 999-mmmm
    status: ready
    verifiable_closure: |
      '"${C}"' -p some-crate --test some_target passes green at a clean HEAD.
')"

check "a bash-prefixed script closure still passes" "ok:scorable-obligations:1 checked" \
  "$(run_in_fixture 'packets:
  - packet_id: leads-with-bash-script
    order: 999-nnnn
    status: ready
    verifiable_closure: |
      bash scripts/test-something.sh prints PASS at a clean HEAD.
')"

# 1036-jamx. NEGATIVE CONTROL FOR THE TOMBSTONE SCAN, from a real false
# positive: a packet DESCRIBING this mechanism ("the tombstone/regime scan
# still needs the flattened body") was reported as tombstoning an obligation.
# Same defect as the scorable patterns had, in the sibling arm of the same
# script. A note nobody can trust is a note everybody learns to skip.
out_tsref="$(run_in_fixture "packets:
  - packet_id: mentions-the-mechanism
    order: 999-oooo
    status: ready
    verifiable_closure: |
      ${C} -p x --test y passes.
    notes: this row explains how the tombstone/regime scan reads the body
")"
case "$out_tsref" in
    *"regime-broken"*) fail=$((fail+1)); echo "FAIL: prose REFERRING to tombstoning is not a tombstone"; echo "  got=[$out_tsref]" ;;
    *) pass=$((pass+1)) ;;
esac

# ── ORDER 1069-5sp4: IS THE GUARD REACHABLE FOR THE CHANGE IT IS ABOUT? ───────
#
# Every arm above tests the CHECKER in isolation, and every one of them passed
# for three cycles while the checker never ran on the authoring host at all.
# That is the class an isolation test cannot see: the checker's only input is
# newly added plan/index.d/*.yaml, gate-stamp.sh:343 EXCLUDES that path from the
# stamp hash (930-i6x4), so a plan-only change leaves the stamp fresh,
# ./build.sh --check answers ok:gate-fresh, and the fast-refusal block never
# executes. Measured 2026-09-05: standalone the checker said
# violation:scorable-obligation-missing:2 while ./build.sh --check on the same
# tree said ok:gate-fresh and exited 0.
#
# So the plan-only pre-push lane must invoke it — that lane is the only thing
# that inspects a plan-only push. This arm pins that wiring.
#
# THE NEEDLE IS ASSEMBLED rather than written literally, because a grep whose
# pattern also matches this file's own assertion proves nothing (the vacuous-pin
# lesson from 1029-5wvd).
#
# AND COMMENTS ARE STRIPPED BEFORE SCANNING, because the first version of this
# arm was NOT teeth-bearing and its own sabotage proved it: disabling the lane's
# invocation left the arm GREEN at 17/17, since the checker's name still appeared
# in the explanatory comment block right above it. A guard that a comment can
# satisfy is satisfied by the history of the thing rather than the thing —
# methodology/verification.yaml, quoted_history_lives_in_comments_guards_scan_declarations.
# So: strip comments, then require an actual `bash ... <checker>` invocation.
_lane="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/hooks/pre-push-local-gate.sh"
_needle="check-scorable""-obligation-added.sh"
_lane_code=""
[ -f "$_lane" ] && _lane_code="$(sed 's/#.*//' "$_lane")"
if [ ! -f "$_lane" ]; then
    fail=$((fail+1)); echo "FAIL: the plan-only lane script is missing: $_lane"
# CAPTURE FIRST — 792-ksr8, and this arm was a live instance of the class it
# is written in the style of. It used to be
#     sed 's/#.*//' "$_lane" | grep -qE "bash[[:space:]]+[^|]*$_needle"
# under this file's `set -uo pipefail`. grep -q exits AT THE MATCH, sed keeps
# writing, takes SIGPIPE, and pipefail promotes 141 to the pipeline's status —
# so the arm reported FAIL BECAUSE THE LANE WAS CORRECTLY WIRED. esmeraldinha
# measured PIPESTATUS=(141 0) on WSL with the wiring present, at 16/17 after a
# 28-minute gate.
#
# IT IS GREEN ON FEDORA AND THE REASON IS NOT THE ONE THIS COMMENT FIRST GAVE.
# Measured on macuahuitl: the comment-stripped lane is 33932 bytes, the first
# match is at line 875, and 10161 bytes remain after it. esmeraldinha reproduced
# those byte counts exactly on WSL — and the same pipeline there is 40/40
# SIGPIPE, PIPESTATUS=(141 0), the consumer MATCHING and the pipeline still
# failing. Identical quantities, opposite verdicts, both deterministic.
#
# SO THE "BYTES AFTER THE MATCH AGAINST THE 65536-BYTE PIPE BUFFER" EXPLANATION
# IS FALSIFIED, and it was the coordinator's. esmeraldinha's synthetics on the
# failing host, with a pipe verified to hold 65536 bytes:
#     500 lines,  match@1     tail 36427 B   wrong 1/10
#     500 lines,  match@450   tail  3650 B   wrong 0/10
#     1200 lines, match@875   tail 23725 B   wrong 1/10
#     1200 lines, match@1199  tail     73 B   wrong 0/10
# A 36 KB tail is nearly always fine there; the real 10 KB tail is never fine.
# The margin does not order the outcomes. It is not mis-parameterised, it is the
# wrong quantity.
#
# THE MECHANISM IS PRODUCER I/O LATENCY, established causally by esmeraldinha and
# not by correlation. Byte-identical file, one distinct md5, same command:
#     drvfs  /mnt/c/.../pre-push-local-gate.sh    10/10 SIGPIPE
#     ext4   a copy in /tmp                        0/10
# and the control that makes it causal rather than a filesystem story — on ext4,
# a deliberately SLOWED producer (per-line bash read loop, same bytes, same
# consumer) reproduces it 10/10. Read times: drvfs 207 ms / 5 reads, ext4 10 ms.
#
# A FAST producer writes its whole output into the 64 KB pipe buffer before
# `grep -q` is scheduled to exit, so it has nothing left to write and never sees
# EPIPE. A SLOW producer is still blocked on read I/O when grep matches and
# exits; its next write goes to a pipe with no reader, and that is the 141. Size
# matters only ABOVE the buffer; below it, latency decides.
#
# CONFIRMED FROM THE FAST SIDE on macuahuitl: checkout on local NVMe btrfs,
# producer 6 ms / 5 reads (~35x faster than drvfs), verdict 0/10 SIGPIPE.
#
# SO A CHECK FOR THIS CLASS MUST EXECUTE THE PIPELINE AGAINST THE REAL FILE ON
# THE REAL CHECKOUT FILESYSTEM. A synthetic calibration case in /tmp reports SAFE
# and is worthless — every synthetic esmeraldinha built lived on ext4, which is
# why none reproduced the defect at any size, match position or ERE complexity.
# The live file is REQUIRED, not brittle. Report `unmeasured` with a reason
# otherwise, and never model it.
#
# FLEET CONSEQUENCE: any host whose checkout is reached over a slow-backed
# filesystem is exposed where a local-disk host is not — WSL drvfs, a network
# mount, a container bind mount, a macOS virtiofs share. A green here says
# nothing about those. 792-ksr8's own "0 below 6 KB, mixed 8-14 KB, certain
# above 19 KB" was one host's slice and conflated size with buffer-fill.
#
# WHAT SURVIVES, AND IT IS WHY THE CAPTURE STAYS: the verdict was decided by
# something other than whether the match existed, on both hosts, in opposite
# directions. That is the defect regardless of mechanism.
elif grep -qE "bash[[:space:]]+[^|]*$_needle" <<<"$_lane_code"; then
    pass=$((pass+1))
else
    fail=$((fail+1))
    echo "FAIL: the plan-only lane does not invoke the scorable guard (1069-5sp4)"
    echo "  A plan-only push is the ONLY kind this guard is about, and the gate"
    echo "  stamp ignores plan/index.d/, so build.sh --check cannot reach it."
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: scorable-obligation gate $pass/$total (977-448j)"
    exit 0
fi
echo "FAIL: scorable-obligation gate $pass/$total (977-448j)"
exit 1
