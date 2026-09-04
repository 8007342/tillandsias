#!/usr/bin/env bash
# @trace spec:methodology-accountability
# @trace order:944-vim8, order:635-i6vm
#
# ORDER 944-vim8. Refuse a `plan/index.d/` fragment whose top-level keys the
# FOLD DOES NOT READ.
#
# THE DEFECT THIS EXISTS FOR, measured 2026-08-30. Four packets were filed
# across four cycles in fragments keyed `steps:` — the key the BASE ledger
# (`plan/index.yaml`) uses. The fold reads `packets:`, `events:`, `fields:` and
# `status:` and nothing else (crates/tillandsias-plan/src/fragments.rs). Every
# one of those fragments:
#   * parsed as YAML,
#   * passed `tillandsias-plan validate-yaml`,
#   * passed `tillandsias-plan check` (which reported the SAME packet count
#     before and after — 696, then 700 once they were re-filed correctly),
#   * read correctly to a human in review,
#   * and was silently discarded by the next compaction, surviving in the base
#     only as prose inside other packets' next_action.
# The failure was indistinguishable from success at EVERY checkpoint a worker
# has. It surfaced only because an unrelated fixture
# (append-event-archived-refusal) went red when its live-packet arm ran out of
# other candidates.
#
# This is the G-Set no-op the worker skill's §7.2 documents for STATUS
# re-declaration (635-i6vm: 11 of 21 completions discarded that way), met again
# at packet DEFINITION. §7.2 warns about the symptom it was bitten by; nothing
# generalised it to "a fragment key the fold does not read".
#
# WHY A KEY ALLOWLIST AND NOT A SCHEMA CHECK. The question is not whether the
# content is well-formed — it always was. The question is whether the fold will
# LOOK at it. That is answered by one thing: the top-level key.
#
# Verdict grammar, one line on stdout:
#   ok:fragment-keys:<n> fragment(s) checked      exit 0
#   violation:fragment-keys:<n> unread key(s)     exit 1
#   blocked:<reason>                              exit 2
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

FRAG_DIR="${TILLANDSIAS_FRAGMENT_DIR:-plan/index.d}"
[ -d "$FRAG_DIR" ] || { echo "blocked:fragment-dir-missing:$FRAG_DIR"; exit 2; }

# The keys fragments.rs folds. Kept as a literal list rather than parsed out of
# the Rust, because a parser that guessed wrong would fail OPEN — and failing
# open is the whole defect. If the fold learns a new channel, this list is
# updated in the same commit; the litmus asserts the list matches the source.
#
# `capabilities` was added on 2026-09-02 after this list had already drifted from
# it: the fold has read that channel since 843-624y (LWW by (ts, host), and
# fold_capability_rows above), and the list had not been updated in the same
# commit — the exact staleness the paragraph above warns about. The effect was a
# deadlock, not a lost fragment: 850-bif2 makes publishing a capability row a
# daily obligation and this guard refused every row the generator produced.
# The litmus arm now iterates the same five names, so the next channel cannot
# drift silently either.
READ_KEYS=" packets events fields status capabilities "

# CHANNELS THE FOLD DELIBERATELY DOES NOT READ, AND MUST NOT BE REFUSED FOR IT.
#
# Order 793-qr4t, measured on lenovinha 2026-09-02: this guard failed
# `./build.sh --check` on a capability row that the Start-Of-Day gate had just
# told the host to publish, using the generator the skill names
# (`host-capability-probe.sh --fragment`). Every host that publishes a row —
# which 850-bif2 requires before it drains work — would hit the same refusal.
#
# THE GUARD'S PREMISE IS TRUE OF `steps:` AND THIS LIST IS WHERE AN EXCEPTION GOES.
#
# `steps:` was a key nobody read: the fold discarded those fragments and NOTHING
# ELSE looked at them, so the contents were genuinely lost. A channel with a
# non-fold CONSUMER is different, and belongs here rather than in READ_KEYS —
# adding to it is a claim someone can check: name the consumer.
#
# `capabilities` WAS listed here (793-qr4t, lenovinha) and has been removed by
# the coordinator, by the rule this comment itself prescribed: "when 846-idhn
# lands a base representation for capability rows, `capabilities` moves from
# here into READ_KEYS". 846-idhn is completed and archived; compaction now
# serialises `capabilities:` into the base (fragments.rs, ORDER 846-idhn) and
# plan/index.yaml carries the key. So the fold both READS the channel
# (fold_capabilities) and WRITES it, which is exactly what READ_KEYS asserts.
#
# WHY THIS NEEDED A THIRD PARTY. Two hosts fixed the same deadlock the same
# hour, independently and both defensibly: macbook widened READ_KEYS, lenovinha
# added this allowlist because widening looked like it would make the litmus
# assertion false to buy silence. It would have, BEFORE 846-idhn. Both landed,
# and the merged result listed one key in two lists that mean opposite things —
# with READ_KEYS matched first, so the allowlist entry was also dead. Neither
# host could see it: each was looking at its own branch, and both gates passed.
NON_FOLD_CHANNELS=" "

violations=0
checked=0
for f in "$FRAG_DIR"/*.yaml; do
    [ -e "$f" ] || continue
    checked=$((checked + 1))
    # Top-level keys are column-0 `name:` lines. Comments and list items are not.
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        case "$READ_KEYS" in
            *" $key "*) continue ;;
        esac
        case "$NON_FOLD_CHANNELS" in
            *" $key "*) continue ;;
        esac
        echo "  $f" >&2
        echo "    top-level key '$key' is NOT read by the fold — this fragment's" >&2
        echo "    contents will be silently discarded at the next compaction." >&2
        echo "    The fold reads:$READ_KEYS" >&2
        echo "    A packet definition belongs under 'packets:' (a G-Set keyed by" >&2
        echo "    packet_id); the base ledger's 'steps:' key is NOT a fragment key." >&2
        violations=$((violations + 1))
    done < <(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*:' "$f" 2>/dev/null | sed 's/:$//')
done

if [ "$violations" -ne 0 ]; then
    echo "violation:fragment-keys:${violations} unread key(s)"
    exit 1
fi

echo "ok:fragment-keys:${checked} fragment(s) checked"
exit 0
