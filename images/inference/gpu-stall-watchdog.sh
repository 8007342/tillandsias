#!/bin/sh
# @trace spec:inference-container, order:1648-gy9z, order:793-a8e7
#
# gpu-stall-watchdog.sh — a GPU request on the WSL2 Vulkan opt-in lane that
# stops making progress is ended and its model moved to the CPU, instead of
# hanging an unattended host (order 793-a8e7 S4).
#
# WHY. 793-a8e7 measured a cold GPU load of qwen2.5:3b that stalled at 40% of
# prompt processing for more than 9 minutes with no error. A time-boxed repro
# on yolanda 2026-10-12 (ollama v0.34.0, Dozen over /dev/dxg, 8 cold loads at
# 2k and 4k prompt tokens) did NOT reproduce it: not reproduced in 8 tries. So
# the hang is real but intermittent, and the defence has to be a watchdog.
# OLLAMA_LOAD_TIMEOUT (set by the launcher on this lane) covers a stalled LOAD;
# this covers a stall AFTER the load, which ollama has no deadline for.
#
# HOW. ollama runs each loaded model in a llama-server runner, whose /slots
# endpoint reports, per slot, `is_processing` and `n_prompt_tokens_processed`
# (verified live on yolanda: `"is_processing":true ... "n_prompt_tokens":1024,
# "n_prompt_tokens_processed":512` mid-request). Each tick reads every runner's
# /slots. A runner that is processing with no change in its progress for
# TGW_STALL_S seconds is stalled: it is killed (ollama then fails the request
# with an error instead of hanging), and its model is QUARANTINED to the CPU
# with the decode-floor pin (num_gpu 0), recorded in the same record, so the
# retry and every later request run on the CPU until the next start, and an
# opt-out restores it like any other pin (decode-floor-pin.sh).
#
# FAIL SAFE, NEVER BLIND. If a runner's /slots cannot be fetched or does not
# carry the fields above, or the stalled runner cannot be attributed to exactly
# one GPU-resident model, the watchdog logs `watchdog blind: <why>` (once per
# runner and reason) and DOES NOTHING. It never kills a runner it cannot read.
#
# PINNED GRAMMAR (one line per event, prefixed by the entrypoint):
#   gpu-stall: model=<m> runner=<pid> stalled=<s>s progress=<n>; killed, quarantined to the CPU until the next start
#   watchdog blind: runner=<pid> <reason>
#
# Seams (the fixture's; production leaves them unset): TGW_PROC_ROOT (default
# /proc), TGW_NOW (epoch seconds), TGW_KILL (default kill). `curl` and `ollama`
# resolve from PATH. Requires decode-floor-pin.sh to be sourced first.

_tgw_now() { echo "${TGW_NOW:-$(date +%s)}"; }

# "pid port" for every llama-server runner.
_tgw_runners() {
    for _tgw_p in "${TGW_PROC_ROOT:-/proc}"/[0-9]*; do
        [ -r "$_tgw_p/cmdline" ] || continue
        _tgw_c="$(tr '\0' ' ' < "$_tgw_p/cmdline" 2>/dev/null)"
        case "$_tgw_c" in *llama-server*--port*) ;; *) continue ;; esac
        _tgw_port="$(printf '%s\n' "$_tgw_c" | awk '{ for (i = 1; i < NF; i++) if ($i == "--port") { print $(i + 1); exit } }')"
        case "$_tgw_port" in '' | *[!0-9]*) continue ;; esac
        echo "${_tgw_p##*/} $_tgw_port"
    done
}

# "<is_processing> <progress>" from a /slots body, or nothing when the shape is
# not the one this watchdog was verified against.
_tgw_progress() {
    printf '%s' "$1" | awk '
        {
            s = s $0
        }
        END {
            proc = ""; n = 0; seen = 0
            while (match(s, /"is_processing":(true|false)/)) {
                v = substr(s, RSTART + 16, RLENGTH - 16); if (v == "true") proc = "true"; else if (proc == "") proc = "false"
                s2 = substr(s, RSTART + RLENGTH)
                if (match(s2, /"n_prompt_tokens_processed":[0-9]+/)) { n += substr(s2, RSTART + 28, RLENGTH - 28); seen++ }
                if (match(s2, /"n_decoded":[0-9]+/)) n += substr(s2, RSTART + 12, RLENGTH - 12)
                s = s2
            }
            if (proc != "" && seen > 0) print proc, n
        }'
}

