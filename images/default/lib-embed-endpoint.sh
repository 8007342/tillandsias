#!/usr/bin/env bash
# lib-embed-endpoint.sh — THE derivation of TILLANDSIAS_EMBED_ENDPOINT.
# @trace order:967-xq5e
# @trace order:919-vvyv (the forge fallback this consolidates)
# @trace order:712-r5x8 (the probe-do-not-assume invariant)
#
# WHY THIS FILE EXISTS, and the measurement that earned it.
#
# scripts/spec-index-ensure.sh did no derivation at all. It read
# `TILLANDSIAS_EMBED_ENDPOINT` and refused when absent:
#
#     EMBED_EP="${TILLANDSIAS_EMBED_ENDPOINT:-}"
#     [ -n "$EMBED_EP" ] || { echo "skip:spec-index:no-embed-endpoint"; exit 0; }
#
# Every site that derived and exported that variable lived in the FORGE lane
# (lib-common.sh, config-overlay/mcp/lib-dev-env.sh). Nothing on the bare-metal
# host lane derived it. A git hook inherits the environment of whatever ran
# `git commit`, so on a host the variable arrived only by luck.
#
# MEASURED 2026-09-02, two hosts, same script, opposite outcomes:
#   macuahuitl  32 consecutive `skip:spec-index:no-embed-endpoint`, zero
#               non-skip entries ever. Index 128 commits stale. A healthy
#               endpoint on localhost:11434 the whole time.
#   yoga        three successful builds — because ONE line in a git-ignored
#               `.claude/settings.local.json` exported the variable into the
#               agent session that ran the commits.
#
# So the host lane had NEVER refreshed an index anywhere; one machine carried a
# private workaround. Supplying the variable by hand on the failing host took
# its index from 128 commits stale to exactly HEAD in 41 seconds and converted
# a groundtruth citation the harness classed as FABRICATED into a pass.
#
# THE SKIP WAS NOT SILENT AND THAT IS THE LESSON. It was logged, loudly, 32
# times. `skip:spec-index:no-embed-endpoint` reads as CONFIGURATION rather than
# BREAKAGE: it names a missing variable and names nothing that would supply it —
# no candidate, no remedy, empty stderr — so nobody had reason to open the log.
# A correct, honest, well-logged refusal can still be unreadable as a problem.
# That is why `resolve_embed_endpoint` reports what it TRIED (below) instead of
# only what it lacked.
#
# WHY ONE FILE RATHER THAN A HOST-SIDE COPY. A second derivation is the drift:
# the same week produced a container name hardcoded in Rust while the shell that
# creates it used another (967-6ax6), and this file's own consolidation folds
# two forge blocks that had already diverged. `images/default/` is the one
# directory present BOTH inside the image and in a host checkout, and
# lib-common.sh is sourced at launch possibly before the project clone — so a
# helper under scripts/ could not serve the image lane. This location is what
# lets both lanes reach ONE implementation.

# Derive and export TILLANDSIAS_EMBED_ENDPOINT if it is not already set.
#
# Contract:
#   - An explicit TILLANDSIAS_EMBED_ENDPOINT is NEVER probed and NEVER
#     overridden. The caller has spoken.
#   - Otherwise a candidate is derived, PROBED, and exported only if it answers.
#   - PROBE, DO NOT ASSUME (712-r5x8): a host or forge with no inference service
#     must wire nothing and keep spec_answer's typed refusal. An endpoint
#     exported on faith replaces an honest `no embedding endpoint` with a
#     misleading `the endpoint did not answer`.
#   - Returns 0 when the variable is set on exit, 1 when nothing answered.
#     The verdict is assigned to TILLANDSIAS_EMBED_ENDPOINT_VERDICT *and*
#     printed, so a refusal says what to fix rather than only what is missing.
#
#     CALL IT DIRECTLY, NEVER IN A COMMAND SUBSTITUTION.
#     `v="$(resolve_embed_endpoint)"` runs the function in a SUBSHELL, so its
#     `export` dies with that subshell and the caller sees the variable still
#     unset while the verdict reads `derived` — a verdict that contradicts the
#     state it describes. That exact mistake was made writing this fix and was
#     caught by scripts/test-embed-endpoint-derivation.sh on its first run. The
#     verdict GLOBAL exists precisely so no caller ever needs the substitution.
resolve_embed_endpoint() {
    if [ -n "${TILLANDSIAS_EMBED_ENDPOINT:-}" ]; then
        TILLANDSIAS_EMBED_ENDPOINT_VERDICT="ok:embed-endpoint:explicit:$TILLANDSIAS_EMBED_ENDPOINT"

        printf 'ok:embed-endpoint:explicit:%s\n' "$TILLANDSIAS_EMBED_ENDPOINT"
        return 0
    fi

    local _ree_candidate
    if [ -n "${OLLAMA_HOST:-}" ]; then
        # One operator's way of spelling the endpoint, not the fleet's.
        _ree_candidate="${OLLAMA_HOST%/}"
    else
        # TILLANDSIAS_INFERENCE_ENDPOINT is the ROOT url by convention
        # (lib-experts-probe.sh: "root url, no /v1"). The default differs by
        # lane: `inference` is the enclave service name and resolves only
        # inside it, so a host falls back to the loopback the dev inference
        # container publishes (dev-inference-ensure.sh).
        if [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ]; then
            _ree_candidate="${TILLANDSIAS_INFERENCE_ENDPOINT:-http://inference:11434}"
        else
            _ree_candidate="${TILLANDSIAS_INFERENCE_ENDPOINT:-http://127.0.0.1:11434}"
        fi
        _ree_candidate="${_ree_candidate%/}"
    fi

    # Add the /v1 base the embeddings path needs — unless it is already spelled
    # that way, in which case appending again would 404 on /v1/v1/embeddings.
    case "$_ree_candidate" in
        */v1) : ;;
        *) _ree_candidate="$_ree_candidate/v1" ;;
    esac

    if ! command -v curl >/dev/null 2>&1; then
        TILLANDSIAS_EMBED_ENDPOINT_VERDICT="skip:embed-endpoint:no-curl:$_ree_candidate"
        printf '%s\n' "$TILLANDSIAS_EMBED_ENDPOINT_VERDICT"
        return 1
    fi
    # Same cheap bounded OpenAI-shape liveness probe the capability line uses
    # (712-r5x8): GET <base>/models, 3s ceiling. Refused connections and DNS
    # misses return immediately, so a lane without inference pays nothing.
    if curl -fsS -m 3 -o /dev/null "$_ree_candidate/models" 2>/dev/null; then
        export TILLANDSIAS_EMBED_ENDPOINT="$_ree_candidate"
        TILLANDSIAS_EMBED_ENDPOINT_VERDICT="ok:embed-endpoint:derived:$_ree_candidate"
        printf '%s\n' "$TILLANDSIAS_EMBED_ENDPOINT_VERDICT"
        return 0
    fi

    TILLANDSIAS_EMBED_ENDPOINT_VERDICT="unreachable:embed-endpoint:$_ree_candidate"
    printf '%s\n' "$TILLANDSIAS_EMBED_ENDPOINT_VERDICT"
    return 1
}
