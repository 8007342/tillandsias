#!/usr/bin/env bash
# ORDER 626-w3fn — every end-user UX string in the code must still be the one the
# operator APPROVED in the ledger.
#
# WHY A GATE AND NOT A UNIT TEST, and this was measured rather than assumed.
# bringup_progress.rs carries a test asserting the emitted line equals the
# approved template. That test lives in the SAME FILE as the string it checks,
# so a single find-and-replace edits the constant and the assertion together and
# the suite stays green. Verified: rewording "Getting your workspace ready…" to
# "Setting up your workspace…" across that file leaves all six tests passing.
# A guard co-edited by its own subject is not a guard.
#
# The vocabulary test still fires for a reword that introduces a BANNED word
# (measured: "Preparing the container stack…" trips it). But the change the
# approval gate exists to prevent is an unapproved reword that happens to use
# clean vocabulary, and nothing caught that.
#
# So the anchor is the LEDGER — a different file, written by a different actor,
# which a source edit cannot co-modify. spec:tray-ux requires approval "recorded
# in the plan ledger (an operator_note or operator-attributed event on the
# packet)", so the ledger is not merely a convenient second copy: it is where the
# authority actually lives. This check asks the code to agree with it.
#
# WHAT THIS DOES NOT DO: it does not verify that an approval EXISTS for a string
# nobody has added yet, and it cannot tell an operator_note from a persuasive
# note that calls itself one. It closes the drift-after-approval hole, which is
# the one that is mechanically checkable.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

# ── THE TABLE ────────────────────────────────────────────────────────────────
#
# One row per user-visible string that carries a POST-GOVERNANCE operator
# approval, as: <source-file>|<extractor-sed>|<label>.
#
# ONLY POST-2026-07-22 APPROVALS BELONG HERE, and that date is the whole reason
# this table is short. The UX curation rule was codified 2026-07-21
# (01696cd54); strings that shipped before it were never approved under it and
# enforcing them now would be inventing an approval nobody gave. Adding a row
# means asserting that an operator_note in the ledger records THIS EXACT string.
#
# WHY NOT AUTO-DISCOVER EVERY USER-VISIBLE STRING: measured, locales/en.toml
# carries 168 of them and exactly one has a recorded post-governance approval.
# A gate that demanded ledger backing for all 168 would be red on its first run
# and switched off by the next person, which is how a governance check becomes
# decoration. The audit lives in the ledger (929-47u8); the GATE covers what is
# genuinely approved, and grows a row at a time as approvals are granted.
UX_ROWS="
crates/tillandsias-headless/src/bringup_progress.rs|s/^const APPROVED_SENTENCE: &str = \"\(.*\)\";$/\1/p|bring-up progress (626-w3fn)
"

# operator_notes — every operator_note event body in the ledger, and nothing
# else. Captures from a `type: operator_note` line until the next event or
# packet boundary, which is the shape tillandsias-plan append-event writes.
# Fragments under plan/index.d/ are included: an approval recorded today lives
# there until the next compaction, and a guard that missed it would refuse a
# string the operator had just approved.
operator_notes() {
    awk '
        # An event opens with `- type: <kind>`. Entering an operator_note turns
        # capture ON; entering any OTHER event turns it OFF. Anchoring on the
        # leading dash matters: `type:` alone also matches the `- type:` line of
        # every other event kind, and the first draft here required a
        # line-initial `type:` and therefore captured nothing at all — the check
        # went red on a clean tree, which is at least the honest direction to
        # fail in.
        /^[[:space:]]*-[[:space:]]*type:[[:space:]]*operator_note[[:space:]]*$/ { inside = 1; next }
        /^[[:space:]]*-[[:space:]]*type:/ { inside = 0; next }
        /^[[:space:]]*-[[:space:]]*packet_id:/ { inside = 0; next }
        /^[[:space:]]*(packets|events|status):[[:space:]]*$/ { inside = 0; next }
        inside { print }
    ' "$LEDGER" "${FRAGMENTS[@]}" "${ARCHIVES[@]}" 2>/dev/null
}

