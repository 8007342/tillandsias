#!/usr/bin/env bash
# @trace spec:git-mirror-service
# Negative two-project DNS fixture for order 659-8faj.
#
# Before 659-8faj, build_git_run_args assigned two CONSTANT network aliases
# (`git-service`, `tillandsias-git`) to EVERY project's mirror. With two
# projects up, one name had two A records and podman's resolver handed out
# either — cross-project, non-deterministic routing (measured 2026-08-10,
# plan/issues/mirror-identity-is-a-shared-dns-alias-audit-2026-08-10.md).
#
# This fixture starts two plain containers carrying the product's EXACT
# alias/hostname args (the aliases and the resolver are the whole mechanism —
# no daemon or volume needed for the DNS claim) and asserts the fixed
# property:
#   1. each project-unique name (git-<project>) returns exactly ONE address;
#   2. the two projects resolve to DIFFERENT addresses;
#   3. the retired shared aliases (tillandsias-git, git-service) do NOT
#      resolve at all.
#
# Instrument note (from the audit): use `getent ahostsv4`, NEVER nslookup —
# nslookup fails against the podman resolver with "Message too large" and
# returns nothing, which reads as NXDOMAIN and is the opposite of a finding.
#
# Runs on tillandsias-enclave by default. If a pre-659 mirror is still
# attached there (its shared alias resolves before the fixture starts
# anything), the fixture falls back to a dedicated network so it measures the
# product's CURRENT launch args rather than the host's stale containers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
require_podman
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

DEFAULT_VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
IMAGE="${1:-localhost/tillandsias-git:v${DEFAULT_VERSION}}"
NET="${TILLANDSIAS_DNS_FIXTURE_NET:-tillandsias-enclave}"
FALLBACK_NET="tillandsias-git-dns-fixture"
PROJ_A="dnsfixa"
PROJ_B="dnsfixb"

CREATED_NET=""
cleanup() {
    podman rm -f "tillandsias-git-${PROJ_A}" "tillandsias-git-${PROJ_B}" >/dev/null 2>&1 || true
    if [ -n "$CREATED_NET" ]; then
        podman network rm "$CREATED_NET" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

fail() {
    echo "[dns-identity] FAIL: $*" >&2
    exit 1
}

# Probe helper: run getent ahostsv4 <name> from a throwaway container on $NET.
resolve() {
    podman run --rm --network "$NET" --entrypoint /bin/sh "$IMAGE" \
        -c "getent ahostsv4 '$1'" 2>/dev/null || true
}

if ! podman network exists "$NET" 2>/dev/null; then
    echo "[dns-identity] network $NET absent; creating (internal, like the product's)"
    podman network create --internal "$NET" >/dev/null
    CREATED_NET="$NET"
fi

# Interference check: a mirror launched by a pre-659 binary still carries the
# shared aliases. Its presence would fail assertion 3 for reasons outside this
# fixture's control, so measure on a dedicated network instead.
if [ -n "$(resolve tillandsias-git)$(resolve git-service)" ]; then
    echo "[dns-identity] NOTE: a pre-659 shared mirror alias already resolves on $NET" >&2
    echo "[dns-identity] (stale container from an old binary); using dedicated network $FALLBACK_NET" >&2
    NET="$FALLBACK_NET"
    if ! podman network exists "$NET" 2>/dev/null; then
        podman network create --internal "$NET" >/dev/null
        CREATED_NET="$NET"
    fi
fi

echo "[dns-identity] network: $NET, image: $IMAGE"

# Start two "mirrors" carrying the product's exact identity args
# (build_git_run_args: --name tillandsias-git-<p> --hostname git-<p>
#  --network-alias git-<p>). Plain sleep, no daemon: DNS is the mechanism
# under test.
for p in "$PROJ_A" "$PROJ_B"; do
    podman rm -f "tillandsias-git-${p}" >/dev/null 2>&1 || true
    podman run -d --rm \
        --name "tillandsias-git-${p}" \
        --hostname "git-${p}" \
        --network-alias "git-${p}" \
        --network "$NET" \
        --entrypoint /bin/sleep \
        "$IMAGE" 300 >/dev/null
done

# Assertion 1+2: each project-unique name resolves to exactly one address,
# and the two projects' addresses differ.
out_a="$(resolve "git-${PROJ_A}")"
out_b="$(resolve "git-${PROJ_B}")"
echo "[dns-identity] getent ahostsv4 git-${PROJ_A}:"
echo "${out_a:-<no answer>}" | sed 's/^/    /'
echo "[dns-identity] getent ahostsv4 git-${PROJ_B}:"
echo "${out_b:-<no answer>}" | sed 's/^/    /'

addr_a="$(printf '%s\n' "$out_a" | awk 'NF {print $1}' | sort -u)"
addr_b="$(printf '%s\n' "$out_b" | awk 'NF {print $1}' | sort -u)"
[ -n "$addr_a" ] || fail "git-${PROJ_A} did not resolve"
[ -n "$addr_b" ] || fail "git-${PROJ_B} did not resolve"
[ "$(printf '%s\n' "$addr_a" | wc -l)" -eq 1 ] || \
    fail "git-${PROJ_A} returned multiple addresses: $addr_a"
[ "$(printf '%s\n' "$addr_b" | wc -l)" -eq 1 ] || \
    fail "git-${PROJ_B} returned multiple addresses: $addr_b"
[ "$addr_a" != "$addr_b" ] || \
    fail "both project names resolved to the same address $addr_a"

# Assertion 3: the retired shared aliases must not resolve (NXDOMAIN) — with
# per-project identities, no container answers to them.
for shared in tillandsias-git git-service; do
    out_shared="$(resolve "$shared")"
    if [ -n "$out_shared" ]; then
        fail "retired shared alias $shared still resolves: $out_shared"
    fi
    echo "[dns-identity] getent ahostsv4 $shared: <no answer> (NXDOMAIN, as required)"
done

echo "[dns-identity] PASS: one A record per project-unique mirror name; shared aliases retired"
