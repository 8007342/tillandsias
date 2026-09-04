#!/usr/bin/env bash
# ORDER 998-qrwu: the CA directory comes from the ONE declaration
# (images/default/ca-path.txt), never a literal — see scripts/lib-ca-path.sh.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-ca-path.sh"
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
#
# THE ACTING ARM (order 878-79b5, opt-in via --act). Four unattended yoga
# cycles each re-noted the same cleanly-stopped proxy and changed nothing: on
# a bare development host no tray runs, so the in-process LivenessProbe
# (782-dpby) never fires, and the only component looking at the enclave was
# this reporter — a reporter by design. A note that fires every cycle and
# changes nothing trains its reader to skip it.
#
# --act makes the UNATTENDED caller (cycle-preflight) able to fix what it can
# prove needs fixing, without fighting an operator. The discrimination the
# in-container supervisor makes ("did I forward this stop?") is unavailable
# from outside, so the ladder below approximates intent from what IS visible:
#
#   1. HOLD MARKER  $STATE_DIR/service-hold-<name> exists — the operator's
#      sanctioned "leave it down". Never acted on:
#        note:enclave-service-held:service=...:action=none
#   2. STACK DOWN   up=0 — a deliberate teardown or a freshly-booted laptop,
#      the normal no-stack state the reporter's header already names. Never
#      acted on: note:enclave-service-unattended:...:reason=stack-down
#   3. GRACE        age_s < TILLANDSIAS_ENCLAVE_ACT_GRACE_S (default 1800) or
#      unknown — a just-stopped service is exactly what an operator mid-debug
#      looks like, so a fresh stop is NEVER fought (the packet's negative
#      control): note:enclave-service-grace:...:action=none
#   4. CAP          restarts within the 24h window have hit
#      TILLANDSIAS_ENCLAVE_ACT_CAP (default 3) — restarting is not helping:
#        fail:enclave-service-flapping:...:action=operator   <- nothing will
#      fix this; stop trying, say so once per cycle, wait for a human.
#   5. ACT          partial enclave, old stop, no hold, under cap:
#        fix:enclave-service-restarted:...:action=started    <- being fixed
#      or fail:enclave-service-start-failed:...:action=operator.
#
# The stdout summary stays the READING (pre-action) — the fix lines are the
# action record, and the next cycle's ok/degraded is the outcome. Counters
# live in $STATE_DIR/service-restarts-<name> as "epoch count", windowed, so a
# flapper goes quiet at the cap instead of being fought forever.

_HEALTH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -uo pipefail

PREFIX="${TILLANDSIAS_ENCLAVE_SERVICE_PREFIX:-tillandsias-}"
EXPECTED="${TILLANDSIAS_ENCLAVE_EXPECTED_SERVICES:-}"
# ORDER 1004-inkc — THE EXPECTED SET IS THIS SCRIPT'S, NOT ITS CALLER'S.
# Resolved after argument parsing (see _resolve_default_expected below), because
# an explicit --expect must still win.
STRICT=0
ACT=0
ACT_GRACE_S="${TILLANDSIAS_ENCLAVE_ACT_GRACE_S:-1800}"
ACT_CAP="${TILLANDSIAS_ENCLAVE_ACT_CAP:-3}"
ACT_WINDOW_S="${TILLANDSIAS_ENCLAVE_ACT_WINDOW_S:-86400}"
STATE_DIR="${TILLANDSIAS_CYCLE_STATE_DIR:-$HOME/.cache/tillandsias}"

while [ $# -gt 0 ]; do
    case "$1" in
        --strict) STRICT=1; shift ;;
        --act) ACT=1; shift ;;
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

