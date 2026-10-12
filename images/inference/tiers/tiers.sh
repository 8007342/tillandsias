#!/bin/sh
# @trace spec:inference-engine-slots (SLOT-7, req-id e52fc9d8), order 482d
#
# Resolver for the shared T0-T5 tier table (tier-table.tsv) and its engine
# adapters (models.<engine>.tsv). POSIX sh, functions only, no side effects
# when sourced; runnable standalone so litmus:inference-tier-table-migration
# can exercise it without a container. No python, no eval.
#
#   tillandsias_tier_classify <vram_gb> <ram_gb>   -> T1..T5 (never T0)
#   tillandsias_tier_models <tier>                 -> logical ids, space-separated:
#                                                     the tier's own plus every lower row's
#   tillandsias_tier_artifact <engine> <logical>   -> the engine's artifact
#                                                     (ollama: tag; llama-server: repo:quant);
#                                                     rc 1 and "unmapped:<engine>:<id>" when absent
#
# TILLANDSIAS_TIERS_DIR names the directory holding the .tsv files; it
# defaults to the directory this file sits in when run standalone, and to the
# image path when sourced by the entrypoint.

_tillandsias_tiers_dir_given="${TILLANDSIAS_TIERS_DIR:-}"
TILLANDSIAS_TIERS_DIR="${TILLANDSIAS_TIERS_DIR:-/usr/local/share/tillandsias/tiers}"

# Rows of a .tsv without comments or blank lines.
_tillandsias_tier_rows() { # <file>
    while IFS= read -r _ttr_line || [ -n "$_ttr_line" ]; do
        case "$_ttr_line" in '' | '#'*) continue ;; esac
        printf '%s\n' "$_ttr_line"
    done < "$1"
}

_tillandsias_tier_ge() { # <value> <floor> — '-' floor never matches
    case "$2" in '' | '-' | *[!0-9]*) return 1 ;; esac
    case "$1" in '' | *[!0-9]*) return 1 ;; esac
    [ "$1" -ge "$2" ]
}

tillandsias_tier_classify() { # <vram_gb> <ram_gb>
    [ -r "$TILLANDSIAS_TIERS_DIR/tier-table.tsv" ] || return 1
    _ttc_out="T1"
    while IFS="$(printf '\t')" read -r _ttc_tier _ttc_vram _ttc_ram _ttc_models; do
        if _tillandsias_tier_ge "$1" "$_ttc_vram" || _tillandsias_tier_ge "$2" "$_ttc_ram"; then
            _ttc_out="$_ttc_tier"
            break
        fi
    done <<EOF
$(_tillandsias_tier_rows "$TILLANDSIAS_TIERS_DIR/tier-table.tsv")
EOF
    printf '%s\n' "$_ttc_out"
}

tillandsias_tier_models() { # <tier>
    _ttm_want="${1#T}"
    case "$_ttm_want" in '' | *[!0-9]*) return 1 ;; esac
    [ -r "$TILLANDSIAS_TIERS_DIR/tier-table.tsv" ] || return 1
    _ttm_out=""
    while IFS="$(printf '\t')" read -r _ttm_tier _ttm_vram _ttm_ram _ttm_models; do
        _ttm_n="${_ttm_tier#T}"
        case "$_ttm_n" in '' | *[!0-9]*) continue ;; esac
        [ "$_ttm_n" -le "$_ttm_want" ] || continue
        [ "$_ttm_models" = "-" ] && continue
        _ttm_out="$_ttm_out $(printf '%s' "$_ttm_models" | tr ',' ' ')"
    done <<EOF
$(_tillandsias_tier_rows "$TILLANDSIAS_TIERS_DIR/tier-table.tsv")
EOF
    # shellcheck disable=SC2086 # deliberate word split to normalise spacing
    set -- $_ttm_out
    printf '%s\n' "$*"
}

tillandsias_tier_artifact() { # <engine> <logical-id>
    _tta_file="$TILLANDSIAS_TIERS_DIR/models.$1.tsv"
    if [ -r "$_tta_file" ]; then
        while IFS="$(printf '\t')" read -r _tta_id _tta_a _tta_b; do
            if [ "$_tta_id" = "$2" ]; then
                if [ -n "$_tta_b" ]; then printf '%s:%s\n' "$_tta_a" "$_tta_b"; else printf '%s\n' "$_tta_a"; fi
                return 0
            fi
        done <<EOF
$(_tillandsias_tier_rows "$_tta_file")
EOF
    fi
    printf 'unmapped:%s:%s\n' "$1" "$2"
    return 1
}

case "${0##*/}" in
    tiers.sh | tillandsias-tiers.sh)
        [ -n "$_tillandsias_tiers_dir_given" ] || TILLANDSIAS_TIERS_DIR="$(cd "$(dirname "$0")" && pwd)"
        _tt_verb="${1:-}"; [ "$#" -gt 0 ] && shift
        case "$_tt_verb" in
            classify) tillandsias_tier_classify "$@" ;;
            models) tillandsias_tier_models "$@" ;;
            artifact) tillandsias_tier_artifact "$@" ;;
            *) echo "usage: tiers.sh classify <vram_gb> <ram_gb> | models <tier> | artifact <engine> <logical-id>"; exit 2 ;;
        esac
        ;;
esac
