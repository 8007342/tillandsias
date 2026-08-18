#!/usr/bin/env bash
# @trace spec:runtime-diagnostics
#
# check-enclave-service-health.sh — ONE place that reports the health of the
# whole enclave service set, with each dead service's last exit code, signal,
# and age. Order 798-tk7b.
#
# THE DEFECT, measured on macuahuitl 2026-08-17T11:02Z and STILL TRUE when this
# script was written 2026-08-18T02:50Z:
#
#   tillandsias-nix     Exited (143)  2 days ago
#   tillandsias-vault   Exited (137)  5 hours ago (healthy)
#
# 143 is SIGTERM, 137 is SIGKILL. Neither produced an alarm anywhere a cycle
# would see it, and several cycles ran on this host in those hours — including
# ones that used podman heavily. `tillandsias-nix` was still dead three days
# later, discovered the same way both times: by someone typing `podman ps -a`
# for an unrelated reason.
#
# Note the vault line especially. podman prints `Exited (137) ... (healthy)`
# because the recorded healthcheck state OUTLIVES the container. A dead service
# advertising "healthy" is worse than one advertising nothing: it is the same
# shape as 797-5kqe (a preflight asserting a cause it never measured), where the
# status is not merely absent but confidently wrong. This script names that
# state `health=stale-healthy` rather than passing podman's word along.
#
# WHY THIS IS NOT A FOURTH SUPERVISOR. There are already three mechanisms in
# this family and the packet asks them to converge on one vocabulary before
# there is a fourth:
#
#   767-es4w  images/proxy/squid-supervisor.sh    — PID 1 inside the proxy
#   767-nkkq  images/default/harness-supervisor.sh — PID 1 inside the forge
#   798-tk7b  this script                          — the HOST's view of the set
#
# The two supervisors answer "the process inside this container died"; they can
# only speak while their container is alive. Nothing answered "which containers
# are dead right now", which is precisely the question a five-hour-old corpse
# needs asked. So this is a REPORTER, not a supervisor: it starts nothing,
# restarts nothing, and kills nothing. It speaks the supervisors' grammar —
# `<class>:<subject>:key=value:...` with the same `service`, `rc`, `signal`
# keys — so one grep spans all three.
#
# A FOURTH ARRIVED ANYWAY, CONCURRENTLY, and this file now follows it. The yoga
# host implemented the same packet the same night, inside the product:
# `format_enclave_service_line` in crates/tillandsias-headless/src/main.rs,
# surfaced through `tillandsias --diagnostics`. Neither of us held a lease.
# That implementation reaches end users inside the enclave and this one does
# not, so it is the canonical surface and its spellings win here:
# `fail:enclave-service-dead` / `note:enclave-service-stopped` /
# `signal=SIGKILL`, shared keys emitted in ITS order, with this script's extra
# facts (health, origin, age_s) appended after them. Shipping two dialects for
# the packet that asked for one vocabulary would have been a self-inflicted
# violation of the thing it closed. What remains genuinely different — this
# script needs no product build, runs in cycle-preflight where the dev-loop
# blind spot actually was, names the stale-healthy corpse, and can be told what
# to EXPECT — is the open reconciliation question, filed as 814-iyu7.
#
# REPORT BY DEFAULT, GATE ON DEMAND. A host with no stack running has every
# service down, and that is the normal state of a laptop that just booted; a
# reporter that fails the build there would be turned off within a day. So the
# exit code is 0 for any successfully-taken reading, and the CLASS of the
# summary line carries the finding. `--strict` exits 1 on `degraded:` for the
# callers that genuinely require a live stack (e2e preflight).
#
# ABSENCE NEEDS A DECLARATION. A container that was never created cannot be
# found by enumeration — the set is derived from what exists. Callers that know
# what SHOULD exist pass `--expect a,b,c` (or
# TILLANDSIAS_ENCLAVE_EXPECTED_SERVICES) and get `enclave-service-absent` lines
# for the missing ones. 798-c4mq is the worked example of that fault for the git
# mirror specifically, and deliberately keeps its own richer three-precondition
# ladder; this script does not duplicate it.
#
# GRAMMAR — exactly one line on stdout:
#   ^(ok|degraded):enclave-service-health:services=[0-9]+:up=[0-9]+:down=[0-9]+:dead=[0-9]+:absent=[0-9]+$
#   ^blocked:enclave-service-health:(no-podman|unreadable)$
# Per-service detail is stderr, one line each, in the supervisors' grammar.

