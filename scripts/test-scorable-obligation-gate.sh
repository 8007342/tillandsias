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

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: scorable-obligation gate $pass/$total (977-448j)"
    exit 0
fi
echo "FAIL: scorable-obligation gate $pass/$total (977-448j)"
exit 1
