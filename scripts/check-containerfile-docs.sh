#!/usr/bin/env bash
# @trace spec:enclave-compose-migration
#
# Asserts that every service defined in compose.yaml has a spec README
# at src-tauri/assets/compose/services/<service>/README.md, and that each
# README contains the mandated section headers from design.md §3.
#
# Wired into build.sh --test.
#
# Exit codes:
#   0 — all READMEs present and well-formed
#   1 — at least one missing README or missing section header
#   2 — usage / missing files

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="$ROOT/src-tauri/assets/compose"
COMPOSE_FILE="$COMPOSE_DIR/compose.yaml"
SERVICES_DIR="$COMPOSE_DIR/services"

VIOLATIONS=0

_fail() {
    echo "[check-containerfile-docs] VIOLATION: $*" >&2
    VIOLATIONS=$((VIOLATIONS + 1))
}

_pass() {
    echo "[check-containerfile-docs] OK: $*"
}

if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "[check-containerfile-docs] error: $COMPOSE_FILE not found" >&2
    exit 2
fi

# Mandated section headers (from design.md §3 "Per-Containerfile spec contract").
REQUIRED_HEADERS=(
    "## Purpose"
    "## Base image"
    "## Build args"
    "## Layers"
    "## Security posture"
    "## Volume contract"
    "## Env contract"
    "## Healthcheck"
    "## Compose service block"
    "## Trace anchors"
)

# Extract the four service names from compose.yaml. Match lines with
# exactly two-space indent immediately under the top-level `services:`
# key.
SERVICES=()
in_services=0
while IFS= read -r line; do
    if [[ "$line" =~ ^services:[[:space:]]*$ ]]; then
        in_services=1
        continue
    fi
    if [[ $in_services -eq 1 ]]; then
        # Top-level key reached — stop.
        if [[ "$line" =~ ^[a-zA-Z_-]+:[[:space:]]*$ ]]; then
            break
        fi
        if [[ "$line" =~ ^[[:space:]]{2}([a-zA-Z_-]+):[[:space:]]*$ ]]; then
            SERVICES+=("${BASH_REMATCH[1]}")
        fi
    fi
done < "$COMPOSE_FILE"

if [[ ${#SERVICES[@]} -eq 0 ]]; then
    _fail "no services found in compose.yaml (parser regression?)"
    exit 1
fi

echo "[check-containerfile-docs] services discovered: ${SERVICES[*]}"

# For each service, check README presence and section headers.
for svc in "${SERVICES[@]}"; do
    readme="$SERVICES_DIR/$svc/README.md"
    if [[ ! -f "$readme" ]]; then
        _fail "service '$svc' has no README at $readme"
        continue
    fi

    missing_headers=()
    for header in "${REQUIRED_HEADERS[@]}"; do
        # Match header at start of line, followed by either EOL or
        # whitespace+subtitle (e.g. "## Layers (cache-ordered, top to bottom)").
        # Escape regex metachars from the header text (none in practice but
        # robust against future additions).
        if ! grep -qE "^${header}([[:space:]]|\$)" "$readme"; then
            missing_headers+=("$header")
        fi
    done

    if [[ ${#missing_headers[@]} -gt 0 ]]; then
        _fail "service '$svc' README missing headers: ${missing_headers[*]}"
    else
        _pass "service '$svc' README has all required sections"
    fi
done

# Summary.
echo
if [[ $VIOLATIONS -eq 0 ]]; then
    echo "[check-containerfile-docs] All per-service READMEs present and well-formed."
    exit 0
else
    echo "[check-containerfile-docs] $VIOLATIONS violation(s) found." >&2
    exit 1
fi
