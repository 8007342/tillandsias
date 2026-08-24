#!/usr/bin/env bash
# @trace order:756-hn3a, spec:methodology-accountability
# freshness: auditor=windows-yolanda-fable5-20260816t0850z date=2026-08-16 verdict=refreshed scope=full file audit on windows (the platform whose hostname/-s gap motivated 743-mgf3): CLI id/node-name correct, bare invocation refuses empty-backend per grammar, hermetic fixture 11/11 green incl. env -i and bash-3.2 lowercase paths
# Pinned by litmus:agent-identity-canonical-source-shape.
# bash-dialect: dual (probed fallback) — the timestamp helper probes the
# printf time builtin and falls back to date(1); everything else is
# pure-3.2. Marker consumed by scripts/check-bash-dialect.sh (761-g36m).
#
# agent-identity.sh — the CANONICAL source of a worker agent's identity.
# Sourceable (functions only, no side effects) AND executable (CLI below).
#
# WHY THIS EXISTS. On 2026-08-15 a fresh-Windows forge (codex lane) minted the
# lease id `forge--codex-20260815t162555z` — an EMPTY workstation component —
# because its ad-hoc claim recipe shelled out to a `hostname` executable the
# forge image does not ship. In the same process HOSTNAME=forge-tillandsias
# was exported, /etc/hostname said forge-tillandsias, and
# `scripts/mo-full-attest.sh host` resolved `forge`: the identity was sitting
# in the environment and the recipe never looked. Every claiming workflow now
# calls THIS helper instead of hand-composing an id from prose
# (methodology/distributed-work.yaml -> agent_identity_contract).
#
# ID SHAPE:  <platform>-<workstation>-<backend>-<utc-timestamp>
#            e.g. forge-forge-tillandsias-codex-20260815t162555z
#
# PRECEDENCE (order 756-hn3a):
#   1. TILLANDSIAS_AGENT_ID          — launch-provided, taken WHOLE (sanitized
#                                      once, never recomposed).
#   Otherwise the id is COMPOSED per component:
#   platform    — TILLANDSIAS_HOST_KIND=forge or the .forge-startup-context.md
#                 marker => forge; else $OSTYPE (a bash-set builtin variable,
#                 PATH-proof); else $OS; else `uname -s`.
#   workstation — 2. TILLANDSIAS_WORKSTATION (stable launch-provided identity)
#                 3. $HOSTNAME (bash sets it even under `env -i`; honored
#                    verbatim when inherited, including inherited-empty)
#                 4. /etc/hostname (read builtin — no executable needed;
#                    TILLANDSIAS_ETC_HOSTNAME overrides the path for hermetic
#                    fixtures only, same idiom as MO_FULL_REMOTE_PROBE)
#                 5. tillandsias_node_name — the portable node-name probe
#                    SHARED with scripts/mo-full-attest.sh's host label
#                    (order 743-mgf3): hostname -s -> hostname -> uname -n ->
#                    /etc/hostname, domain-stripped and lowercased with bash
#                    builtins.
#   backend     — the harness lane: explicit argument, else TILLANDSIAS_AGENT
#                 (the harness TYPE — claude|codex|opencode|gemini — order 570).
#   timestamp   — UTC via the printf '%(...)T' builtin: no `date` executable
#                 required, so a minimal image cannot lose this component.
#
# SANITIZE ONCE. Each component (or the explicit id, whole) is lowercased,
# every character outside [a-z0-9-] becomes '-', runs of '-' collapse, and
# leading/trailing '-' are trimmed. Exactly once, here — consumers never
# re-sanitize.
#
# REFUSE, DON'T IMPROVISE. If platform, workstation, backend, or timestamp
# resolves empty the helper prints NOTHING on stdout, emits exactly one loud
# stderr verdict, and exits non-zero — BEFORE any append-event can happen:
#
#   ^refused:agent-identity:empty-(explicit-id|platform|workstation|backend|timestamp)$
#
# Usage:
#   scripts/agent-identity.sh id [backend]   # print the full agent id
#   scripts/agent-identity.sh node-name      # print the shared node-name probe
#
# Fixture: scripts/test-agent-identity.sh (hermetic env -i scenarios).
# Litmus:  openspec/litmus-tests/litmus-agent-identity-canonical-source-shape.yaml

