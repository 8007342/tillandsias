#!/bin/sh
# @trace spec:forge-environment-discoverability
# @trace order:619-pfsj (project-answer-uniform-surface, exit criterion C3)
# @trace order:569 (forge-experts-capability-honesty), order:531, order:459
#
# GENERIC ANSWER ENGINE capability skew — honesty for an IMAGE-BAKED artifact.
#
# THE FAILURE THIS EXISTS TO NAME
#
# Order 531: a forge truthfully stamped `experts: ready` while every answer
# came back `confidence=unsupported`, because "ready" described the BUILD, not
# the artifact's ability to answer. lib-expert-capability.sh closed that gap
# for the plan expert — an engine BUILT AT LAUNCH from the mounted checkout,
# where "skew" means "the checkout would build something the installed binary
# is not" and the remedy is a relaunch.
#
# The generic project answer engine (project-info.sh) is a DIFFERENT packaging
# and needs the definition REDEFINED (design record constraint 3): it is baked
# into the forge image (order 459 — image builds have no network, the engine is
# pure shell, zero build), so its sources are NEVER the mounted checkout and no
# relaunch rebuilds it. A checkout that carries a newer answer contract than
# the image was baked from runs the OLD engine while every health signal reads
# green — `project-expert: ready` describes the tmpfs INDEX, not the engine.
# This helper makes that artifact-vs-source skew a named, machine-readable
# fact.
#
# WHY A SEPARATE FILE: same reason as lib-inference-state.sh and
# lib-expert-capability.sh — lib-common.sh cannot be sourced outside the forge
# image, and this helper has no import-time side effects, no jq, no python, so
# a litmus (or an operator) can execute every branch of the grammar directly
# against fixture engines on any host.
#
# PINNED GRAMMAR — the machine line agents branch on (peer of
# `expert_capability:` and `inference_state=`; closed vocabulary, no
# indeterminate state):
#
#   project_engine: state=<ready|absent|stale-engine|skewed> \
#                   baked=<engine-contract-vN|-> expected=<engine-contract-vN|-> \
#                   missing_in_engine=<csv|-> engine_only=<csv|->
#
# FIELD VOCABULARIES (all CLOSED):
#
#   state — THE LOAD-BEARING FIELD:
#     ready         an engine is present, self-reports a capability manifest,
#                   and either matches the mounted checkout's expectation or
#                   the checkout carries none (a non-Tillandsias project has no
#                   copy of the engine source — "no expectation found" is not
#                   evidence of skew, and crying skew there would be a guess;
#                   `expected=-` stays visible so nothing is hidden).
#     absent        no engine resolved at all.
#     stale-engine  an engine IS present but does not self-report a manifest —
#                   it predates the embedded-manifest contract, so its
#                   capabilities are UNKNOWABLE, not assumed. A named fact with
#                   an unambiguous action (rebuild the image), never an
#                   indeterminate state.
#     skewed        the engine self-reports AND the checkout carries an
#                   expectation AND the two sets differ — the baked engine is
#                   from a different image/version than this checkout expects.
#                   This is the order-531 shape for the generic lane, and
#                   UNLIKE plan-expert skew NO RELAUNCH HEALS IT: the engine is
#                   image-baked, so the remedy is rebuilding the forge image
#                   from this checkout.
#
#   baked         the `engine-contract-vN` token the RUNNING ARTIFACT reports
#                 for itself (`project-info.sh capabilities`, embedded in the
#                 baked script — asked of the artifact, never inferred).
#   expected      the `engine-contract-vN` token in the MOUNTED CHECKOUT's copy
#                 of the engine source, read TEXTUALLY (no execution of
#                 checkout code — the same discipline as reading
#                 capabilities.txt, because a checkout is data until vetted).
#   missing_in_engine  expectation minus engine — what this image's engine
#                 cannot do that the checkout's contract promises.
#   engine_only   engine minus expectation — what the baked engine carries that
#                 the checkout no longer expects (an image NEWER than the
#                 checkout). Suppressed (`-`) when the checkout carries no
#                 expectation, for the same no-guessing rule as
#                 `lost_on_relaunch` in lib-expert-capability.sh.
#
# CONTRACT: ALWAYS returns 0, never writes to stdout when sourced, bounded by
# the probe timeout. The engine is OPTIONAL (order 486 warn-and-continue) — a
# capability probe that breaks a launch is strictly worse than the skew it
# measures.

# Where a Tillandsias-shaped checkout keeps the engine source — the checkout's
# EXPECTATION of what the image should have baked. MUST stay identical to the
# Containerfile's COPY source for the baked engine; if these two disagree,
# `expected` silently reads none on a perfectly good checkout and every skew
# verdict collapses to `ready`.
TILLANDSIAS_PROJECT_ENGINE_SRC_REL="images/default/config-overlay/mcp/project-info.sh"

