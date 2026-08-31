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
READ_KEYS=" packets events fields status "

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
