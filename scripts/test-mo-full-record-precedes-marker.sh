#!/usr/bin/env bash
# @trace spec:meta-orchestration, spec:methodology-accountability
# @trace order:974-uk95, order:614-2gqx, order:651-2x5s
#
# Fixture for order 974-uk95: a valid MO-FULL marker must not be printable
# unless THIS cycle wrote its durable ledger record.
#
# IT REPRODUCES THE MEASURED SEQUENCE, not an abstraction of it. On lenovinha
# 2026-09-03: `record` refused because HEAD was unpushed; the cycle's
# fetch/rebase/retry loop then landed the work without re-running it; and `self`
# printed COMPLETE, correctly, because local and remote now agreed. Every tool
# was right in isolation and the ledger had no line for the cycle. The retry
# loop between the two steps is the whole defect, and it is in the skill's own
# recipe, so every host has it.
#
# THE ASSERTION THAT ALMOST WENT IN WRONG, and the reason it is called out here:
# the ledger line names the WORK head, never the head that contains the ledger
# commit — appending the line moves HEAD, and the terminal marker is re-derived
# one commit later by design. A fixture asserting "the ledger names the head the
# marker names" would fail on every correct cycle. Case 5 asserts the real
# relationship: the recorded head is an ANCESTOR of the attested head.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ATTEST="$REPO_ROOT/scripts/mo-full-attest.sh"
GUARD="$REPO_ROOT/scripts/meta-orchestration-worktree-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=0
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

export MO_FULL_HOST=fixture-host
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid

git init -q --bare "$TMP/remote.git"
git init -q -b work "$TMP/repo"
cd "$TMP/repo"
git remote add origin "$TMP/remote.git"
echo seed > seed.txt && git add . && git commit -qm seed && git push -q origin work

LEDGER="$TMP/repo/ledger.md"
BOUNDARY="$TMP/boundary"

snapshot() { "$GUARD" snapshot "$BOUNDARY" >/dev/null 2>&1; }
verify()   { "$GUARD" verify   "$BOUNDARY" >/dev/null 2>&1; }
self_out() { "$ATTEST" self 5 2>&1; }
record_out() { "$ATTEST" record "$LEDGER" 5 2>&1; }

# ---- cycle 1 -------------------------------------------------------------
rm -rf "$BOUNDARY"; snapshot

echo work > work.txt && git add . && git commit -qm "the cycle's work"
WORK_HEAD="$(git rev-parse HEAD)"
# Finalization verifies the boundary (step 7) BEFORE recording (step 9), so the
# fixture does too — otherwise the boundary precondition masks the case under
# test and every assertion below would be about the wrong refusal.
verify

# 1. record refuses on an unpushed HEAD. This is the step that was CORRECT in
#    the real incident and is the reason the gap opened at all.
out="$(record_out)"
case "$out" in *"not durably on origin"*) ;; *) fail "record should refuse an unpushed HEAD, got: $out" ;; esac
[ -f "$LEDGER" ] && fail "a refused record must leave no ledger behind"

# 2. THE DEFECT. The retry loop lands the work; nothing re-runs record; the
#    marker must now REFUSE rather than print a verified COMPLETE.
git push -q origin work
verify
out="$(self_out)"
case "$out" in
    *"wrote no durable ledger record"*) ;;
    "MO-FULL: COMPLETE"*) fail "REGRESSION: self printed a marker with no ledger record — this is 974-uk95" ;;
    *) fail "expected the no-record refusal, got: $out" ;;
esac

# 3. record after the push succeeds, and writes the ledger.
out="$(record_out)"
case "$out" in "MO-FULL: COMPLETE $WORK_HEAD work $WORK_HEAD") ;; *) fail "record should succeed once pushed, got: $out" ;; esac
grep -q "$WORK_HEAD" "$LEDGER" || fail "the ledger has no line for the work head"

# 4. Committing the ledger MOVES HEAD, exactly as the real sequence does.
git add ledger.md && git commit -qm "record(mo-full)" && git push -q origin work
TERMINAL_HEAD="$(git rev-parse HEAD)"
verify
out="$(self_out)"
case "$out" in "MO-FULL: COMPLETE $TERMINAL_HEAD work $TERMINAL_HEAD") ;; *) fail "the terminal marker should now print, got: $out" ;; esac

# 5. THE CAVEAT, asserted rather than assumed: the ledger names the WORK head,
#    which the attested head DESCENDS FROM. An auditor grepping the ledger for
#    the terminal head concludes the bug is present when it is not.
[ "$WORK_HEAD" != "$TERMINAL_HEAD" ] || fail "fixture is not exercising the head-moves case"
grep -q "$TERMINAL_HEAD" "$LEDGER" && fail "the ledger must NOT name the terminal head"
git merge-base --is-ancestor "$WORK_HEAD" "$TERMINAL_HEAD" || fail "recorded head must be an ancestor of the attested head"

# ---- cycle 2 -------------------------------------------------------------
# 6. A NEW CYCLE HAS RECORDED NOTHING. Without clearing the stamp, one
#    successful record would license every later marker forever — the original
#    defect with a longer fuse.
rm -rf "$BOUNDARY"; snapshot
echo more > more.txt && git add . && git commit -qm "second cycle work" && git push -q origin work
verify
out="$(self_out)"
case "$out" in
    *"wrote no durable ledger record"*) ;;
    "MO-FULL: COMPLETE"*) fail "REGRESSION: a previous cycle's record licensed this cycle's marker" ;;
    *) fail "expected the no-record refusal in cycle 2, got: $out" ;;
esac

# 7. BLOCKED is exempt: a cycle reporting it did not finish must still be able
#    to say so, and requiring a record there would silence exactly that.
out="$(MO_FULL_DISPOSITION=BLOCKED "$ATTEST" self 5 2>&1)"
case "$out" in "MO-FULL: BLOCKED"*) ;; *) fail "BLOCKED should not require a record, got: $out" ;; esac

if [ "$failures" -gt 0 ]; then
    echo "FAILED: $failures case(s)"
    exit 1
fi
echo "ok: mo-full record-precedes-marker fixture 7/7"
