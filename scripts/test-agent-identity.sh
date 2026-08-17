#!/usr/bin/env bash
# @trace order:756-hn3a, spec:methodology-accountability
set -uo pipefail

# Hermetic fixture for the canonical agent-identity helper (order 756-hn3a).
#
# Reproduces the 2026-08-15 breach shape — a forge image WITHOUT a hostname
# executable minting the lease id `forge--codex-20260815t162555z` (EMPTY
# workstation component) while HOSTNAME=forge-tillandsias and /etc/hostname
# were both present — and proves the helper (a) completes the id from the
# environment the old recipe ignored, and (b) REFUSES loudly, before any
# append-event, when identity genuinely cannot be resolved.
#
# Every scenario runs under `env -i` with PATH pointed at an EMPTY directory,
# so no hostname/uname/date executable can leak in from the host: what these
# scenarios prove is exactly what a minimal forge image gets. The
# TILLANDSIAS_ETC_HOSTNAME override stands in for /etc/hostname (fixture-only
# seam, same idiom as MO_FULL_REMOTE_PROBE in mo-full-attest.sh).
#
# Verdict: exactly one final line
#   PASS: agent-identity fixture <n>/<n> scenarios green (...)
# or FAIL diagnostics + a final FAIL line, exit 1.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/agent-identity.sh"
MO_ATTEST="$ROOT/scripts/mo-full-attest.sh"
BASH_BIN="${BASH:-/bin/bash}"

work="$(mktemp -d "${TMPDIR:-/tmp}/agent-identity-fixture.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/nobin" "$work/cwd"
NOPATH="$work/nobin"

ID_RE='^[a-z0-9][a-z0-9-]*[a-z0-9]$'
TS_RE='[0-9]{8}t[0-9]{6}z'

failures=()

# run_id_case <name> <expect-rc> <expect-stdout-re|-> <expect-stderr-re|-> [env assignments...]
# Runs `agent-identity.sh id` inside env -i from a neutral cwd. `-` skips the
# corresponding assertion; stdout must be EMPTY whenever expect-rc != 0 (a
# refusal must not hand the caller anything a claim recipe could paste in).
run_id_case() {
    local name="$1" want_rc="$2" want_out_re="$3" want_err_re="$4"
    shift 4
    local rc=0 out="" err=""
    out="$(cd "$work/cwd" && env -i PATH="$NOPATH" "$@" "$BASH_BIN" "$HELPER" id 2>"$work/err")" || rc=$?
    err="$(cat "$work/err" 2>/dev/null || true)"
    if [ "$rc" -ne "$want_rc" ]; then
        failures+=("$name: exit=$rc expected=$want_rc (stdout='$out' stderr='$err')")
        return 0
    fi
    if [ "$want_rc" -ne 0 ] && [ -n "$out" ]; then
        failures+=("$name: refusal leaked stdout '$out' — a refused id must print NOTHING a claim could use")
        return 0
    fi
    if [ "$want_out_re" != "-" ] && ! printf '%s' "$out" | grep -qE "$want_out_re"; then
        failures+=("$name: stdout '$out' !~ $want_out_re")
        return 0
    fi
    if [ "$want_err_re" != "-" ] && ! printf '%s' "$err" | grep -qE "$want_err_re"; then
        failures+=("$name: stderr '$err' !~ $want_err_re")
        return 0
    fi
    if [ "$want_rc" -eq 0 ] && ! printf '%s' "$out" | grep -qE "$ID_RE"; then
        failures+=("$name: id '$out' violates the sanitized-id grammar $ID_RE")
        return 0
    fi
    return 0
}

# 1. THE BREACH SHAPE (756-hn3a): hostname absent from PATH, HOSTNAME present
#    in the environment — exactly the failing forge process. The old prose
#    recipe wrote `forge--codex-...`; the helper must produce the COMPLETE id.
run_id_case "hostnameless-env-hostname" 0 \
    "^forge-forge-tillandsias-codex-${TS_RE}\$" - \
    TILLANDSIAS_HOST_KIND=forge HOSTNAME=forge-tillandsias TILLANDSIAS_AGENT=codex

# 2. hostname absent from PATH, HOSTNAME inherited-empty, /etc/hostname
#    present (via the fixture seam): still a complete id — the read builtin
#    needs no executable. Domain is stripped, case folded.
printf 'Forge-Tillandsias.local\n' > "$work/etc-hostname"
run_id_case "hostnameless-etc-hostname" 0 \
    "^forge-forge-tillandsias-codex-${TS_RE}\$" - \
    TILLANDSIAS_HOST_KIND=forge HOSTNAME= TILLANDSIAS_ETC_HOSTNAME="$work/etc-hostname" TILLANDSIAS_AGENT=codex

# 3. NEGATIVE CONTROL — ALL identity sources absent (no launch id, no
#    workstation env, HOSTNAME forced empty, no /etc/hostname, no executables):
#    the helper must FAIL non-zero with the exact one-line verdict and an
#    EMPTY stdout, i.e. refuse BEFORE any append-event is possible. Without
#    this scenario the positive pins could be satisfied by a helper that
#    happily emits `forge--codex-...` again.
run_id_case "all-sources-absent-refused" 1 \
    - '^refused:agent-identity:empty-workstation$' \
    TILLANDSIAS_HOST_KIND=forge HOSTNAME= TILLANDSIAS_ETC_HOSTNAME="$work/absent" TILLANDSIAS_AGENT=codex

