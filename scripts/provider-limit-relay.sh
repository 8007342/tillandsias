#!/usr/bin/env bash
# @trace order:1957-msjs, order:1941-rlim
#
# provider-limit-relay.sh — a provider usage limit one host's forge recorded
# holds the forges of every fleet host (1957-msjs).
#
# WHY. The opencode free tier's quota is shared by every fleet host: yoga hit
# it on 2026-11-01 and every host's opencode traffic had to stop by coordinator
# order until 03:00Z the next day. 1941-rlim records the deadline in the
# forge's project cache, which no other host can read, and a forge cannot
# publish it itself (its push is gated on the GitHub token, and fleet messages
# do not cross hosts yet, 1506-7tq4). So the HOST relays it (design approved by
# the coordinator, 2026-11-02):
#
#   on-exit  after a forge exits, read its record and publish it as a NEW plan
#            fragment on the plan-only lane, detached and bounded by the caller;
#            a failed push leaves one deferred line that `retry` (run from the
#            slot's check-fleet-membership.sh todo) pushes later. Never delays
#            the exit: the tray spawns this and does not wait.
#   seed-env at launch, OFFLINE: fold the local plan copy's limit events and
#            print the live ones as the TILLANDSIAS_PROVIDER_LIMIT_SHARED value
#            the forge's lib-provider-limit.sh refuses on, naming the host.
#   retry    push every deferred fragment; drop the ones that reached trunk.
#
# THE EVENT maps 1:1 to a coordinator-queue message (1824-58bm) once that
# queue is live: one flat record whose TTL is the hold.
#   provider-usage-limit provider=<p> retry_after=<utc> retry_after_epoch=<n> recorded_by=<host> recorded=<utc>
#
# VERDICTS (stdout, last line):
#   ok:provider-limit-relay:published:<provider>:<fragment>   pushed to trunk
#   ok:provider-limit-relay:deferred:<provider>:<fragment>    written; the push failed, retried later
#   ok:provider-limit-relay:already-published:<provider>      this deadline is already in the plan
#   ok:provider-limit-relay:nothing-recorded                  the forge recorded no live limit
#   ok:provider-limit-relay:retried:<pushed>/<deferred>
#   refused:provider-limit-relay:usage:<detail>
# seed-env prints only the value (empty when nothing is live) and exits 0.
#
# Environment (the fixture's seams; production uses the defaults):
#   TILLANDSIAS_PROVIDER_LIMIT_PLAN_DIR   plan/index.d of this checkout
#   TILLANDSIAS_PROVIDER_LIMIT_PUSH       pusher, called with one fragment path
#                                         (default scripts/push-plan-fragments-to-trunk.sh)
#   TILLANDSIAS_PROVIDER_LIMIT_STATE      deferred-push state dir
#                                         (default ~/.local/state/tillandsias)
#   TILLANDSIAS_PROVIDER_LIMIT_PUSH_TIMEOUT_S  bound on one push (default 60)
#
# Usage:
#   scripts/provider-limit-relay.sh on-exit (--volume <name> | --record-dir <dir>) [--host <h>]
#   scripts/provider-limit-relay.sh seed-env
#   scripts/provider-limit-relay.sh retry
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAN_DIR="${TILLANDSIAS_PROVIDER_LIMIT_PLAN_DIR:-$ROOT/plan/index.d}"
PUSH="${TILLANDSIAS_PROVIDER_LIMIT_PUSH:-$ROOT/scripts/push-plan-fragments-to-trunk.sh}"
STATE="${TILLANDSIAS_PROVIDER_LIMIT_STATE:-${HOME:-/tmp}/.local/state/tillandsias}"
DEFERRED="$STATE/provider-limit-deferred"
PUSH_TIMEOUT_S="${TILLANDSIAS_PROVIDER_LIMIT_PUSH_TIMEOUT_S:-60}"
# The row these events ride on: 1957-msjs itself.
PACKET="a-provider-usage-limit-deadline-recorded-on-one-host-holds-every-host-of-the-fleet"

_afford() { printf '  why: %s\n  remedy: %s\n' "$1" "$2" >&2; }

_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# _push <fragment> — 0 when the pusher's last line says the fragment is on trunk.
# Bounded by PUSH_TIMEOUT_S without GNU timeout, which macOS hosts lack: the
# pusher runs in the background and is killed at the deadline.
_push() {
    local log pid waited=0 out
    mkdir -p "$STATE" && log="$(mktemp "$STATE/push.XXXXXX")" || return 1
    "$PUSH" "$1" </dev/null >"$log" 2>/dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$PUSH_TIMEOUT_S" ]; then
            kill "$pid" 2>/dev/null
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid" 2>/dev/null
    out="$(tail -n 1 "$log")"
    rm -f "$log"
    case "$out" in ok:fragments-on-trunk:* | skip:fragments-to-trunk:nothing-new) return 0 ;; esac
    return 1
}