# ORDER 1004-inkc — DEFAULT EXPECTED SET, WITH THE ANCHOR RULE, IN THE CHECK.
#
# THE DEFECT THIS CLOSES, measured on lenovinha-silverblue 2026-09-04, two
# readings of one host minutes apart with nothing repaired between them:
#   proxy container DOWN     -> degraded:enclave-service-health:services=6:up=5:down=1
#   proxy container REMOVED  -> ok:enclave-service-health:services=5:up=5:down=0:dead=0:absent=0
# The service went from stopped to NONEXISTENT and the verdict went from
# degraded to ok, printing absent=0 while a required service was absent. A gate
# that `podman rm` can satisfy is not a gate.
#
# The enumeration below walks what EXISTS, so a deleted member is invisible to
# it; without a declaration it never reaches the absent loop either. 994-8r3w
# declared the expected set but wired it into ONE CALLER (cycle-preflight), so
# the verdict depended on who invoked the script — and the bare invocation, the
# one an operator makes by hand, was the unguarded path. That order's own
# unmet criterion 3 says it: "nothing yet fails if a future edit stops preflight
# exporting the variable." This is that criterion, done in the check.
#
# THE ANCHOR RULE MOVES HERE TOO, and it is not optional. A machine that has
# never provisioned an enclave is not MISSING anything, and reporting it absent
# would be the cry-wolf failure that gets a check switched off — which is how
# the original gap survived. Vault is the anchor: every other persistent service
# depends on it in the graph, so its presence is what distinguishes "provisioned
# and degraded" from "never provisioned". Leaving the anchor in the caller while
# moving the default here would have re-created the same split one layer down.
#
# Precedence unchanged: --expect and TILLANDSIAS_ENCLAVE_EXPECTED_SERVICES still
# win, so every existing caller and fixture behaves exactly as before.
# `--expect none` (or the env set to `none`) means EXPECT NOTHING — pure
# enumeration, the behaviour every caller had before this order. It exists
# because an EMPTY value now means "use the default", so without an explicit
# token there is no way to ask for the old semantics, and a caller that wants
# them would have to pass a fake service name. Fixtures exercising unrelated
# properties (exit codes, origin labels, stale-healthy) use it so they do not
# silently inherit the fleet's expected set and start reporting an absence they
# were never written to model.
#
# ── FIXTURE-ONLY. NO PRODUCTION CALLER MAY PASS `none`. ─────────────────────
#
# This token disables the absent detection, which is the entire subject of
# 1004-inkc. A production caller passing it would turn this check back into one
# that CANNOT FAIL on a deleted service — precisely the class the order just
# removed, reintroduced through the door built to fix it.
#
# Enforced, not merely requested: scripts/check-enclave-expect-none-is-fixture-only.sh
# refuses any caller outside the fixture, and it is wired into local-ci.sh. The
# rule is deliberately a LINT rather than a runtime guard keyed on a test-only
# environment variable — such a variable is itself settable from production, so
# it would move the hole rather than close it.
if [ "$EXPECTED" = "none" ]; then
    EXPECTED=""
elif [ -z "$EXPECTED" ]; then
    _declared_file="$_HEALTH_DIR/../images/default/enclave-services.txt"
    if [ -r "$_declared_file" ] && podman container exists "${PREFIX}vault" 2>/dev/null; then
        EXPECTED="$(
            grep -v '^[[:space:]]*#' "$_declared_file" 2>/dev/null \
              | grep -v '^[[:space:]]*$' \
              | tr '\n' ',' | sed 's/,$//'
        )"
    fi
fi

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
    # 878-79b5: remember the down set for the acting arm; the decision needs
    # the final `up` count, so it runs after the loop, not here.
    down_list="${down_list:-}${name}|${age_s}
"
done <<EOF
$ps_out
EOF

# ── The acting arm (878-79b5) — see the header ladder ────────────────────────
if [ "$ACT" -eq 1 ] && [ -n "${down_list:-}" ]; then
    while IFS='|' read -r name age_s; do
        [ -n "$name" ] || continue
        if [ -f "$STATE_DIR/service-hold-${name}" ]; then
            details="${details}note:enclave-service-held:service=${name}:action=none:reason=operator-hold-marker
"
            continue
        fi
        if [ "$up" -eq 0 ]; then
            details="${details}note:enclave-service-unattended:service=${name}:action=none:reason=stack-down
"
            continue
        fi
        if [ "$age_s" -lt 0 ] || [ "$age_s" -lt "$ACT_GRACE_S" ]; then
            details="${details}note:enclave-service-grace:service=${name}:action=none:age_s=${age_s}:grace_s=${ACT_GRACE_S}
"
            continue
        fi
        # Windowed restart counter: "epoch count", reset when the window laps.
        _cf="$STATE_DIR/service-restarts-${name}"
        _cepoch=0 _ccount=0
        if [ -f "$_cf" ]; then
            read -r _cepoch _ccount < "$_cf" 2>/dev/null || true
            case "$_cepoch" in ''|*[!0-9]*) _cepoch=0 ;; esac
            case "$_ccount" in ''|*[!0-9]*) _ccount=0 ;; esac
            if [ "$_cepoch" -gt 0 ] && [ $((now - _cepoch)) -gt "$ACT_WINDOW_S" ]; then
                _cepoch=0 _ccount=0
            fi
        fi
        if [ "$_ccount" -ge "$ACT_CAP" ]; then
            details="${details}fail:enclave-service-flapping:service=${name}:restarts=${_ccount}:window_s=${ACT_WINDOW_S}:action=operator
