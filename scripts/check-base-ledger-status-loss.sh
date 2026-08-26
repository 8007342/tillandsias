#!/usr/bin/env bash
# @trace order:751-i9mb, spec:methodology-accountability
#
# ORDER 751-i9mb. The closure-event pass, applied where the events ACTUALLY LIVE.
#
# THE GAP THIS CLOSES
#
# scripts/check-fragment-status-loss.sh reads "$FRAG_DIR"/*.yaml — plan/index.d
# only. Compaction folds every fragment INTO plan/index.yaml, so the moment a
# ledger is compacted, every closure event it carried moves somewhere that
# checker cannot see. Nothing re-examines the base after a fold.
#
# MEASURED 2026-08-15: packet 532 (inference-state-warm-grammar-multimodel) read
# `in_progress` while its work was done and on the remote — the litmus step its
# exit criterion names was committed and passing, and the ledger carried TWO
# closure events for it. A `claim` event landed AFTER both and left the status
# non-terminal, so the packet advertised itself as claimable work whose exit
# criterion was already green. That is the mechanical root of agents "going in
# circles on work that is already done".
#
# `./build.sh --check` was green throughout, including
# `ok:no-fragment-status-loss:16 checked` — sixteen fragments checked, and the
# one packet with the defect was not among them because it no longer lived in a
# fragment.
#
# WHY THIS IS A SEPARATE SCRIPT, AND NOT A PASS INSIDE THE GATE
#
# The packet's exit criteria require this to be ADVISORY: "report and let a
# cycle check exit criteria. Auto-promoting a status from an event is how a
# false completion becomes permanent — 532 was only closable because its litmus
# was re-run and passed." check-fragment-status-loss.sh is a HARD GATE on two
# surfaces (build.sh exits 1; the pre-push plan-only lane refuses). Folding an
# advisory pass into a gate makes the two severities share one exit code, and
# the first time this reports a false positive on a historical base row, someone
# turns the whole gate off. Separate script, distinct verdict vocabulary, always
# exit 0 — the severities cannot blur because they are not in the same process.
#
# WHY IT DOES NOT AUTO-CORRECT ANYTHING
#
# Deliberately, per the packet: the event log is append-only and honest, status
# is a separate LWW channel by design (ledger_write_path), and coupling them
# would break the intentional `implemented` -> field-verification hand-off. A
# terminal event beside a non-terminal status is a QUESTION for a cycle, not a
# fact to apply. Closing a packet requires checking its exit criteria against
# the tree; guessing marks unfinished work done, which is strictly worse than
# leaving it stranded.
#
# GRAMMAR (exactly one line on stdout)
#   ok:no-base-status-loss:<n> checked      n base packets examined, none adrift
#   advisory:base-status-loss:<n>           n carry a closure event beside a
#                                           non-terminal status; each named on
#                                           stderr
#   skip:no-base-ledger                     no plan/index.yaml here
#   skip:plan-binary-unavailable            cannot resolve the fold
#   skip:base-ledger-unparseable            the base did not parse (787-f7dh) —
#                                           NOT `ok:`, because an unexamined
#                                           ledger reported as clean is the very
#                                           failure this file exists for
#
# EXIT 0 ALWAYS. Branch on the verdict, never on the exit code. An advisory that
# can fail a build is a gate wearing an advisory's name, and it would be turned
# off the first time it was wrong.

set -uo pipefail


# ORDER 799-tb7q — resolve `jq` through the shared host-preferred /
# toolbox-fallback dispatch instead of assuming the host has it.
# shellcheck source=scripts/lib/tool-dispatch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/tool-dispatch.sh" 2>/dev/null || true
if command -v resolve_tool >/dev/null 2>&1; then
    JQ="$(resolve_tool jq || printf 'jq')"
else
    JQ="jq"   # lib unavailable: preserve the previous behaviour exactly
fi

ROOT="${BASE_STATUS_LOSS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" || exit 0

BASE="${BASE_STATUS_LOSS_INDEX:-plan/index.yaml}"
[ -f "$BASE" ] || { echo "skip:no-base-ledger"; exit 0; }

# The shared probe (704-zcgi), resolving by EXECUTION rather than by an
# executable bit (721-nyev).
. "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
PLAN="$(resolve_plan_binary)" || PLAN=""
if [ -z "$PLAN" ]; then
    echo "skip:plan-binary-unavailable"
    echo "  note: tillandsias-plan is not built, so the base closure pass did not run." >&2
    exit 0
fi