# Fragment list resolved ONCE, tolerating an EMPTY index.d: a fully compacted
# ledger leaves no fragments, the bare glob then reaches awk as a literal
# filename, awk exits 2 after the base file — and under this script's
# pipefail that nonzero poisons `operator_notes | grep -q` even when the
# grep MATCHED. First fired on the first complete compaction (941-trcf):
# every approval looked missing on a tree where every approval was present.
FRAGMENTS=()
for _f in plan/index.d/*.yaml; do
    [ -e "$_f" ] && FRAGMENTS+=("$_f")
done
# The ARCHIVE is a ledger source too (911-m7js cycle, 2026-09-02): an approval
# is a durable fact about a string, and the packet that carries it completes
# and gets archived like any other. The first archiver sweep after 626-w3fn
# landed moved first-run-long-work-is-silent-across-surfaces — and its
# operator_note for "Getting your workspace ready…" — into plan/archive/, and
# this gate went red on a tree where nothing about the string had changed.
ARCHIVES=()
for _f in plan/archive/*.yaml; do
    [ -e "$_f" ] && ARCHIVES+=("$_f")
done

LEDGER="plan/index.yaml"
[ -f "$LEDGER" ] || { echo "skip:approved-ux-strings:no-ledger"; exit 0; }

# THE LOOP IS NOT PIPED INTO, and that is load-bearing rather than stylistic.
# The first version of this generalization was `printf '%s' "$UX_ROWS" | while
# read …`, which puts the loop body in a SUBSHELL: its `exit 1` ended the
# subshell, `fail=1` never escaped, and the check reported ok:…:1 while the
# clean-vocabulary reword sat in the tree. MEASURED — the mutation test that is
# this packet's whole bar returned rc=0. A guard generalized into silence is
# worse than the single-string version it replaced, because it now looks like it
# covers more.
#
# A here-string keeps the loop in THIS shell, so a failure is visible to the
# verdict below.
fail=0
checked=0
while IFS='|' read -r src extractor label; do
    [ -n "$src" ] || continue
    if [ ! -f "$src" ]; then
        echo "blocked:approved-ux-strings:missing-source — $src ($label)" >&2
        fail=1
        continue
    fi
    sentence="$(sed -n "$extractor" "$src" | head -1)"
    checked=$((checked + 1))
    if [ -z "$sentence" ]; then
        echo "blocked:approved-ux-strings:no-string — could not extract from $src ($label)" >&2
        fail=1
        continue
    fi
    # SEARCH ONLY operator_note BODIES, never the whole ledger.
    #
    # THE BUG THIS AVOIDS, found by mutation-testing this very check and it is
    # the sharpest thing in this packet: searching the whole ledger means any
    # PROSE MENTION of a string counts as approval. My own 626-w3fn and 929-47u8
    # notes quote "Setting up your workspace…" as the counterexample that
    # defeated the in-file test — so the guard, asked whether that reword was
    # approved, found it in the ledger and said yes. A guard SATISFIED by the
    # documentation of its own counterexample.
    #
    # spec:tray-ux is precise about where authority lives: "an operator_note or
    # operator-attributed event on the packet". So the search is scoped to those
    # event bodies, which is what the rule actually says, not merely what is
    # convenient to grep.
    if operator_notes | grep -qF "$sentence"; then
        continue
    fi
    fail=1
    cat >&2 <<EOF
[check-approved-ux-strings] UNAPPROVED end-user UX string.

  surface   : $label
  in code   : $src
  string    : "$sentence"
  ledger    : $LEDGER — no operator approval records this exact string

spec:tray-ux, Requirement "UX curation governance": no agent may alter any
user-visible surface "without EXPLICIT prior operator approval recorded in the
plan ledger", and the change "MUST NOT be implemented until the packet carries
recorded operator approval for that exact surface change".

If you changed this text: revert it, or get the new wording approved by the
operator and recorded as an operator_note on the packet FIRST. Precedent for
getting this wrong is on the record — the reset-guest menu leaf, added
2026-07-21 without approval, removed by operator order 2026-07-22.
EOF
done <<EOT
$UX_ROWS
EOT

# A table that checked NOTHING is a failure, not a pass. Otherwise deleting the
# table — or breaking its parsing — reads as a clean tree.
if [ "$checked" -eq 0 ]; then
    echo "blocked:approved-ux-strings:empty-table — no row was checked; the table is empty or unparseable" >&2
    echo "blocked:approved-ux-strings:0"
    exit 1
fi

if [ "$fail" -ne 0 ]; then
    echo "blocked:approved-ux-strings:${checked}"
    exit 1
fi

echo "ok:approved-ux-strings:${checked} checked against the ledger"
exit 0