# The one model resident on the GPU, or nothing when there is not exactly one.
_tgw_gpu_model() {
    curl -s --max-time 3 http://127.0.0.1:11434/api/ps 2>/dev/null | awk '
        { s = s $0 }
        END {
            n = 0
            while (match(s, /"name":"[^"]*"/)) {
                name = substr(s, RSTART + 8, RLENGTH - 9); s = substr(s, RSTART + RLENGTH)
                if (match(s, /"size_vram":[0-9]+/) && substr(s, RSTART + 12, RLENGTH - 12) + 0 > 0) { n++; m = name }
            }
            if (n == 1) print m
        }'
}

_tgw_blind() { # state pid reason
    _tgw_bk="$1/blind-$2"
    [ "$(cat "$_tgw_bk" 2>/dev/null)" = "$3" ] && return 0
    printf '%s\n' "$3" > "$_tgw_bk"
    echo "watchdog blind: runner=$2 $3"
}

# One pass over every runner. $1 state dir, $2 the decode-floor pin record.
tillandsias_gpu_stall_tick() {
    _tgw_state="$1" _tgw_record="$2"
    _tgw_stall="${TGW_STALL_S:-120}"
    mkdir -p "$_tgw_state"
    _tgw_runners | while read -r _tgw_pid _tgw_port; do
        _tgw_body="$(curl -s --max-time 3 "http://127.0.0.1:$_tgw_port/slots" 2>/dev/null)" || _tgw_body=""
        if [ -z "$_tgw_body" ]; then
            _tgw_blind "$_tgw_state" "$_tgw_pid" "slots-unreachable:port=$_tgw_port"
            continue
        fi
        _tgw_pg="$(_tgw_progress "$_tgw_body")"
        if [ -z "$_tgw_pg" ]; then
            _tgw_blind "$_tgw_state" "$_tgw_pid" "slots-unrecognised:port=$_tgw_port"
            continue
        fi
        rm -f "$_tgw_state/blind-$_tgw_pid"
        set -- $_tgw_pg
        if [ "$1" != "true" ]; then
            rm -f "$_tgw_state/seen-$_tgw_pid"
            continue
        fi
        _tgw_now_s="$(_tgw_now)"
        _tgw_last="" _tgw_since=""
        [ -f "$_tgw_state/seen-$_tgw_pid" ] && read -r _tgw_last _tgw_since < "$_tgw_state/seen-$_tgw_pid"
        if [ "$_tgw_last" != "$2" ]; then
            echo "$2 $_tgw_now_s" > "$_tgw_state/seen-$_tgw_pid"
            continue
        fi
        _tgw_for=$((_tgw_now_s - _tgw_since))
        [ "$_tgw_for" -ge "$_tgw_stall" ] || continue
        _tgw_model="$(_tgw_gpu_model)"
        if [ -z "$_tgw_model" ]; then
            _tgw_blind "$_tgw_state" "$_tgw_pid" "stalled-${_tgw_for}s-but-no-single-gpu-model"
            continue
        fi
        ${TGW_KILL:-kill} -TERM "$_tgw_pid" 2>/dev/null
        rm -f "$_tgw_state/seen-$_tgw_pid"
        if _tdf_pin "$_tgw_model"; then
            grep -qxF "$_tgw_model" "$_tgw_record" 2>/dev/null || printf '%s\n' "$_tgw_model" >> "$_tgw_record"
        fi
        echo "gpu-stall: model=$_tgw_model runner=$_tgw_pid stalled=${_tgw_for}s progress=$2; killed, quarantined to the CPU until the next start"
    done
    return 0
}

# The loop the entrypoint backgrounds on the opt-in lane.
tillandsias_gpu_stall_watchdog() {
    while :; do
        tillandsias_gpu_stall_tick "$1" "$2"
        sleep "${TGW_TICK_S:-10}"
    done
}