# tillandsias_node_name — the portable node-name fallback chain, extracted
# from mo-full-attest.sh's mo_full_host() (order 743-mgf3) so the agent
# identity and the MO-FULL ledger label derive from ONE implementation.
#
# `hostname -s` is a GNU/BSD spelling. MSYS/Git Bash on Windows ships a
# hostname that REJECTS -s ("unknown option -- s") and there is no
# /etc/hostname, so the -s form returned empty and mo-full-attest `record`
# refused with "cannot determine host label" on every Windows host — locking
# that host out of the attestation ledger entirely (measured 2026-08-15).
# Fall back to bare `hostname` and strip any domain ourselves, which is all
# -s does. Then the kernel's own view (`uname -n` — some environments ship no
# hostname(1) at all), then /etc/hostname via the `read` builtin.
#
# Strip the domain and lowercase with BASH BUILTINS, not cut/tr. The external
# form resolved correctly when run by hand and returned EMPTY under
# ./build.sh --check, which is the difference between a helper that works and
# one that works where you tested it. Builtins have no PATH sensitivity, so
# this cannot depend on the caller's environment.
# ${var,,} is bash>=4; Apple ships bash 3.2 and /usr/bin/env bash resolves to
# it (738-3pft decision 4: shared writers stay 3.2-clean or fail loud — on 3.2
# the bash-4 form is a bad-substitution error, the label came back EMPTY, and
# the attestation gate failed closed for the whole macOS host). Lowercase via
# a case table instead: pure builtins, so it keeps this file's env -i /
# empty-PATH guarantee, and it is ONE code path that behaves identically on
# every bash rather than a fast path plus a fallback that only runs where
# nobody tested it — the exact failure mode the header describes.
tillandsias_lower() {
    local s="${1:-}" out="" c i
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            A) c=a ;; B) c=b ;; C) c=c ;; D) c=d ;; E) c=e ;; F) c=f ;;
            G) c=g ;; H) c=h ;; I) c=i ;; J) c=j ;; K) c=k ;; L) c=l ;;
            M) c=m ;; N) c=n ;; O) c=o ;; P) c=p ;; Q) c=q ;; R) c=r ;;
            S) c=s ;; T) c=t ;; U) c=u ;; V) c=v ;; W) c=w ;; X) c=x ;;
            Y) c=y ;; Z) c=z ;;
        esac
        out="$out$c"
    done
    printf '%s' "$out"
    return 0
}

tillandsias_node_name() {
    local h="" etc="${TILLANDSIAS_ETC_HOSTNAME:-/etc/hostname}"
    h="$(hostname -s 2>/dev/null || true)"
    [ -n "$h" ] || h="$(hostname 2>/dev/null || true)"
    [ -n "$h" ] || h="$(uname -n 2>/dev/null || true)"
    [ -n "$h" ] || { [ -r "$etc" ] && read -r h < "$etc"; }
    h="${h%%.*}"
    tillandsias_lower "$h"
    return 0
}

# tillandsias_sanitize_component <raw> — the ONE sanitize pass: lowercase,
# [^a-z0-9-] -> '-', collapse '-' runs, trim leading/trailing '-'. Builtins
# only.
tillandsias_sanitize_component() {
    local s="${1:-}"
    s="$(tillandsias_lower "$s")"
    s="${s//[^a-z0-9-]/-}"
    while [[ "$s" == *--* ]]; do s="${s//--/-}"; done
    s="${s#-}"
    s="${s%-}"
    printf '%s' "$s"
    return 0
}

# tillandsias_agent_platform — forge marker first (both the env kind every
# forge entrypoint exports and the workspace marker mo-full-attest.sh keys
# on), then bash's own $OSTYPE (set by the shell itself, so it survives
# `env -i` and an empty PATH), then $OS, then `uname -s`.
tillandsias_agent_platform() {
    local forge_context
    if [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ]; then
        printf 'forge'
        return 0
    fi
    # The override is a fixture seam like TILLANDSIAS_ETC_HOSTNAME below: a
    # test running inside a real forge must be able to model a bare host without
    # renaming the checkout's live startup marker.
    forge_context="${TILLANDSIAS_FORGE_CONTEXT:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)/.forge-startup-context.md}"
    if [ -f "$forge_context" ]; then
        printf 'forge'
        return 0
    fi
    case "${OSTYPE:-}" in
        linux*)             printf 'linux'; return 0 ;;
        darwin*)            printf 'macos'; return 0 ;;
        msys*|cygwin*|win*) printf 'windows'; return 0 ;;
    esac
    if [ "${OS:-}" = "Windows_NT" ]; then
        printf 'windows'
        return 0
    fi
    case "$(uname -s 2>/dev/null || true)" in
        Linux)                         printf 'linux' ;;
        Darwin)                        printf 'macos' ;;
        MINGW*|MSYS*|CYGWIN*|Windows*) printf 'windows' ;;
        *)                             printf '' ;;
    esac
    return 0
}

