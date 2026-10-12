#!/bin/sh
# @trace spec:inference-container
# order 521 — engine-payload-download-integrity (the INSTALLED half)
#
# What the inference container may EXECUTE from its engine cache.
#
# WHY A SEPARATE FILE: same discipline as preload-policy.sh / engine-tuning.sh —
# the rules must be FALSIFIABLE without booting a container. POSIX sh, no side
# effects when sourced (functions only), so entrypoint.sh can `.` it while
# litmus:inference-engine-payload-and-tuning runs it standalone against a
# scratch cache with planted, stale and tampered executables. No python.
#
# WHAT IS ALREADY COVERED ELSEWHERE: the DOWNLOAD is pinned and verified in
# entrypoint.sh since 1118-d3b6 (OLLAMA_VERSION + per-arch OLLAMA_SHA256,
# checked before a single file is extracted, fail closed). That digest is a PIN:
# it was read from the GitHub release API when someone bumped the version
# (trust on first fetch, at bump time). It is NOT a signature and NOT an
# independent attestation — it proves the bytes are the ones the bumper saw.
#
# WHAT THIS FILE ADDS. The engine lives on the writable model-cache volume and
# survives the container. Before 521 the only record was `.engine-set` holding
# the BACKEND SET, so the entrypoint executed whatever sat there as long as the
# set matched: an engine left by an older image (never verified, or a different
# version), a version bump that never reinstalled, or an executable swapped on
# the cache after install. Now the manifest records:
#
#   line 1      <set> <version> sha256:<payload digest>   (the ENGINE ID)
#   line 2..n   sha256:<hex> <path relative to the tools root>
#
# for each EXECUTABLE the engine runs — bin `ollama/ollama` and
# `lib/ollama/llama-server` — hashed at install time from files just extracted
# out of the verified payload, and re-hashed at every start (measured on
# lenovinha 2026-10-11: 40 MB ollama + 15 KB llama-server, 0.02 s warm).
# OUT OF SCOPE, deliberately: the ~850 MB of shared libraries under lib/ollama
# (CUDA/ggml .so files). Hashing them is seconds per start; they are loaded by
# the checked executables, so a swapped .so is NOT detected by this file.
# Also out of scope: a writer that can rewrite the manifest AND the executables
# together — the manifest lives on the same volume; this is integrity against
# drift and accidental/partial tampering, not against a cache-volume owner.
#
# VERDICTS (one token on stdout, always exit 0 from the standalone runner):
#   ok                                      recorded id == wanted id, executables match
#   stale:<recorded id>                     a fully recorded, matching engine of a
#                                           DIFFERENT id (e.g. reinstall after a bump
#                                           failed) — servable, reported loudly
#   engine-integrity-refused:<why>          never execute it. <why> is one of
#       no-engine                           nothing installed
#       unrecorded-engine                   no manifest, or a pre-521 manifest
#                                           (set only), or no executable rows
#       executable-missing:<path>           a recorded executable is gone
#       executable-digest-mismatch:<path>   an executable changed since install
#       no-verifier                         sha256sum absent — refuse, never trust
#
# STANDALONE (litmus):
#   sh engine-integrity.sh id <set> <version> <sha256>
#   sh engine-integrity.sh record <toolsroot> <manifest> <engine-id>
#   sh engine-integrity.sh check <toolsroot> <manifest> <wanted-engine-id>

TILLANDSIAS_ENGINE_EXECUTABLES="ollama/ollama lib/ollama/llama-server"

tillandsias_engine_id() { # <set> <version> <sha256>
    printf '%s %s sha256:%s\n' "$1" "$2" "$3"
}

_tillandsias_engine_sha() { # <file> -> hex on stdout, rc 1 when unreadable
    _tes_out="$(sha256sum "$1" 2>/dev/null)" || return 1
    printf '%s\n' "${_tes_out%% *}"
}

# Write the manifest for an engine just extracted from a VERIFIED payload.
# rc 0 written; rc 1 when an executable is missing or cannot be hashed.
tillandsias_engine_record() { # <toolsroot> <manifest> <engine-id>
    command -v sha256sum >/dev/null 2>&1 || return 1
    _ter_body="$3"
    for _ter_rel in $TILLANDSIAS_ENGINE_EXECUTABLES; do
        [ -f "$1/$_ter_rel" ] || return 1
        _ter_sha="$(_tillandsias_engine_sha "$1/$_ter_rel")" || return 1
        _ter_body="$_ter_body
sha256:$_ter_sha $_ter_rel"
    done
    printf '%s\n' "$_ter_body" > "$2"
}

# One verdict token on stdout (see header). Never executes anything it checks.
tillandsias_engine_check() { # <toolsroot> <manifest> <wanted-engine-id>
    if [ ! -f "$1/ollama/ollama" ] && [ ! -f "$2" ]; then
        echo "engine-integrity-refused:no-engine"; return 0
    fi
    if ! command -v sha256sum >/dev/null 2>&1; then
        echo "engine-integrity-refused:no-verifier"; return 0
    fi
    _tec_id="$(sed -n '1p' "$2" 2>/dev/null)"
    case "$_tec_id" in
        *" sha256:"*) ;;
        *) echo "engine-integrity-refused:unrecorded-engine"; return 0 ;;
    esac
    _tec_rows=0
    for _tec_rel in $TILLANDSIAS_ENGINE_EXECUTABLES; do
        _tec_want="$(sed -n "s|^sha256:\([0-9a-f]\{64\}\) $_tec_rel\$|\1|p" "$2" 2>/dev/null)"
        if [ -z "$_tec_want" ]; then
            echo "engine-integrity-refused:unrecorded-engine"; return 0
        fi
        _tec_rows=$((_tec_rows + 1))
        if [ ! -f "$1/$_tec_rel" ]; then
            echo "engine-integrity-refused:executable-missing:$_tec_rel"; return 0
        fi
        _tec_got="$(_tillandsias_engine_sha "$1/$_tec_rel")" || {
            echo "engine-integrity-refused:executable-missing:$_tec_rel"; return 0
        }
        if [ "$_tec_got" != "$_tec_want" ]; then
            echo "engine-integrity-refused:executable-digest-mismatch:$_tec_rel"; return 0
        fi
    done
    if [ "$_tec_id" = "$3" ]; then
        echo "ok"
    else
        echo "stale:$_tec_id"
    fi
}

case "${0##*/}" in
    engine-integrity.sh | tillandsias-engine-integrity.sh)
        _te_verb="${1:-}"
        [ "$#" -gt 0 ] && shift
        case "$_te_verb" in
            id) tillandsias_engine_id "$@" ;;
            record) tillandsias_engine_record "$@" && echo "recorded" || echo "record-failed" ;;
            check) tillandsias_engine_check "$@" ;;
            *) echo "usage: engine-integrity.sh id|record|check ..." ;;
        esac
        exit 0
        ;;
esac
