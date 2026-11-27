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

# tillandsias_project_engine_capability <engine> <checkout>
#
# <engine>   path to the baked engine script (defaults to the image path; may
#            be empty/absent).
# <checkout> the mounted project checkout (may be empty/absent/non-Tillandsias).
#
# Sets TILLANDSIAS_PROJECT_ENGINE_{STATE,BAKED,EXPECTED,MISSING,ONLY} and
# TILLANDSIAS_PROJECT_ENGINE_LINE.
#
# ORDER 2393-j27x (openspec forge-lua-helpers D3.6): the manifest reads, the
# shape filter and the two set differences are lua/project-engine-capability.lua
# on `tillandsias-plan script run --helper` (beside this file in a checkout,
# /usr/local/lib/tillandsias/lua/ in the image), where they were sixteen
# processes of awk | sort, sed | sed and tr | sed (measured in the forge image).
# The four states are the helper's CLOSED vocabulary. Without the runner or the
# module the state is `unknown` with probe=no-plan-binary on the line, the same
# shape lib-common.sh renders for a missing probe (probe=helper-missing): an
# absent probe never reports a verdict, and there is no second implementation.
tillandsias_project_engine_capability() {
    _tpe_bin="${1:-$TILLANDSIAS_PROJECT_ENGINE_DEFAULT}"
    _tpe_checkout="${2:-}"
    TILLANDSIAS_PROJECT_ENGINE_STATE="unknown"
    TILLANDSIAS_PROJECT_ENGINE_BAKED="-"
    TILLANDSIAS_PROJECT_ENGINE_EXPECTED="-"
    TILLANDSIAS_PROJECT_ENGINE_MISSING="-"
    TILLANDSIAS_PROJECT_ENGINE_ONLY="-"
    TILLANDSIAS_PROJECT_ENGINE_PROBE="no-plan-binary"
    _tpe_run="${TILLANDSIAS_PLAN_BIN:-tillandsias-plan}"
    _tpe_lua=""
    for _tpe_c in "${BASH_SOURCE:+${BASH_SOURCE%/*}/lua/project-engine-capability.lua}" \
                  "${0%/*}/lua/project-engine-capability.lua" \
                  /usr/local/lib/tillandsias/lua/project-engine-capability.lua; do
        if [ -n "$_tpe_c" ] && [ -r "$_tpe_c" ]; then _tpe_lua="$_tpe_c"; break; fi
    done
    _tpe_vals=""
    if [ -n "$_tpe_lua" ] && command -v "$_tpe_run" >/dev/null 2>&1; then
        _tpe_vals="$("$_tpe_run" script run --helper "$_tpe_lua" -- "$_tpe_bin" "$_tpe_checkout" 2>/dev/null)" || _tpe_vals=""
    fi
    if [ -n "$_tpe_vals" ]; then
        { IFS= read -r _tpe_s; IFS= read -r _tpe_b; IFS= read -r _tpe_e; IFS= read -r _tpe_m; IFS= read -r _tpe_o; } <<_TPE_EOF
$_tpe_vals
_TPE_EOF
        case "$_tpe_s" in
            absent|stale-engine|ready|skewed)
                TILLANDSIAS_PROJECT_ENGINE_STATE="$_tpe_s"
                TILLANDSIAS_PROJECT_ENGINE_BAKED="${_tpe_b:--}"
                TILLANDSIAS_PROJECT_ENGINE_EXPECTED="${_tpe_e:--}"
                TILLANDSIAS_PROJECT_ENGINE_MISSING="${_tpe_m:--}"
                TILLANDSIAS_PROJECT_ENGINE_ONLY="${_tpe_o:--}"
                TILLANDSIAS_PROJECT_ENGINE_PROBE="" ;;
            *) TILLANDSIAS_PROJECT_ENGINE_PROBE="helper-out-of-grammar" ;;
        esac
    fi

    _tillandsias_project_engine_emit
    return 0
}

_tillandsias_project_engine_emit() {
    TILLANDSIAS_PROJECT_ENGINE_LINE="project_engine: state=${TILLANDSIAS_PROJECT_ENGINE_STATE} baked=${TILLANDSIAS_PROJECT_ENGINE_BAKED} expected=${TILLANDSIAS_PROJECT_ENGINE_EXPECTED} missing_in_engine=${TILLANDSIAS_PROJECT_ENGINE_MISSING} engine_only=${TILLANDSIAS_PROJECT_ENGINE_ONLY}"${TILLANDSIAS_PROJECT_ENGINE_PROBE:+ probe=${TILLANDSIAS_PROJECT_ENGINE_PROBE}}
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
        unknown)
            printf 'UNKNOWN ENGINE STATE: the capability probe could not run (probe=%s), so whether the baked engine matches this checkout is not known — this is not a no-skew verdict.\n' "${TILLANDSIAS_PROJECT_ENGINE_PROBE:-unknown}"
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