"
            continue
        fi
        # ORDER 975-rsgm. RESTORE THE PRECONDITION BEFORE STARTING THE PROXY,
        # because `podman start` alone is what CREATES the second failure.
        #
        # The proxy is served its certificate from a bind mount and its private
        # key from the podman secret `tillandsias-ca-key`.
        # `ensure_proxy_ca_key_secret` refreshes that secret with `--replace`
        # immediately before every launch — on the LAUNCH path only. This
        # self-heal, and the REMEDY line this script prints, both use plain
        # `podman start`, which bypasses it. So after any CA regeneration the
        # heal "succeeds", squid comes up, and dies:
        #
        #   WARNING: '/etc/squid/certs/intermediate.key' X509_check_private_key() failed
        #   FATAL: No valid signing certificate configured for HTTP_port [::]:3128
        #
        # MEASURED on yoga over five cycles: the restart reported
        # `fix:enclave-service-restarted:...:action=started` and the container
        # was dead seconds later, with a message naming neither file. The heal
        # was reporting success for an action that could not work.
        #
        # Refreshing the secret from the current bundle is exactly what the
        # launch path does, so this is not a new policy — it is the same
        # precondition, applied on the path that was missing it. It runs ONLY
        # for the proxy and ONLY when the pair actually disagrees, so a healthy
        # host pays one modulus comparison and nothing is rotated needlessly.
        _ca_check="${TILLANDSIAS_CA_CONSISTENCY_CHECK:-$_HEALTH_DIR/check-enclave-ca-consistency.sh}"
        if [ "$name" = "tillandsias-proxy" ] && [ -x "$_ca_check" ]; then
            if ! bash "$_ca_check" >/dev/null 2>&1; then
                _cadir="${TILLANDSIAS_CA_DIR}"
                if [ -r "$_cadir/intermediate.key" ] \
                   && _run podman secret create --replace tillandsias-ca-key "$_cadir/intermediate.key" >/dev/null 2>&1; then
                    details="${details}fix:enclave-ca-key-rotated:service=${name}:action=secret-replaced
"
                else
                    # Say so rather than starting into a certain death. A start
                    # that reports `started` and dies is worse than a refusal
                    # that names the reason.
                    details="${details}fail:enclave-ca-desync-unrepaired:service=${name}:action=operator
"
                    continue
                fi
            fi
        fi
        if _run podman start "$name" >/dev/null 2>&1; then
            [ "$_cepoch" -eq 0 ] && _cepoch="$now"
            _ccount=$((_ccount + 1))
            mkdir -p "$STATE_DIR" 2>/dev/null || true
            printf '%s %s\n' "$_cepoch" "$_ccount" > "$_cf" 2>/dev/null || true
            details="${details}fix:enclave-service-restarted:service=${name}:restarts=${_ccount}:action=started
"
        else
            details="${details}fail:enclave-service-start-failed:service=${name}:action=operator
"
        fi
    done <<EOF
$down_list
EOF
fi

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
            # ORDER 1004-inkc: an absent member still COUNTS as a service. Left
            # out, `services=` shrinks when a member is deleted — which is half
            # of what made the two readings look like an improvement: 6 down to
            # 5 reads as "one fewer thing to worry about" rather than "one thing
            # vanished".
            total=$((total + 1))
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
    echo "  REMEDY: 'podman logs <service>' for the last words, then bring the enclave up through" >&2
    echo "  the orchestration: 'tillandsias --ensure-enclave' (idempotent), NOT 'podman start <service>' and NOT '--init', which only builds images (1004-xw3q). Order 975-rsgm: a bare" >&2
    echo "  'podman start' skips the preconditions the launch path establishes — for the" >&2
    echo "  proxy that is the CA key secret, and starting without it produces a DIFFERENT" >&2
    echo "  failure (squid: X509_check_private_key() failed) whose message names neither" >&2
    echo "  the certificate nor the key, sending the reader at the wrong subsystem." >&2
    echo "  If it exits again immediately, that is a crash loop and belongs in a packet," >&2
    echo "  not a restart." >&2
fi

if [ "$down" -gt 0 ] || [ "$absent" -gt 0 ]; then
    echo "degraded:enclave-service-health:services=${total}:up=${up}:down=${down}:dead=${dead}:absent=${absent}"
    [ "$STRICT" -eq 1 ] && exit 1
    exit 0
fi

# ORDER 1004-inkc: print the COMPUTED absent, not a hard-coded 0. This line is
# only reached when down and absent are both zero, so the value is 0 either way
# — but a literal here means the ok verdict asserts something it never measured,
# and the next person to change the absent logic gets no help from it.
echo "ok:enclave-service-health:services=${total}:up=${up}:down=0:dead=0:absent=${absent}"
exit 0