# _published <provider> <until-epoch> — 0 when the plan already carries it.
_published() {
    local f
    for f in "$PLAN_DIR"/*-provider-limit-"$1"-*.yaml; do
        [ -f "$f" ] || continue
        grep -q "retry_after_epoch=$2 " "$f" && return 0
    done
    return 1
}

# _publish <provider> <until-epoch> <until-utc> <recorded-utc> <host>
_publish() {
    local provider="$1" until="$2" until_utc="$3" recorded="$4" host="$5" ts frag
    if _published "$provider" "$until"; then
        echo "ok:provider-limit-relay:already-published:$provider"
        return 0
    fi
    ts="$(date -u +%Y%m%dt%H%M%Sz)"
    frag="$PLAN_DIR/${ts}-provider-limit-${provider}-${host}.yaml"
    mkdir -p "$PLAN_DIR"
    cat >"$frag" <<EOF
# Ledger fragment — append-only, IMMUTABLE once written.
# Written by: scripts/provider-limit-relay.sh on-exit (order 1957-msjs).
events:
  - packet_id: $PACKET
    event:
      type: note
      ts: "$(_utc)"
      host: $host
      summary: |-
        provider-usage-limit provider=$provider retry_after=$until_utc retry_after_epoch=$until recorded_by=$host recorded=$recorded
EOF
    if _push "$frag"; then
        echo "ok:provider-limit-relay:published:$provider:${frag##*/}"
    else
        mkdir -p "$STATE" && printf '%s\n' "$frag" >>"$DEFERRED"
        echo "provider-limit-relay: the push of ${frag##*/} did not reach trunk; the next slot run retries it" >&2
        echo "ok:provider-limit-relay:deferred:$provider:${frag##*/}"
    fi
}

# _read_volume_records <volume> — the records in the volume's provider-limits dir, read as
# the volume's owner (rootless: through podman unshare).
_read_volume_records() {
    local mp
    mp="$(podman volume inspect -f '{{.Mountpoint}}' "$1" 2>/dev/null)" || return 1
    [ -n "$mp" ] || return 1
    # shellcheck disable=SC2016
    podman unshare sh -c 'for f in "$1"/provider-limits/*; do [ -f "$f" ] && printf "%s %s\n" "${f##*/}" "$(head -n 1 "$f")"; done' sh "$mp" 2>/dev/null
}

_read_dir_records() {
    local f
    for f in "$1"/*; do
        [ -f "$f" ] && printf '%s %s\n' "${f##*/}" "$(head -n 1 "$f")"
    done
}

cmd_on_exit() {
    local volume="" rdir="" host="" records now any=0 provider until until_utc recorded _rest
    while [ $# -gt 0 ]; do
        case "$1" in
            --volume) volume="${2:-}"; shift 2 ;;
            --record-dir) rdir="${2:-}"; shift 2 ;;
            --host) host="${2:-}"; shift 2 ;;
            *) _afford "$1 is not an on-exit flag" "pass --volume <name> or --record-dir <dir>, and optionally --host <h>"
               echo "refused:provider-limit-relay:usage:$1"; return 2 ;;
        esac
    done
    if [ -z "$volume" ] && [ -z "$rdir" ]; then
        _afford "on-exit needs to know where the forge wrote its record" "pass --volume <the forge's project cache volume> or --record-dir <dir>"
        echo "refused:provider-limit-relay:usage:--volume or --record-dir is required"; return 2
    fi
    [ -n "$host" ] || host="$(hostname -s 2>/dev/null || hostname)"
    if [ -n "$volume" ]; then records="$(_read_volume_records "$volume")" || records=""
    else records="$(_read_dir_records "$rdir")"; fi
    now="$(date -u +%s)"
    while read -r provider until until_utc recorded _rest; do
        [ -n "${provider:-}" ] || continue
        case "$until" in '' | *[!0-9]*) continue ;; esac
        [ "$now" -lt "$until" ] || continue
        any=1
        _publish "$provider" "$until" "$until_utc" "${recorded:-$(_utc)}" "$host"
    done <<<"$records"
    [ "$any" = 1 ] || echo "ok:provider-limit-relay:nothing-recorded"
}

# The latest live deadline per provider. A later fragment may carry an
# EARLIER deadline, so the fold compares deadlines, not file order. Portable
# to bash 3.2 (macOS hosts): no associative arrays.
cmd_seed_env() {
    local now f line provider until until_utc by rows=""
    now="$(date -u +%s)"
    for f in "$PLAN_DIR"/*-provider-limit-*.yaml; do
        [ -f "$f" ] || continue
        line="$(grep -m 1 'provider-usage-limit provider=' "$f")" || continue
        provider="$(sed -n 's/.* provider=\([^ ]*\).*/\1/p' <<<"$line")"
        until="$(sed -n 's/.* retry_after_epoch=\([0-9]*\).*/\1/p' <<<"$line")"
        until_utc="$(sed -n 's/.* retry_after=\([^ ]*\).*/\1/p' <<<"$line")"
        by="$(sed -n 's/.* recorded_by=\([^ ]*\).*/\1/p' <<<"$line")"
        [ -n "$provider" ] && [ -n "$until" ] || continue
        [ "$now" -lt "$until" ] || continue
        rows="${rows}${provider} ${until} ${until_utc} ${by:-another-host}"$'\n'
    done
    printf '%s' "$rows" | sort -k1,1 -k2,2nr \
        | awk '!seen[$1]++ { printf "%s%s", (n++ ? ";" : ""), $0 } END { print "" }'
}

cmd_retry() {
    local pushed=0 total=0 frag keep=""
    [ -s "$DEFERRED" ] || { echo "ok:provider-limit-relay:retried:0/0"; return 0; }
    while read -r frag; do
        [ -n "$frag" ] || continue
        total=$((total + 1))
        if [ -f "$frag" ] && _push "$frag"; then pushed=$((pushed + 1))
        elif [ -f "$frag" ]; then keep="${keep}${frag}"$'\n'
        fi
    done <"$DEFERRED"
    printf '%s' "$keep" >"$DEFERRED"
    echo "ok:provider-limit-relay:retried:$pushed/$total"
}

case "${1:-}" in
    on-exit) shift; cmd_on_exit "$@" ;;
    seed-env) shift; cmd_seed_env ;;
    retry) shift; cmd_retry ;;
    *) _afford "${1:-no subcommand} is not a subcommand of this script" "use on-exit, seed-env or retry (the header lists their flags)"
       echo "refused:provider-limit-relay:usage:${1:-no-subcommand}"; exit 2 ;;
esac
