#!/usr/bin/env bash
# ORDER 1083-gzqj. A number a gate compares against must have been CHOSEN, and
# the choice must be written down.
#
# THE TEST TO APPLY, which is the packet's general form rather than a pattern to
# grep: find the number, and ask WHO CHOSE IT AND WHERE THAT CHOICE IS RECORDED.
# If the answer is "whatever the tree measured when the arm was written", it is
# NOT A THRESHOLD, IT IS A SNAPSHOT. A snapshot in a gate fires later, on a host
# that changed nothing, with a label pointing at the wrong subsystem.
#
# WHAT THIS FIXTURE IS NOT: a ban on comparing against live content. The
# negative control below is the whole reason — a DECLARED vacuity floor whose
# number was chosen and stated is correct and must keep passing. Two independent
# sweeps examined that case and both cleared it. A remedy that outlawed it would
# be worse than the defect, because the honest response would then be to delete
# vacuity guards rather than to state their numbers.
#
# REGIME. Every arm reads the CURRENT tree and asserts a structural property of
# the fixture sources named in 1083-gzqj. These are assertions about test code,
# so they are necessarily textual; each one names the exact construct it forbids
# and why, so a reader can tell a real regression from a reformat. No arm
# asserts an absolute moment or a count of anything that grows.
#
# Prints one PASS/FAIL summary line and exits 0/1.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

pass=0
fail=0
ok()  { echo "ok:   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail + 1)); }

CRED="scripts/test-check-credential-channel.sh"
SELECTOR="scripts/test-selector-drops-cross-branch-claims.sh"
HOOKS="scripts/test-forge-project-guard-hooks.sh"
CONTROL="scripts/test-precommit-zero-trace-scan-scope.sh"

for f in "$CRED" "$SELECTOR" "$HOOKS" "$CONTROL"; do
    [ -f "$f" ] || { bad "$f is missing — this fixture cannot assert over a file that is not there"; }
done

# ── ARM 1 — THE ARMED ONE. A live-tree-derived COUNT compared against a
#           literal, with zero margin. Measured on macuahuitl 2026-09-05 and
#           again on lenovinha: the probe count was exactly 3 against a `-le 3`
#           ceiling at HEAD, HEAD~10 and HEAD~30. The next refusal class needing
#           its own `push --dry-run` would have red the LANDING GATE on every
#           host, under a message blaming reverify.
# COMMENTS ARE NOT CODE, and this fixture got that wrong on its first run: the
# replacement in $CRED QUOTES the old assertion to explain what was removed, and
# a bare grep matched that comment and reported the defect still present. That is
# precisely the incidental-co-occurrence error $CRED's own header records
# (888-m75r) — "counted two COMMENT lines describing the probe" — reproduced in
# the fixture written to police it. Strip comment lines before matching.
if grep -vE '^[[:space:]]*#' "$CRED" | grep -qE '\[ *"\$probes" *-le *[0-9]+ *\]'; then
    bad "ARM 1: $CRED still compares a probe COUNT against a literal ceiling — nobody chose that number; assert where probes live, not how many there are"
else
    ok "ARM 1: the probe-count ceiling is gone from $CRED"
fi
# And the replacement asserts the property the old comment already claimed.
if grep -q 'credential_channel_verdict()' "$CRED"; then
    ok "ARM 1: $CRED asserts probes are confined to the verdict function (structural, no number)"
else
    bad "ARM 1: $CRED no longer scopes probes to credential_channel_verdict() — the replacement property is missing, so removing the count only deleted coverage"
fi

# ── ARM 2 — THE VACUITY BASELINE MUST NOT BE THE LIVE POOL. The selector
#           fixture required the REAL selector against the LIVE ledger to emit a
#           packet, so it red whenever the linux ready pool emptied — which a
#           sibling holding rows or a release bump causes with no code change.
if grep -q 'TILLANDSIAS_PLAN_BIN=' "$SELECTOR"; then
    ok "ARM 2: $SELECTOR drives the selector through a pinned ledger, not the fleet's"
else
    bad "ARM 2: $SELECTOR does not override TILLANDSIAS_PLAN_BIN — its baseline is back on the live ledger and any sibling can red it"
fi
if grep -qE '_FIXTURE_INDEX|fixture-index\.yaml' "$SELECTOR"; then
    ok "ARM 2: the ledger the selector reads is a fixture this file owns"
else
    bad "ARM 2: no fixture ledger in $SELECTOR — the batch is whatever the fleet happens to be holding"
fi

# ── ARM 3 — A HARDCODED LIST THAT MUST TRACK A REAL SET DECLARES THE COUPLING.
#           Eight hook sources were transcribed by name; adding a ninth to
#           install-hooks.sh failed at hook INSTALLATION rather than at the
#           stale list, misattributing the fault.
if grep -qE "for h in pre-commit-openspec\.sh" "$HOOKS"; then
    bad "ARM 3: $HOOKS still transcribes the hook source list — a ninth hook will fail here as an installation fault"
else
    ok "ARM 3: the transcribed hook list is gone from $HOOKS"
fi
if grep -q 'install-hooks.sh' "$HOOKS" && grep -qE "grep -oE 'scripts/hooks/" "$HOOKS"; then
    ok "ARM 3: $HOOKS derives its hook set from install-hooks.sh, the source of truth"
else
    bad "ARM 3: $HOOKS does not derive the set from install-hooks.sh — the coupling is undeclared again"
fi

# ── NEGATIVE CONTROL — and it is what stops this becoming a ban on live-tree
#     assertions. `n_all -gt 20` compares against the live tree, chose its
#     number deliberately, states why in a comment, and guards a NAMED vacuity.
#     Both independent sweeps examined it and both cleared it. If this arm ever
#     reds, the remedy has overreached and is now deleting legitimate guards.
if grep -qE '\-gt 20' "$CONTROL"; then
    ok "NEGATIVE CONTROL: the declared vacuity floor in $CONTROL is untouched — a chosen, stated number still passes"
else
    bad "NEGATIVE CONTROL BREACHED: the declared floor in $CONTROL is gone. This remedy is about numbers NOBODY CHOSE; a chosen and stated floor is correct and must survive"
fi
if grep -qE 'vacuous|vacuity' "$CONTROL"; then
    ok "NEGATIVE CONTROL: that floor still states what it guards against"
else
    bad "NEGATIVE CONTROL: $CONTROL no longer says what its number is for — a stated choice that stops being stated becomes a snapshot again"
fi

echo "gate-thresholds-are-chosen: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
