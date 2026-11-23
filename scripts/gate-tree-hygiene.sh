#!/usr/bin/env bash
# ORDER 2150-qd38 (priority:build-speed). Tree hygiene for the gate.
#
# Two questions a slow gate could not answer about itself:
#   1. Was the HOST under pressure? `psi <label>` prints one line of Linux
#      PSI (cpu, memory, io avg10/avg60) — the gate logs it at start and end,
#      so a 40-minute gate can be told apart from a 40-minute gate on a host
#      that was swapping. Hosts without /proc/pressure print psi:unavailable.
#   2. Is the CHECKOUT bloated? `scratch` sums untracked-but-not-ignored
#      paths plus the known scratch roots (fixture scratch, agent worktrees),
#      warns above 1 GB, and REFUSES (exit 1) only when the caller opted in
#      with TILLANDSIAS_GATE_SCRATCH_REFUSE=1 — a warning never blocks a land
#      on its own. target/debug is a build cache, not scratch: its size is
#      reported with the prune remedy, never counted toward the refusal.
#
# Cost: ~0.1 s on the floor host (git ls-files + du -sk on a handful of
# roots). Never reads file contents.
#
# Usage:
#   scripts/gate-tree-hygiene.sh psi <label>   -> psi:<label> cpu=.. mem=.. io=..   (exit 0)
#   scripts/gate-tree-hygiene.sh scratch       -> ok:tree-scratch:<mb>MB | warn:tree-scratch:<mb>MB ... | refused:...
# Env:
#   TILLANDSIAS_GATE_SCRATCH_WARN_MB    threshold, default 1024
#   TILLANDSIAS_GATE_SCRATCH_REFUSE=1   turn the warning into exit 1
#   TILLANDSIAS_GATE_DEBUG_WARN_MB      target/debug threshold, default 20480
#   TILLANDSIAS_PSI_ROOT                /proc/pressure override (fixtures)
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "could-not-run:tree-hygiene:not-a-git-repo"; exit 3; }
cd "$ROOT" || exit 3

_psi_field() { # file kind -> "avg10/avg60"
    local line
    line="$(grep "^$2 " "$1" 2>/dev/null)" || return 1
    local a10 a60
    a10="$(printf '%s\n' "$line" | sed -n 's/.*avg10=\([0-9.]*\).*/\1/p')"
    a60="$(printf '%s\n' "$line" | sed -n 's/.*avg60=\([0-9.]*\).*/\1/p')"
    printf '%s/%s' "$a10" "$a60"
}

_psi() {
    local label="${1:-now}" root="${TILLANDSIAS_PSI_ROOT:-/proc/pressure}"
    if [ ! -r "$root/memory" ]; then echo "psi:$label:unavailable"; return 0; fi
    printf 'psi:%s cpu=%s mem=%s mem_full=%s io=%s io_full=%s\n' "$label" \
        "$(_psi_field "$root/cpu" some || echo -)" \
        "$(_psi_field "$root/memory" some || echo -)" \
        "$(_psi_field "$root/memory" full || echo -)" \
        "$(_psi_field "$root/io" some || echo -)" \
        "$(_psi_field "$root/io" full || echo -)"
}

_kb() { du -sk "$@" 2>/dev/null | awk '{s+=$1} END {print s+0}'; }

_scratch() {
    local warn_mb="${TILLANDSIAS_GATE_SCRATCH_WARN_MB:-1024}" dbg_mb="${TILLANDSIAS_GATE_DEBUG_WARN_MB:-20480}"
    local roots=() p
    # --directory collapses an untracked dir to one entry, so du sees a few roots.
    while IFS= read -r p; do [ -n "$p" ] && roots+=("$p"); done \
        < <(git ls-files --others --exclude-standard --directory 2>/dev/null)
    for p in .tillandsias/fixture-scratch .claude/worktrees; do [ -e "$p" ] && roots+=("$p"); done
    local kb=0 top=""
    if [ "${#roots[@]}" -gt 0 ]; then
        kb="$(_kb "${roots[@]}")"
        top="$(du -sk "${roots[@]}" 2>/dev/null | sort -rn | head -3 | awk '{printf "%s%s(%dMB)", (NR>1?" ":""), $2, $1/1024}')"
    fi
    local mb=$((kb / 1024)) rc=0
    if [ "$mb" -gt "$warn_mb" ]; then
        if [ "${TILLANDSIAS_GATE_SCRATCH_REFUSE:-0}" = 1 ]; then
            echo "refused:tree-scratch:${mb}MB>${warn_mb}MB largest: $top"
            echo "  why: TILLANDSIAS_GATE_SCRATCH_REFUSE=1 asked the gate to stop on a checkout carrying this much untracked scratch"
            echo "  remedy: delete the scratch you own (see below), or unset TILLANDSIAS_GATE_SCRATCH_REFUSE to make this a warning"
            rc=1
        else
            echo "warn:tree-scratch:${mb}MB>${warn_mb}MB largest: $top"
        fi
        echo "remedy: inspect with 'git status --short --ignored=no', then delete scratch you own (fixture scratch is safe: rm -rf .tillandsias/fixture-scratch/*)"
    else
        echo "ok:tree-scratch:${mb}MB"
    fi
    if [ -d target/debug ]; then
        local dmb=$(( $(_kb target/debug) / 1024 ))
        if [ "$dmb" -gt "$dbg_mb" ]; then
            echo "warn:target-debug:${dmb}MB>${dbg_mb}MB — build cache, not counted as scratch; prune with: cargo clean --profile dev"
        else
            echo "info:target-debug:${dmb}MB"
        fi
    fi
    return "$rc"
}

case "${1:-}" in
    psi) _psi "${2:-now}" ;;
    scratch) _scratch ;;
    *) echo "usage: $0 psi <label> | scratch" >&2; exit 2 ;;
esac
