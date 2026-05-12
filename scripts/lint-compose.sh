#!/usr/bin/env bash
# @trace spec:enclave-compose-migration, spec:enclave-network, spec:forge-offline
#
# Static lint for src-tauri/assets/compose/compose.yaml and the dev/local
# overlays. Asserts the non-negotiable security and network rules of the
# Tillandsias enclave so that hand edits to the YAML cannot silently weaken
# isolation. Wired into build.sh --test.
#
# Rules enforced (per service / network):
#   1. Every service declares `cap_drop: [ALL]`
#   2. Every service declares `no-new-privileges` under `security_opt`
#   3. Every service declares `userns_mode: keep-id`
#   4. forge / git / inference are on `enclave` and NOT on `egress`
#   5. proxy is on BOTH `enclave` and `egress`
#   6. Top-level `enclave` network has `internal: true`
#   7. All three top-level secrets declare `external: true`
#
# Exit codes:
#   0 — all rules pass
#   1 — at least one violation; details printed to stderr
#   2 — usage / missing files

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="$ROOT/src-tauri/assets/compose"
COMPOSE_FILE="$COMPOSE_DIR/compose.yaml"

VIOLATIONS=0

_fail() {
    echo "[lint-compose] VIOLATION: $*" >&2
    VIOLATIONS=$((VIOLATIONS + 1))
}

_pass() {
    echo "[lint-compose] OK: $*"
}

if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "[lint-compose] error: $COMPOSE_FILE not found" >&2
    exit 2
fi

# Services that MUST exist in compose.yaml.
SERVICES=(forge proxy git inference)

# Extract a service block by reading from "^  <name>:" until the next
# top-level service indent or EOF.
_extract_service_block() {
    local svc="$1"
    awk -v svc="$svc" '
        $0 ~ "^  "svc":[[:space:]]*$" { in_block = 1; print; next }
        in_block && /^  [a-zA-Z_-]+:[[:space:]]*$/ { exit }
        in_block { print }
    ' "$COMPOSE_FILE"
}

# ── Rule 1-3: per-service security flags ──────────────────────────
for svc in "${SERVICES[@]}"; do
    block="$(_extract_service_block "$svc")"
    if [[ -z "$block" ]]; then
        _fail "service '$svc' not found in compose.yaml"
        continue
    fi

    # cap_drop: [ALL]
    if ! echo "$block" | grep -qE '^[[:space:]]+cap_drop:[[:space:]]*\[ALL\]'; then
        _fail "service '$svc' missing 'cap_drop: [ALL]'"
    else
        _pass "service '$svc' has cap_drop: [ALL]"
    fi

    # no-new-privileges under security_opt
    if ! echo "$block" | grep -qE '^[[:space:]]+-[[:space:]]+no-new-privileges'; then
        _fail "service '$svc' missing 'no-new-privileges' in security_opt"
    else
        _pass "service '$svc' has no-new-privileges"
    fi

    # userns_mode: keep-id
    if ! echo "$block" | grep -qE '^[[:space:]]+userns_mode:[[:space:]]+keep-id'; then
        _fail "service '$svc' missing 'userns_mode: keep-id'"
    else
        _pass "service '$svc' has userns_mode: keep-id"
    fi
done

# ── Rule 4-5: network topology ────────────────────────────────────
# Extract each service's "networks:" list block (the list immediately
# under `networks:` until indentation drops). Lighter than a full YAML
# walk; relies on the canonical 2-space indent we author with.
# Returns a space-separated list of attached network names for $svc,
# tolerant of inline YAML comments after the entry.
_attached_networks() {
    local svc="$1"
    _extract_service_block "$svc" | awk '
        /^[[:space:]]+networks:[[:space:]]*$/ { in_list = 1; next }
        in_list && /^[[:space:]]+-[[:space:]]+/ {
            line = $0
            sub(/[[:space:]]*#.*$/, "", line)        # strip inline comment
            sub(/^[[:space:]]+-[[:space:]]+/, "", line)
            gsub(/[[:space:]]+$/, "", line)
            print line
            next
        }
        in_list { exit }
    '
}

_has_net() {
    # $1 = newline-separated list, $2 = name to test
    echo "$1" | grep -qFx "$2"
}

# forge / git / inference: enclave only
for svc in forge git inference; do
    nets="$(_attached_networks "$svc")"
    if [[ -z "$nets" ]]; then
        _fail "service '$svc' has no networks list (or it is malformed)"
        continue
    fi
    if _has_net "$nets" egress; then
        _fail "service '$svc' is attached to 'egress' — must be enclave-only"
    fi
    if ! _has_net "$nets" enclave; then
        _fail "service '$svc' is NOT attached to 'enclave'"
    fi
    if _has_net "$nets" enclave && ! _has_net "$nets" egress; then
        _pass "service '$svc' networks: enclave only"
    fi
done

# proxy: both enclave and egress
proxy_nets="$(_attached_networks proxy)"
if ! _has_net "$proxy_nets" enclave; then
    _fail "service 'proxy' is NOT attached to 'enclave'"
fi
if ! _has_net "$proxy_nets" egress; then
    _fail "service 'proxy' is NOT attached to 'egress' — proxy MUST be on egress"
fi
if _has_net "$proxy_nets" enclave && _has_net "$proxy_nets" egress; then
    _pass "service 'proxy' networks: enclave + egress"
fi

# ── Rule 6: top-level enclave network internal: true ──────────────
if awk '
    /^networks:[[:space:]]*$/ { in_net = 1; next }
    in_net && /^[a-zA-Z_-]+:[[:space:]]*$/ { exit }
    in_net && /^[[:space:]]+enclave:[[:space:]]*$/ { in_enclave = 1; next }
    in_enclave && /^[[:space:]]+[a-zA-Z_-]+:[[:space:]]*$/ { exit }
    in_enclave && /^[[:space:]]+internal:[[:space:]]+true/ { found = 1 }
    END { exit !found }
' "$COMPOSE_FILE"; then
    _pass "network 'enclave' has internal: true"
else
    _fail "network 'enclave' missing 'internal: true'"
fi

# ── Rule 7: secrets external: true ────────────────────────────────
for secret in tillandsias-github-token tillandsias-ca-cert tillandsias-ca-key; do
    if awk -v s="$secret" '
        /^secrets:[[:space:]]*$/ { in_sec = 1; next }
        in_sec && /^[a-zA-Z_-]+:[[:space:]]*$/ { exit }
        in_sec && $0 ~ "^[[:space:]]+"s":[[:space:]]*$" { in_block = 1; next }
        in_block && /^[[:space:]]+[a-zA-Z_-]+:[[:space:]]*$/ { exit }
        in_block && /^[[:space:]]+external:[[:space:]]+true/ { found = 1 }
        END { exit !found }
    ' "$COMPOSE_FILE"; then
        _pass "secret '$secret' is external: true"
    else
        _fail "secret '$secret' missing 'external: true'"
    fi
done

# ── Summary ───────────────────────────────────────────────────────
echo
if [[ $VIOLATIONS -eq 0 ]]; then
    echo "[lint-compose] All rules pass."
    exit 0
else
    echo "[lint-compose] $VIOLATIONS violation(s) found." >&2
    exit 1
fi
