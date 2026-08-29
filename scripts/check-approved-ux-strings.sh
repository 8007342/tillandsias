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

SRC="crates/tillandsias-headless/src/bringup_progress.rs"
LEDGER="plan/index.yaml"
fail=0

[ -f "$SRC" ]    || { echo "skip:approved-ux-strings:no-source"; exit 0; }
[ -f "$LEDGER" ] || { echo "skip:approved-ux-strings:no-ledger"; exit 0; }

# The approved sentence, read from the constant rather than hardcoded here —
# hardcoding it would make THIS file a third copy that can drift.
sentence="$(sed -n 's/^const APPROVED_SENTENCE: &str = "\(.*\)";$/\1/p' "$SRC" | head -1)"
if [ -z "$sentence" ]; then
    echo "blocked:approved-ux-strings:no-constant — APPROVED_SENTENCE not found in $SRC" >&2
    echo "blocked:approved-ux-strings:1"
    exit 1
fi

# grep -F: the sentence contains a typographic ellipsis and parentheses; it is a
# literal, never a pattern.
if grep -qF "$sentence" "$LEDGER"; then
    echo "ok:approved-ux-strings:1 checked (\"$sentence\" is recorded in the ledger)"
    exit 0
fi

cat >&2 <<EOF
[check-approved-ux-strings] UNAPPROVED end-user UX string.

  in code   : $SRC
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
echo "blocked:approved-ux-strings:1"
exit 1