# A binary predating the subcommand skips LOUDLY rather than inventing a
# verdict — the 702-68zj ruling. Note the subcommand ALSO had to be taught to
# read a base ledger at all (751-i9mb): it walked `doc["packets"]` only, while
# the base keeps packets at `plan_index.steps[]`, so it parsed the whole file
# and printed nothing with exit 0. A binary from before that fix reports every
# base as clean, which is exactly the silence being closed here — so an old
# binary must never reach the `ok:` line.
if ! plan_binary_has "$PLAN" fragment-terminal-events; then
    echo "skip:plan-binary-unavailable"
    echo "  note: this tillandsias-plan predates fragment-terminal-events; rebuild it (scripts/cycle-preflight.sh)." >&2
    exit 0
fi

# `--live` applies the WITHDRAWAL rule: a closure a later `falsified` event
# retracted is not a live declaration, so a withdrawn completion does not report
# forever. The flag is opt-in precisely so the sibling GATE
# (check-fragment-status-loss.sh) keeps the plain syntactic question it has
# always asked.
declared="$("$PLAN" fragment-terminal-events "$BASE" --live 2>/dev/null)"
rc=$?
if [ "$rc" -eq 3 ]; then
    # ORDER 787-f7dh. Silence from a parser is not evidence of absence.
    echo "skip:base-ledger-unparseable"
    echo "  note: $BASE did not parse, so every terminal event it declares is UNEXAMINED." >&2
    exit 0
fi
if [ -z "$declared" ]; then
    echo "ok:no-base-status-loss:0 checked"
    exit 0
fi

# The FOLDED status is the question — not the status written beside the packet
# in the base, which a later fragment may have superseded. One batched call
# (783-xyk5) rather than a `status` invocation per packet.
status_map=""
if plan_binary_has "$PLAN" query && command -v jq >/dev/null 2>&1; then
    status_map="$("$PLAN" query --json --limit 0 2>/dev/null \
        | "$JQ" -r '.[] | select((.packet_id // "") != "") | [.packet_id, (.status // "")] | @tsv' 2>/dev/null)"
fi
if [ -z "$status_map" ]; then
    echo "  note: batched fold unavailable ($PLAN query --json); falling back to per-packet status lookups" >&2
    status_map="$(printf '%s\n' "$declared" | while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        s="$("$PLAN" status "$pid" 2>/dev/null | awk '{print $2}')"
        [ -n "$s" ] && printf '%s\t%s\n' "$pid" "$s"
    done)"
fi

# One awk join. M rows load the map first, D rows are the declarations.
# A packet absent from the map is SKIPPED, not reported: `query` reads the LIVE
# fold only, while archived rows still answer through other surfaces, so an
# archived packet would otherwise be flagged as adrift on every run
# (the c1f6595c5 "archived rows still answer" case).
report="$( { printf '%s\n' "$status_map" | sed 's/^/M\t/'
             printf '%s\n' "$declared"   | sed 's/^/D\t/'; } | awk -F'\t' '
    $1 == "M" { st[$2] = $3; next }
    $1 == "D" {
        pid = $2
        if (pid == "") next
        if (!(pid in st)) next
        s = st[pid]
        if (s == "completed" || s == "verified" || s == "done" || s == "obsoleted") next
        printf "%s\tCOUNTED\t%s\n", pid, s
    }
')"

# `printf '%s\n'`, NOT `printf '%s'`. `wc -l` counts NEWLINES, so a final line
# with no terminator is not counted — with `%s` a single-row report measured as
# zero and this advisory could never fire on the one-defect case, which is the
# common one. It read `ok:` while holding the finding in a variable. Caught by
# fixture case 1 on the first run; without that case it would have shipped as a
# guard that always passes, which is the exact class this file exists to close.
checked="$(printf '%s\n' "$declared" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
adrift="$(printf '%s\n' "$report" | sed '/^$/d' | wc -l | tr -d ' ')"

if [ "${adrift:-0}" -eq 0 ]; then
    echo "ok:no-base-status-loss:${checked} checked"
    exit 0
fi

echo "advisory:base-status-loss:${adrift}"
printf '%s\n' "$report" | while IFS=$'\t' read -r pid _tag st; do
    [ -n "$pid" ] || continue
    echo "  advisory: ${pid} declares a terminal event in ${BASE} but folds as '${st}'" >&2
done
{
    echo "  WHAT THIS MEANS: the work may be finished while the packet still advertises"
    echo "  itself as claimable — the 532 shape, and the mechanical reason agents go in"
    echo "  circles on work that is already done."
    echo "  WHAT TO DO: check the packet's exit criteria AGAINST THE TREE. If they hold,"
    echo "  close it with evidence (set-field ... --evidence). If they do not, the event"
    echo "  is the thing that is wrong. Do NOT promote a status from an event alone —"
    echo "  532 was only closable because its litmus was re-run and passed."
    echo "  This is ADVISORY and never fails a build (order 751-i9mb)."
} >&2
exit 0