# 4. NEGATIVE CONTROL — backend unresolvable (no argument, no
#    TILLANDSIAS_AGENT): refuse with the backend verdict, never invent a lane.
run_id_case "empty-backend-refused" 1 \
    - '^refused:agent-identity:empty-backend$' \
    TILLANDSIAS_HOST_KIND=forge HOSTNAME=forge-tillandsias

# 5. Precedence 1: an explicit TILLANDSIAS_AGENT_ID is taken WHOLE (sanitized
#    once — lowercase, [^a-z0-9-] -> '-', collapse) even when every other
#    source is absent.
run_id_case "explicit-id-taken-whole" 0 \
    '^linux-macuahuitl-claude-20260815t000000z$' - \
    HOSTNAME= TILLANDSIAS_AGENT_ID='Linux--Macuahuitl__Claude.20260815T000000Z'

# 6. NEGATIVE CONTROL — an explicit id that sanitizes to NOTHING is refused,
#    not passed through as an empty claim identity.
run_id_case "explicit-id-empty-refused" 1 \
    - '^refused:agent-identity:empty-explicit-id$' \
    HOSTNAME= TILLANDSIAS_AGENT_ID='___'

# 7. Precedence 2 beats 3: a stable launch-provided workstation outranks
#    HOSTNAME.
run_id_case "launch-workstation-wins" 0 \
    "^forge-ws-launch-codex-${TS_RE}\$" - \
    TILLANDSIAS_HOST_KIND=forge TILLANDSIAS_WORKSTATION=ws-launch HOSTNAME=other TILLANDSIAS_AGENT=codex

# 8. The explicit backend ARGUMENT outranks TILLANDSIAS_AGENT (a wrapper that
#    says who it is wins over the ambient harness type).
argout=""
argrc=0
argout="$(cd "$work/cwd" && env -i PATH="$NOPATH" TILLANDSIAS_HOST_KIND=forge HOSTNAME=forge-tillandsias TILLANDSIAS_AGENT=codex "$BASH_BIN" "$HELPER" id claude 2>"$work/err")" || argrc=$?
if [ "$argrc" -ne 0 ] || ! printf '%s' "$argout" | grep -qE "^forge-forge-tillandsias-claude-${TS_RE}\$"; then
    failures+=("backend-arg-wins: rc=$argrc out='$argout' expected ^forge-forge-tillandsias-claude-<ts>\$")
fi

# 9. Sanitize-once: hostile characters in the workstation source collapse to
#    the [a-z0-9-] grammar instead of leaking into the ledger.
run_id_case "sanitize-collapses" 0 \
    "^forge-forge-tillandsias-codex-${TS_RE}\$" - \
    TILLANDSIAS_HOST_KIND=forge HOSTNAME='Forge__Tillandsias!!' TILLANDSIAS_AGENT=codex

# 10. A bare host (no forge markers): platform resolves from bash's own
#     $OSTYPE with an empty PATH — no uname executable required.
run_id_case "bare-host-platform" 0 \
    "^(linux|macos|windows)-box-claude-${TS_RE}\$" - \
    HOSTNAME=box TILLANDSIAS_AGENT=claude

# 11. ALIGNMENT (743-mgf3): mo-full-attest.sh's host label actually flows
#     through the SHARED probe — with no hostname/uname/git in PATH and the
#     /etc/hostname seam pointed at a fixture file, `mo-full-attest.sh host`
#     must print the seam-derived label. A diverging inline copy would print
#     nothing here.
mkdir -p "$work/iso/scripts"
cp "$HELPER" "$MO_ATTEST" "$work/iso/scripts/"
printf 'Seam-Host.example\n' > "$work/iso/etc-hostname"
label="$(cd "$work/iso" && env -i PATH="$NOPATH" TILLANDSIAS_ETC_HOSTNAME="$work/iso/etc-hostname" "$BASH_BIN" scripts/mo-full-attest.sh host 2>"$work/err")" || true
if [ "$label" != "seam-host" ]; then
    failures+=("shared-probe-alignment: mo-full-attest host printed '$label', expected 'seam-host' (stderr: $(cat "$work/err" 2>/dev/null))")
fi

total=11
if [ "${#failures[@]}" -gt 0 ]; then
    printf 'FAIL: %s\n' "${failures[@]}" >&2
    echo "FAIL: agent-identity fixture ${#failures[@]}/$total scenario(s) did not match expected verdicts"
    exit 1
fi
echo "PASS: agent-identity fixture $total/$total scenarios green (hostnameless-env-hostname, hostnameless-etc-hostname, all-sources-absent-refused, empty-backend-refused, explicit-id-taken-whole, explicit-id-empty-refused, launch-workstation-wins, backend-arg-wins, sanitize-collapses, bare-host-platform, shared-probe-alignment)"
exit 0