# tillandsias_agent_workstation — precedence 2..5 from the header. The
# launch-provided value is authoritative as given; every derived source is
# domain-stripped (dots would otherwise sanitize into '-' noise).
tillandsias_agent_workstation() {
    local w="" etc="${TILLANDSIAS_ETC_HOSTNAME:-/etc/hostname}"
    if [ -n "${TILLANDSIAS_WORKSTATION:-}" ]; then
        printf '%s' "$TILLANDSIAS_WORKSTATION"
        return 0
    fi
    w="${HOSTNAME:-}"
    if [ -z "$w" ]; then
        [ -r "$etc" ] && read -r w < "$etc"
    fi
    [ -n "$w" ] || w="$(tillandsias_node_name)"
    printf '%s' "${w%%.*}"
    return 0
}

# tillandsias_agent_backend [backend] — explicit argument wins; else the
# harness type the launcher exported (TILLANDSIAS_AGENT, order 570). No
# guessing: an empty backend is the caller's refusal to say who is claiming.
tillandsias_agent_backend() {
    local b="${1:-}"
    [ -n "$b" ] || b="${TILLANDSIAS_AGENT:-}"
    printf '%s' "$b"
    return 0
}

# tillandsias_agent_timestamp — UTC compact stamp via the printf time builtin
# (bash >= 4.2). Apple's bash 3.2 printf rejects '%(' as an invalid format
# character and exits non-zero, so probe silently and fall back to date(1)
# with the identical format. There is no pure-builtin clock on 3.2, so the
# fallback tries PATH first, then the fixed locations date actually occupies
# on the hosts where bash 3.2 exists (macOS/BSD: /bin/date) — keeping the
# env -i guarantee everywhere the time builtin exists, and degrading to a
# fixed absolute path, never to silence, where it does not. TZ is scoped to
# the one call in every branch.
tillandsias_agent_timestamp() {
    local d
    if TZ=UTC0 printf '%(%s)T' -1 >/dev/null 2>&1; then
        TZ=UTC0 printf '%(%Y%m%dt%H%M%S)Tz' -1
        return 0
    fi
    for d in date /bin/date /usr/bin/date; do
        if TZ=UTC0 "$d" '+%Y%m%dt%H%M%Sz' 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# tillandsias_agent_id [backend] — the full canonical id on stdout, or a
# refusal verdict on stderr + non-zero exit (grammar in the header). Refusal
# happens BEFORE the caller can reach an append-event.
tillandsias_agent_id() {
    local platform workstation backend ts whole
    if [ -n "${TILLANDSIAS_AGENT_ID:-}" ]; then
        whole="$(tillandsias_sanitize_component "$TILLANDSIAS_AGENT_ID")"
        if [ -z "$whole" ]; then
            echo 'refused:agent-identity:empty-explicit-id' >&2
            return 1
        fi
        printf '%s\n' "$whole"
        return 0
    fi
    platform="$(tillandsias_sanitize_component "$(tillandsias_agent_platform)")"
    workstation="$(tillandsias_sanitize_component "$(tillandsias_agent_workstation)")"
    backend="$(tillandsias_sanitize_component "$(tillandsias_agent_backend "${1:-}")")"
    ts="$(tillandsias_sanitize_component "$(tillandsias_agent_timestamp)")"
    [ -n "$platform" ]    || { echo 'refused:agent-identity:empty-platform' >&2; return 1; }
    [ -n "$workstation" ] || { echo 'refused:agent-identity:empty-workstation' >&2; return 1; }
    [ -n "$backend" ]     || { echo 'refused:agent-identity:empty-backend' >&2; return 1; }
    [ -n "$ts" ]          || { echo 'refused:agent-identity:empty-timestamp' >&2; return 1; }
    printf '%s-%s-%s-%s\n' "$platform" "$workstation" "$backend" "$ts"
    return 0
}

# Executed (not sourced): run the CLI. Shell options are set only on this
# branch so sourcing never mutates the caller's shell.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -uo pipefail
    cmd="${1:-id}"
    [ $# -gt 0 ] && shift
    case "$cmd" in
        id)
            tillandsias_agent_id "${1:-}"
            exit $?
            ;;
        node-name)
            tillandsias_node_name
            printf '\n'
            exit 0
            ;;
        *)
            echo "usage: $0 {id [backend]|node-name}" >&2
            exit 2
            ;;
    esac
fi