# Where the forge image bakes the engine (Containerfile: COPY config-overlay/mcp/).
TILLANDSIAS_PROJECT_ENGINE_DEFAULT="/home/forge/.config-overlay/mcp/project-info.sh"

# _tpe_clean_manifest — manifest-shaped stream in, sorted unique tokens out.
# Anything that is not a bare `[a-z][a-z0-9-]*` token is DROPPED, and an empty
# result reads as "no manifest": that is what makes a pre-manifest engine's
# output (nothing, or JSON-RPC noise) fail the shape test instead of being
# mistaken for a capability list. Same grammar as lib-expert-capability.sh.
_tpe_clean_manifest() {
    awk '
        { sub(/#.*/, "") }
        { gsub(/[ \t\r]+/, "") }
        /^[a-z][a-z0-9-]*$/ { print }
    ' 2>/dev/null | sort -u
}

# _tpe_join — newline-separated tokens -> csv, or the supplied empty-marker.
_tpe_join() {
    _tpe_j_empty="$1"
    _tpe_j_out="$(tr '\n' ',' 2>/dev/null | sed 's/,*$//' 2>/dev/null)" || _tpe_j_out=""
    if [ -z "$_tpe_j_out" ]; then
        printf '%s' "$_tpe_j_empty"
    else
        printf '%s' "$_tpe_j_out"
    fi
}

# _tpe_version <newline-separated-set> — the engine-contract-vN token, or `-`.
_tpe_version() {
    _tpe_v_out="$(printf '%s\n' "$1" | sed -n 's/^\(engine-contract-v[0-9][0-9]*\)$/\1/p' | head -1)" || _tpe_v_out=""
    printf '%s' "${_tpe_v_out:--}"
}

# _tpe_has <token> <newline-separated-set>
_tpe_has() {
    _tpe_h_needle="$1"
    for _tpe_h_t in $2; do
        if [ "$_tpe_h_t" = "$_tpe_h_needle" ]; then
            return 0
        fi
    done
    return 1
}

# _tpe_checkout_manifest <checkout> — the expectation, extracted TEXTUALLY from
# the checkout's engine source: the lines of the PROJECT_INFO_ENGINE_MANIFEST
# single-quoted block, shape-filtered. Executing checkout code here would run
# an unvetted script during a health probe; reading it keeps the same safety
# property capabilities.txt has.
_tpe_checkout_manifest() {
    _tpe_cm_file="$1/$TILLANDSIAS_PROJECT_ENGINE_SRC_REL"
    [ -r "$_tpe_cm_file" ] || return 0
    sed -n "/^PROJECT_INFO_ENGINE_MANIFEST='/,/^'/p" "$_tpe_cm_file" 2>/dev/null \
        | sed "1d;\$d" 2>/dev/null \
        | _tpe_clean_manifest
}

# tillandsias_project_engine_capability [<engine>] [<checkout>]
#
# <engine>   path to the baked engine script (defaults to the image path; may
#            be empty/absent).
# <checkout> the mounted project checkout (may be empty/absent/non-Tillandsias).
#
# Sets TILLANDSIAS_PROJECT_ENGINE_{STATE,BAKED,EXPECTED,MISSING,ONLY} and
# TILLANDSIAS_PROJECT_ENGINE_LINE.
tillandsias_project_engine_capability() {
    _tpe_bin="${1:-$TILLANDSIAS_PROJECT_ENGINE_DEFAULT}"
    _tpe_checkout="${2:-}"
    TILLANDSIAS_PROJECT_ENGINE_STATE="absent"
    TILLANDSIAS_PROJECT_ENGINE_BAKED="-"
    TILLANDSIAS_PROJECT_ENGINE_EXPECTED="-"
    TILLANDSIAS_PROJECT_ENGINE_MISSING="-"
    TILLANDSIAS_PROJECT_ENGINE_ONLY="-"
    _tpe_now_set=""
    _tpe_want_set=""

    # ── what does the BAKED ENGINE say about itself ───────────────────────
    # Asked of the ARTIFACT (order 569). stdin comes from /dev/null so a
    # pre-manifest engine — whose only mode is the JSON-RPC stdin loop — reads
    # EOF and exits silently instead of hanging the probe; its empty output is
    # then the stale-engine verdict, which is the truth.
    if [ -n "$_tpe_bin" ] && [ -x "$_tpe_bin" ]; then
        _tpe_raw=""
        if command -v timeout >/dev/null 2>&1; then
            _tpe_raw="$(timeout 5 "$_tpe_bin" capabilities </dev/null 2>/dev/null)" || _tpe_raw=""
        else
            _tpe_raw="$("$_tpe_bin" capabilities </dev/null 2>/dev/null)" || _tpe_raw=""
        fi
        _tpe_now_set="$(printf '%s\n' "$_tpe_raw" | _tpe_clean_manifest)" || _tpe_now_set=""
        if [ -z "$_tpe_now_set" ]; then
            TILLANDSIAS_PROJECT_ENGINE_STATE="stale-engine"
        else
            TILLANDSIAS_PROJECT_ENGINE_STATE="ready"
            TILLANDSIAS_PROJECT_ENGINE_BAKED="$(_tpe_version "$_tpe_now_set")"
        fi
    fi

    # ── what does the CHECKOUT expect ─────────────────────────────────────
    if [ -n "$_tpe_checkout" ]; then
        _tpe_want_set="$(_tpe_checkout_manifest "$_tpe_checkout")" || _tpe_want_set=""
        if [ -n "$_tpe_want_set" ]; then
            TILLANDSIAS_PROJECT_ENGINE_EXPECTED="$(_tpe_version "$_tpe_want_set")"
        fi
    fi

    # ── the verdict + the two set differences ─────────────────────────────
    if [ "$TILLANDSIAS_PROJECT_ENGINE_STATE" = "ready" ] && [ -n "$_tpe_want_set" ]; then
        _tpe_missing=""
        for _tpe_t in $_tpe_want_set; do
            if ! _tpe_has "$_tpe_t" "$_tpe_now_set"; then
                _tpe_missing="${_tpe_missing}${_tpe_t}
"
            fi
        done
        _tpe_extra=""
        for _tpe_t in $_tpe_now_set; do
            if ! _tpe_has "$_tpe_t" "$_tpe_want_set"; then
                _tpe_extra="${_tpe_extra}${_tpe_t}
"
            fi
        done
        TILLANDSIAS_PROJECT_ENGINE_MISSING="$(printf '%s' "$_tpe_missing" | _tpe_join -)" || TILLANDSIAS_PROJECT_ENGINE_MISSING="-"
        TILLANDSIAS_PROJECT_ENGINE_ONLY="$(printf '%s' "$_tpe_extra" | _tpe_join -)" || TILLANDSIAS_PROJECT_ENGINE_ONLY="-"
        if [ "$TILLANDSIAS_PROJECT_ENGINE_MISSING" != "-" ] \
            || [ "$TILLANDSIAS_PROJECT_ENGINE_ONLY" != "-" ]; then
            TILLANDSIAS_PROJECT_ENGINE_STATE="skewed"
        fi
    fi

    _tillandsias_project_engine_emit
    return 0
}

_tillandsias_project_engine_emit() {
    TILLANDSIAS_PROJECT_ENGINE_LINE="project_engine: state=${TILLANDSIAS_PROJECT_ENGINE_STATE} baked=${TILLANDSIAS_PROJECT_ENGINE_BAKED} expected=${TILLANDSIAS_PROJECT_ENGINE_EXPECTED} missing_in_engine=${TILLANDSIAS_PROJECT_ENGINE_MISSING} engine_only=${TILLANDSIAS_PROJECT_ENGINE_ONLY}"
}

# tillandsias_project_engine_advice — the one-sentence action for each verdict.
# Kept beside the vocabulary it explains so a new state cannot be added without
# an action being written for it.
tillandsias_project_engine_advice() {
    case "${1:-ready}" in
        absent)
            printf 'NO GENERIC ANSWER ENGINE: project-info.sh is not installed in this image, so project_answer is unavailable in every lane. Rebuild the forge image.\n'
            ;;
        stale-engine)
            printf 'UNKNOWABLE ENGINE: an engine is installed but predates the embedded capability manifest, so what it can do cannot be determined — treat its answers as suspect and rebuild the forge image from a current checkout.\n'
            ;;
        skewed)
            printf 'IMAGE REBUILD REQUIRED: the baked engine and the mounted checkout carry different answer contracts. The engine is image-baked (order 459), so NO relaunch and NO in-session build heals this — waiting or retrying is futile. Rebuild the forge image from this checkout.\n'
            ;;
        *)
            printf 'No engine skew: the baked engine matches everything the mounted checkout expects (or the checkout carries no expectation to compare against — see expected=).\n'
            ;;
    esac
}

# Run directly (litmus / operator diagnostics) vs sourced (lib-common.sh):
# when this file IS the program, $0 ends in its own basename.
case "${0##*/}" in
    lib-project-engine-capability.sh)
        tillandsias_project_engine_capability "$@"
        printf '%s\n' "$TILLANDSIAS_PROJECT_ENGINE_LINE"
        tillandsias_project_engine_advice "$TILLANDSIAS_PROJECT_ENGINE_STATE"
        ;;
esac