set -uo pipefail

PREFIX="${TILLANDSIAS_ENCLAVE_SERVICE_PREFIX:-tillandsias-}"
EXPECTED="${TILLANDSIAS_ENCLAVE_EXPECTED_SERVICES:-}"
STRICT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --strict) STRICT=1; shift ;;
        --expect) EXPECTED="${2:-}"; shift 2 ;;
        --expect=*) EXPECTED="${1#--expect=}"; shift ;;
        --prefix) PREFIX="${2:-}"; shift 2 ;;
        -h|--help) sed -n '3,60p' "$0"; exit 0 ;;
        *) echo "blocked:enclave-service-health:unreadable"; echo "  unknown argument: $1" >&2; exit 2 ;;
    esac
done

command -v podman >/dev/null 2>&1 || {
    echo "blocked:enclave-service-health:no-podman"
    exit 0
}

# A wedged podman must not hang a cycle preflight. `timeout` is not universal;
# absence of it is not a reason to skip the reading.
_run() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 15 "$@"
    else
        "$@"
    fi
}

now="$(date -u +%s 2>/dev/null || echo 0)"

# One round trip for the set. `.StartedAt` and `.ExitedAt` are unix epochs in
# podman's template vocabulary, which is why this needs no `date -d` and works
# where GNU date does not.
ps_out="$(_run podman ps -a --format \
    '{{.Names}}|{{.State}}|{{.ExitCode}}|{{.StartedAt}}|{{.ExitedAt}}|{{.Restarts}}' 2>/dev/null)"
ps_rc=$?
if [ "$ps_rc" -ne 0 ]; then
    echo "blocked:enclave-service-health:unreadable"
    echo "  podman ps -a exited ${ps_rc}; no reading was taken. This is NOT a report of a healthy stack." >&2
    exit 0
fi

# Compact age: the number a human acts on, next to the seconds a check greps.
_age() { # <seconds>
    local s="$1"
    if [ "$s" -lt 0 ]; then printf 'unknown'; return; fi
    if [ "$s" -lt 60 ]; then printf '%ds' "$s"; return; fi
    if [ "$s" -lt 3600 ]; then printf '%dm' $((s / 60)); return; fi
    if [ "$s" -lt 86400 ]; then printf '%dh%dm' $((s / 3600)) $(((s % 3600) / 60)); return; fi
    printf '%dd%dh' $((s / 86400)) $(((s % 86400) / 3600))
}

names=""
up=0
down=0
dead=0
absent=0
total=0
details=""
saw_stale_healthy=0

