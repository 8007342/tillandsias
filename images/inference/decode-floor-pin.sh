#!/bin/sh
# @trace spec:inference-container, order:793-a8e7
#
# decode-floor-pin.sh — keep small models' decode on the CPU on the WSL2 Vulkan
# opt-in lane (order 793-a8e7 S3), and leave NOTHING behind when the opt-in is
# turned off.
#
# WHY. The opt-in lane (TILLANDSIAS_INFERENCE_TIER=gpu-vulkan) puts every model
# on the iGPU by default, and on this stack that is a regression for small
# models: qwen2.5:0.5b decode measured 1.23x SLOWER on the iGPU and nomic-embed
# 1.16x slower, while qwen2.5:3b decode gained 1.37x. ollama cannot split a
# model by phase: MEASURED on yolanda 2026-10-12 (ollama v0.34.0, Dozen over
# /dev/dxg), num_gpu=0 loads the model with CPU buffers only and prefill drops
# from ~1245 to ~395 t/s, so there is no "prefill on GPU, decode on CPU" to
# select. What CAN be chosen is per model: below the floor a model is pinned
# all-CPU (num_gpu 0); at or above it, it keeps the GPU.
#
# THE FLOOR. TILLANDSIAS_DECODE_FLOOR_B, passed by the launcher: the host's
# measured decode crossover (793-qc6q) when there is one, `all` when the host
# measured and the CPU won at every size, else 3 — PROVISIONAL, the smallest
# size measured to gain (coordinator ruling 2026-10-12), until a host measures.
#
# HOW. ollama has no per-model server setting, only a per-request option or a
# Modelfile PARAMETER. A model below the floor is re-created under its OWN name
# FROM itself with `PARAMETER num_gpu 0`: the layers are reused (no download),
# only the default changes, and a request can still override it.
#
# NO DRIFT AFTER OPT-OUT. Every model this script pins is recorded, one name per
# line, in the state file (beside the engine, in the model cache). On any other
# tier the recorded models are restored, by re-creating each from its own
# `ollama show --modelfile` minus the num_gpu line, and the record is removed.
# A model that already carried num_gpu when first seen is the operator's, so it
# is never pinned, never recorded, and never restored.
#
# LIMIT. A model pulled while the container runs is pinned at the next start.
#
# PINNED GRAMMAR — exactly one line, always returns 0:
#   decode-floor: tier=<tier> floor_b=<n|all|-> source=<s> pinned=<n> kept=<n> restored=<n> skipped=<n>
#
# Usage (sourced by the entrypoint once `ollama serve` answers):
#   . tillandsias-decode-floor-pin.sh && tillandsias_decode_floor_reconcile <state-file>
# `ollama` is resolved from PATH, which is the seam the fixture uses.

# Parameter count in billions from `ollama show <model>` ("parameters 494.03M").
# Empty when it cannot be read: such a model is skipped, never guessed.
_tdf_params_b() {
    ollama show "$1" 2>/dev/null | awk '
        $1 == "parameters" {
            v = $2; u = substr(v, length(v)); n = substr(v, 1, length(v) - 1)
            if (n !~ /^[0-9.]+$/) exit
            if (u == "B") print n
            else if (u == "M") print n / 1000
            else if (u == "K") print n / 1000000
            else if (u == "T") print n * 1000
            exit
        }'
}

_tdf_has_num_gpu() {
    ollama show --parameters "$1" 2>/dev/null | awk '$1 == "num_gpu" { f = 1 } END { exit !f }'
}

_tdf_below_floor() { # size floor
    [ "$2" = "all" ] && return 0
    awk -v s="$1" -v f="$2" 'BEGIN { exit !(s + 0 < f + 0) }'
}

_tdf_pin() {
    _tdf_mf="$(mktemp)" || return 1
    printf 'FROM %s\nPARAMETER num_gpu 0\n' "$1" > "$_tdf_mf"
    ollama create "$1" -f "$_tdf_mf" >/dev/null 2>&1
    _tdf_rc=$?
    rm -f "$_tdf_mf"
    return $_tdf_rc
}

