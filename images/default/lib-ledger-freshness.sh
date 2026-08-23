#!/usr/bin/env bash
# @trace order:835-h2wq, spec:default-image
#
# lib-ledger-freshness.sh — how stale is the checkout an in-forge expert
# answers from, measured against the mirror the clone already carries?
#
# WHY (order 835-h2wq). A forge seeded from an old branch builds a WORKING
# expert over an old ledger, and its answers are confident, well-cited, and
# wrong-for-today — the operator was told to re-seed a healthy Vault token by
# an agent reading a two-day-old ledger. A refusal is legible; a confident
# stale answer is not. This function makes the staleness VISIBLE: the startup
# context states the head being answered from and how far the newest mirror
# branch is ahead of it.
#
# PROJECT-AGNOSTIC BY CONSTRUCTION (the base_state scope rule): no branch is
# judged by NAME. The measure is a fact about any clone — the newest
# committer-date across origin heads minus the checkout HEAD's committer-date,
# floored at zero. The clone-from-mirror routine fetches all mirror heads, so
# the comparison needs no network.
#
# Sourced by inject_startup_context in lib-common.sh, and SEPARATELY
# SOURCEABLE outside the forge image (lib-common.sh hard-fails at source time
# on the vendor CA bundle — the lib-inference-state.sh precedent), so the
# fixture in litmus:forge-ledger-freshness-shape exercises the real function
# against a seeded repo instead of grep-pinning a heredoc.
#
# Contract: tillandsias_ledger_freshness <project_dir> always returns 0 and
# sets:
#   TILLANDSIAS_BASE_HEAD      short HEAD sha, or `unknown`
#   TILLANDSIAS_LEDGER_LAG_H   whole hours the newest origin head is ahead of
#                              HEAD's commit time; 0 when current, equal, or
#                              unknowable (never guessed negative)
#   TILLANDSIAS_LEDGER_NEWEST  the origin/<branch> holding that newest commit
#                              (origin/ prefix stripped), or `unknown`

tillandsias_ledger_freshness() {
    local project_dir="${1:-}"
    TILLANDSIAS_BASE_HEAD="unknown"
    TILLANDSIAS_LEDGER_LAG_H=0
    TILLANDSIAS_LEDGER_NEWEST="unknown"
    [[ -n "$project_dir" && -d "$project_dir" ]] || return 0

    local head_sha head_ts newest_line newest_ref newest_ts
    head_sha="$(git -C "$project_dir" rev-parse --short HEAD 2>/dev/null || true)"
    [[ -n "$head_sha" ]] && TILLANDSIAS_BASE_HEAD="$head_sha"

    head_ts="$(git -C "$project_dir" log -1 --format=%ct 2>/dev/null || true)"
    # origin/HEAD is a symref clone creates (short name: bare `origin`); it
    # duplicates whichever branch it points at and must not shadow the real
    # newest branch's NAME in the report.
    newest_line="$(git -C "$project_dir" for-each-ref refs/remotes/origin \
        --sort=-committerdate \
        --format='%(refname:short) %(committerdate:unix)' 2>/dev/null \
        | while read -r _ref _ts; do
            case "$_ref" in origin | origin/HEAD) continue ;; esac
            printf '%s %s\n' "$_ref" "$_ts"
            break
        done)"
    newest_ref="${newest_line% *}"
    newest_ts="${newest_line##* }"

    if [[ -n "$newest_ref" && "$newest_ref" != "$newest_line" ]]; then
        TILLANDSIAS_LEDGER_NEWEST="${newest_ref#origin/}"
    fi
    if [[ "$head_ts" =~ ^[0-9]+$ && "$newest_ts" =~ ^[0-9]+$ ]] \
        && [[ "$newest_ts" -gt "$head_ts" ]]; then
        TILLANDSIAS_LEDGER_LAG_H=$(( (newest_ts - head_ts) / 3600 ))
    fi
    return 0
}