while IFS='|' read -r name state exitcode started exited restarts; do
    [ -n "$name" ] || continue
    # Only enclave services. The cross-control for this line is a foreign
    # container in the store (`modest_proskuriakova`, live on macuahuitl):
    # without the prefix test it would be reported as a dead enclave service.
    case "$name" in
        "$PREFIX"*) : ;;
        *) continue ;;
    esac
    total=$((total + 1))
    names="${names} ${name}"

    if [ "$state" = "running" ]; then
        up=$((up + 1))
        continue
    fi

    down=$((down + 1))

    # Signal SPELLING is yoga's (crates/tillandsias-headless format_enclave_service_line,
    # same order, same night): 128+N is the shell/OCI convention, and the NAME is
    # what a reader acts on. Two implementations of one packet must not ship two
    # dialects of its vocabulary — see the reconciliation note in this cycle's
    # fragment.
    sig="none"
    case "$exitcode" in
        ''|*[!0-9]*) exitcode="unknown" ;;
        *)
            if [ "$exitcode" -gt 128 ] && [ "$exitcode" -lt 192 ]; then
                case $((exitcode - 128)) in
                    9) sig="SIGKILL" ;;
                    15) sig="SIGTERM" ;;
                    11) sig="SIGSEGV" ;;
                    *) sig="SIG$((exitcode - 128))" ;;
                esac
            fi
            ;;
    esac
    case "$restarts" in ''|*[!0-9]*) restarts=0 ;; esac

    age_s=-1
    case "$exited" in
        ''|*[!0-9]*) : ;;
        *) [ "$now" -gt 0 ] && [ "$exited" -gt 0 ] && age_s=$((now - exited)) ;;
    esac

    # Health is read from inspect, not from the `podman ps` Status phrase. The
    # phrase for a dead container is `Exited (143) 2 days ago` — its LAST
    # parenthetical is the exit code, so a "read the parens" parse reports
    # health=143 on exactly the containers this script exists for.
    #
    # `origin` comes from the SAME round trip. Product-built images carry
    # io.tillandsias.image.name=<role>; a container merely WEARING the name
    # prefix does not. Measured 2026-08-18: the three-day-old `tillandsias-nix`
    # corpse that motivated this packet is a hand-made fedora-toolbox:44 from an
    # operator's nix experiment, referenced nowhere in the tree — knowing that
    # is the difference between "restart the service" and "remove the leftover".
    #
    # This is an ANNOTATION, deliberately not a filter. Keying the set on the
    # label instead of the name would have silently dropped `tillandsias-nix-cache`
    # — running, real, and unlabelled because it is built outside the product
    # image path. Over-reporting a leftover is recoverable; hiding a live
    # service from the one place that reports live services is the bug.
    _insp="$(_run podman inspect "$name" \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{if .Config.Labels}}{{index .Config.Labels "io.tillandsias.image.name"}}{{end}}' 2>/dev/null)"
    health="$(printf '%s' "$_insp" | cut -d'|' -f1 | tr -d '[:space:]')"
    origin="$(printf '%s' "$_insp" | cut -d'|' -f2 | tr -d '[:space:]')"
    [ -n "$health" ] || health="none"
    case "$origin" in
        ''|'<novalue>') origin="unlabelled" ;;
        *) origin="product-${origin}" ;;
    esac

    # THE CONFIDENTLY-WRONG CASE. A stopped container whose recorded
    # healthcheck still says healthy. Named, never passed through.
    if [ "$health" = "healthy" ]; then
        health="stale-healthy"
        saw_stale_healthy=1
    fi

    # SHARED KEYS FIRST, in yoga's order, so one grep spans both implementations
    # and the two supervisors; this script's extra facts follow. A clean stop is
    # not a fault: conflating it with a crash makes the report noisy enough to
    # ignore, which is how the original blind spot survived five hours.
    if [ "$exitcode" = "0" ]; then
        _class="note:enclave-service-stopped"
    else
        _class="fail:enclave-service-dead"
        dead=$((dead + 1))
    fi
    details="${details}${_class}:service=${name}:state=${state}:rc=${exitcode}:signal=${sig}:age=$(_age "$age_s"):restarts=${restarts}:health=${health}:origin=${origin}:age_s=${age_s}
"
done <<EOF
$ps_out
EOF

# Declared-but-missing services. Enumeration cannot see these; only a caller
# that says what it expects can.
if [ -n "$EXPECTED" ]; then
    while IFS= read -r want; do
        [ -n "$want" ] || continue
        found=0
        for have in $names; do
            [ "$have" = "$want" ] && found=1 && break
        done
        if [ "$found" -eq 0 ]; then
            absent=$((absent + 1))
            details="${details}fail:enclave-service-absent:service=${want}:state=absent:rc=none:signal=none:age=unknown:restarts=0:health=none:origin=unknown:age_s=-1
"
        fi
    done <<EOF
$(printf '%s' "$EXPECTED" | tr ',' '\n')
EOF
fi

if [ -n "$details" ]; then
    printf '%s' "$details" >&2
    if [ "$saw_stale_healthy" -eq 1 ]; then
        echo "  NOTE: health=stale-healthy means podman still reports the LAST healthcheck result for a container that is no longer running. The service is dead; the word 'healthy' beside it is podman's stale record, not a reading." >&2
    fi
    echo "  CAUSE: an enclave service exited and nothing restarted it. rc>128 means it died of signal rc-128 (143=SIGTERM, 137=SIGKILL, 139=SIGSEGV); the in-container supervisors (767-es4w proxy, 767-nkkq forge harness) can only speak while their container lives, so a stopped container is silent by construction." >&2
    echo "  REMEDY: 'podman logs <service>' for the last words, then 'podman start <service>' or re-run the enclave orchestration. If it exits again immediately, that is a crash loop and belongs in a packet, not a restart." >&2
fi

if [ "$down" -gt 0 ] || [ "$absent" -gt 0 ]; then
    echo "degraded:enclave-service-health:services=${total}:up=${up}:down=${down}:dead=${dead}:absent=${absent}"
    [ "$STRICT" -eq 1 ] && exit 1
    exit 0
fi

echo "ok:enclave-service-health:services=${total}:up=${up}:down=0:dead=0:absent=0"
exit 0