_tdf_restore() {
    _tdf_mf="$(mktemp)" || return 1
    ollama show --modelfile "$1" 2>/dev/null | grep -v '^PARAMETER num_gpu ' > "$_tdf_mf"
    if grep -q '^FROM ' "$_tdf_mf"; then
        ollama create "$1" -f "$_tdf_mf" >/dev/null 2>&1
        _tdf_rc=$?
    else
        _tdf_rc=1
    fi
    rm -f "$_tdf_mf"
    return $_tdf_rc
}

tillandsias_decode_floor_reconcile() {
    _tdf_state="$1"
    _tdf_tier="${TILLANDSIAS_INFERENCE_TIER:-cpu}"
    _tdf_pinned=0 _tdf_kept=0 _tdf_restored=0 _tdf_skipped=0
    _tdf_floor="-" _tdf_source="-"

    if [ "$_tdf_tier" != "gpu-vulkan" ]; then
        # OPT-IN OFF: undo every pin this script recorded, then forget them.
        if [ -s "$_tdf_state" ]; then
            while IFS= read -r _tdf_m; do
                [ -n "$_tdf_m" ] || continue
                if _tdf_restore "$_tdf_m"; then
                    _tdf_restored=$((_tdf_restored + 1))
                else
                    # Gone, or unreadable: nothing of ours left to undo there.
                    _tdf_skipped=$((_tdf_skipped + 1))
                fi
            done < "$_tdf_state"
        fi
        rm -f "$_tdf_state"
    else
        _tdf_floor="${TILLANDSIAS_DECODE_FLOOR_B:-}"
        _tdf_source="${TILLANDSIAS_DECODE_FLOOR_SOURCE:-launcher}"
        case "$_tdf_floor" in
            all) ;;
            '' | *[!0-9.]* | .) _tdf_floor=3 _tdf_source=default-provisional ;;
        esac
        _tdf_next="$(mktemp)" || return 0
        for _tdf_m in $(ollama list 2>/dev/null | awk 'NR > 1 && $1 != "" { print $1 }'); do
            _tdf_ours=0
            [ -f "$_tdf_state" ] && grep -qxF "$_tdf_m" "$_tdf_state" && _tdf_ours=1
            _tdf_size="$(_tdf_params_b "$_tdf_m")"
            if [ -z "$_tdf_size" ]; then
                # Unknown size: never guessed. Keep the record so opt-out can
                # still restore a pin made earlier.
                [ "$_tdf_ours" = 1 ] && printf '%s\n' "$_tdf_m" >> "$_tdf_next"
                _tdf_skipped=$((_tdf_skipped + 1))
            elif _tdf_below_floor "$_tdf_size" "$_tdf_floor"; then
                if [ "$_tdf_ours" = 1 ]; then
                    _tdf_has_num_gpu "$_tdf_m" || _tdf_pin "$_tdf_m"
                    printf '%s\n' "$_tdf_m" >> "$_tdf_next"
                    _tdf_kept=$((_tdf_kept + 1))
                elif _tdf_has_num_gpu "$_tdf_m"; then
                    _tdf_skipped=$((_tdf_skipped + 1)) # the operator's own setting
                elif _tdf_pin "$_tdf_m"; then
                    printf '%s\n' "$_tdf_m" >> "$_tdf_next"
                    _tdf_pinned=$((_tdf_pinned + 1))
                else
                    _tdf_skipped=$((_tdf_skipped + 1))
                fi
            elif [ "$_tdf_ours" = 1 ]; then
                # At or above a floor that moved up past it: give the GPU back.
                if _tdf_restore "$_tdf_m"; then
                    _tdf_restored=$((_tdf_restored + 1))
                else
                    printf '%s\n' "$_tdf_m" >> "$_tdf_next"
                    _tdf_skipped=$((_tdf_skipped + 1))
                fi
            fi
        done
        if [ -s "$_tdf_next" ]; then
            mv "$_tdf_next" "$_tdf_state"
        else
            rm -f "$_tdf_next" "$_tdf_state"
        fi
    fi
    echo "decode-floor: tier=$_tdf_tier floor_b=$_tdf_floor source=$_tdf_source pinned=$_tdf_pinned kept=$_tdf_kept restored=$_tdf_restored skipped=$_tdf_skipped"
    return 0
}
