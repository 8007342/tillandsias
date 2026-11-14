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

    # ORDER 2049-ndde (openspec forge-lua-helpers D3.3): the three git reads
    # are lua/ledger-freshness.lua on `tillandsias-plan script run --helper`.
    # The module sits beside this file (images/default/lua/ in a checkout,
    # /usr/local/lib/tillandsias/lua/ in the image). Without the runner or the
    # module the values stay unknown / 0 / unknown, which this contract already
    # defines as "unknowable": never a guessed lag. No second implementation.
    local lua="" c vals head lag newest
    for c in "${BASH_SOURCE[0]%/*}/lua/ledger-freshness.lua" /usr/local/lib/tillandsias/lua/ledger-freshness.lua; do
        if [[ -r "$c" ]]; then lua="$c"; break; fi
    done
    [[ -n "$lua" ]] && command -v "${TILLANDSIAS_PLAN_BIN:-tillandsias-plan}" >/dev/null 2>&1 || return 0
    vals="$("${TILLANDSIAS_PLAN_BIN:-tillandsias-plan}" script run --helper "$lua" -- "$project_dir" 2>/dev/null)" || return 0
    # Three lines in a fixed order (the module's header): head, lag_h, newest.
    {
        IFS= read -r head
        IFS= read -r lag
        IFS= read -r newest
    } <<<"$vals"
    [[ -n "$head" ]] && TILLANDSIAS_BASE_HEAD="$head"
    [[ "$lag" =~ ^[0-9]+$ ]] && TILLANDSIAS_LEDGER_LAG_H="$lag"
    [[ -n "$newest" ]] && TILLANDSIAS_LEDGER_NEWEST="$newest"
    return 0
}
