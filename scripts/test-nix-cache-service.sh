#!/usr/bin/env bash
# @trace order:801-kqme, spec:nix-cache-service
#
# test-nix-cache-service.sh — behavioural fixture for the enclave nix binary
# cache (scripts/nix-cache-service.sh).
#
# WHAT THIS PINS, and why each one is here rather than being assumed:
#
#   1-2 keypair identity is STABLE. A cache whose signing key rotates on every
#       ensure invalidates every client's trusted-public-keys and silently
#       degrades to "nothing verifies".
#   3-4 TRANSPORT is real. The leaf must chain to the STACK CA, and a client
#       without that CA must FAIL. Scenario 4 is the one that would go vacuous
#       first: if the service ever fell back to plain HTTP, a test that only
#       asserted "curl --cacert works" would still pass, because curl ignores
#       --cacert on an http:// URL. So 4 asserts the NEGATIVE directly.
#   5   ENCLAVE reachability by DNS name, from a container holding NO host
#       mount. This is the whole point of the packet: warm cache WITHOUT
#       punching a host path through the forge boundary.
#   6-7 CONTENT signing is real and ENFORCED. 6 substitutes into a throwaway
#       store with the right key; 7 is the mutation control — same bytes, same
#       server, WRONG key — and must be refused by nix itself.
#   8   A DOWN cache must emit NO substituter flags. A dead substituter in a
#       build's flag list is worse than none: nix retries it per path.
#
# Scenario 7 deliberately goes through `nix copy` rather than inspecting the
# narinfo text, because the property under test is "nix REFUSES", not "a Sig:
# line is present". An assertion that only grepped for a signature would pass
# against a server that signed with a key nobody trusts.
#
# GRAMMAR (exactly one line on stdout)
#   ok:nix-cache-fixture:<passed>/<total>
#   skip:nix-cache-fixture:<no-nix|no-store|no-podman|no-ca|service-down>
#   violation:nix-cache-fixture:<passed>/<total>:failed=<n,n>
#
# Exit 0 when every scenario passes or the fixture skips, 1 on violation.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVC="$ROOT/scripts/nix-cache-service.sh"
STATE_DIR="${TILLANDSIAS_NIX_CACHE_STATE:-$HOME/.local/share/tillandsias/nix-cache}"
CA_DIR="${TILLANDSIAS_CA_DIR:-/tmp/tillandsias-ca}"
CHROOT_STORE="${TILLANDSIAS_NIX_CHROOT_STORE:-$HOME/.local/share/tillandsias/nix-store}"
HOST_PORT="${TILLANDSIAS_NIX_CACHE_HOST_PORT:-5111}"
ENCLAVE_NET="${TILLANDSIAS_ENCLAVE_NET:-tillandsias-enclave}"
BASE_IMAGE="${TILLANDSIAS_NIX_CACHE_BASE_IMAGE:-registry.fedoraproject.org/fedora-minimal:44}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/nix-cache-fixture.XXXXXX")"
cleanup() { chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP" 2>/dev/null; }
trap cleanup EXIT

# THE NARINFO CACHE WILL MAKE THIS FIXTURE LIE IF YOU LET IT.
#
# nix keeps a client-side narinfo cache (~/.cache/nix/binary-cache-v7.sqlite)
# keyed by substituter URL, and `narinfo-cache-positive-ttl` defaults to 30
# DAYS. Measured on macuahuitl 2026-08-17 while mutation-testing this file:
# with signing switched OFF on the server, a copy from the same URL still
# returned rc=0 and 7 paths, because nix replayed a narinfo captured while the
# server was still signing. The same copy with a fresh XDG_CACHE_HOME, or with
# positive-ttl 0, correctly failed rc=1 with 0 paths.
#
# So the first draft of scenarios 6 and 7 PASSED against a server that had
# stopped signing entirely — a vacuous test that would have shipped as proof of
# a property it never checked. Both the TTL override and the private
# XDG_CACHE_HOME below are load-bearing; do not "simplify" either away.
NIX_NOCACHE=(--option narinfo-cache-positive-ttl 0 --option narinfo-cache-negative-ttl 0)
export XDG_CACHE_HOME="$TMP/xdg"
mkdir -p "$XDG_CACHE_HOME"

_podman() { env http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= podman "$@"; }

# CAPABILITY, NOT `command -v nix` ON THE HOST — the FIFTH instance of the
# 799-tb7q defect in this lane (after check-nix-deps-stability.sh,
# select-work-batch.sh, check-nix-builder-e2e.sh and nix-cache-service.sh).
#
# FOUND WHILE ANSWERING AN OPERATOR QUESTION, which is the part worth recording:
# the operator asked whether every host uses the nix-cache container. On
# lenovinha 2026-08-30 the service was RUNNING
# (ok:nix-cache-status:running:endpoint=https://nix-cache:5000) with a populated
# store (5715 paths, 8G) — and THIS FIXTURE, the evidence that would prove it,
# printed skip:nix-cache-fixture:no-nix and exited 0. A host with no host-nix
# binary but a working toolbox rung produced a green skip where the truth was
# "yes, and here are the numbers". The adoption evidence was missing for a
# reason that was not true.
_ncf_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$_ncf_dir/nix-toolbox.sh" capability >/dev/null 2>&1     || { echo "skip:nix-cache-fixture:no-nix"; exit 0; }

# And the ARMS must use the same rung the gate just proved. Converting only the
# gate turned a false green skip into two rc=127 failures — `nix` is not on this
# host's PATH at all — which is more honest but still not a test. Both halves
# have to move together: a gate that admits a host the body cannot run on has
# only relocated the lie.
_NCF_RUNG="$(bash "$_ncf_dir/nix-toolbox.sh" capability 2>/dev/null)"
_NCF_RUNG="${_NCF_RUNG#ok:nix-capability:}"
_ncf_nix() {
    if [ "$_NCF_RUNG" = "toolbox" ]; then
        bash "$_ncf_dir/nix-toolbox.sh" run -- nix "$@"
    else
        nix "$@"
    fi
}
command -v podman >/dev/null 2>&1  || { echo "skip:nix-cache-fixture:no-podman"; exit 0; }
[ -d "$CHROOT_STORE/nix/store" ]   || { echo "skip:nix-cache-fixture:no-store"; exit 0; }
[ -s "$CA_DIR/intermediate.crt" ]  || { echo "skip:nix-cache-fixture:no-ca"; exit 0; }
# SKIP ONLY WHEN THE SERVICE IS GENUINELY NOT THERE.
#
# The obvious gate here is `nix-cache-service.sh status | grep running`, and it
# is WRONG: `status` reports `running` only when its own HTTPS probe succeeds
# against the stack CA. So a service that is up but serving a cert we do not
# trust reports "stopped", and this fixture would SKIP — going quiet at exactly
# the moment transport trust is broken. Caught by mutation control M2 on
# 2026-08-17: a leaf re-minted from a rogue CA turned the whole fixture into
# `skip:service-down` instead of a violation.
#
# So the skip gate asks podman whether the container is RUNNING, which is a
# fact independent of every property under test. If it is running, we assert;
# any trust failure is then a violation and not a shrug.
[ "$(_podman inspect -f '{{.State.Running}}' \
      "${TILLANDSIAS_NIX_CACHE_CONTAINER:-tillandsias-nix-cache}" 2>/dev/null)" = "true" ] \
    || { echo "skip:nix-cache-fixture:service-down"; exit 0; }

PUBKEY="$("$SVC" pubkey 2>/dev/null)"
BUNDLE="$STATE_DIR/ca-bundle.crt"

# A plain string accumulator, not an array: under `set -u`, bash 3.2 (the
# declared floor) errors on ${arr[*]} when the array is empty — which is the
# ALL-PASSING case, so the fixture would fail exactly when nothing is wrong.
total=0; passed=0; failed=""
check() { # check <n> <description> <0|1 result>
    total=$((total + 1))
    if [ "$3" -eq 0 ]; then
        passed=$((passed + 1))
    else
        if [ -z "$failed" ]; then failed="$1"; else failed="$failed,$1"; fi
        echo "  FAIL $1: $2" >&2
    fi
}

# --- 1. keygen is idempotent: a second call reports `present` -----------------
out1="$("$SVC" keygen 2>/dev/null)"
case "$out1" in ok:nix-cache-key:present:*) r=0 ;; *) r=1 ;; esac
check 1 "keygen on an existing key reports present (got: $out1)" "$r"

# --- 2. ...and the public key is unchanged ------------------------------------
pub2="$("$SVC" pubkey 2>/dev/null)"
[ -n "$PUBKEY" ] && [ "$pub2" = "$PUBKEY" ]; check 2 "pubkey is stable across calls" "$?"

# --- 3. TLS leaf chains to the STACK CA ---------------------------------------
openssl verify -CAfile "$CA_DIR/intermediate.crt" "$STATE_DIR/nix-cache.crt" >/dev/null 2>&1
check 3 "TLS leaf verifies against the stack CA" "$?"

# --- 4. MUTATION-RESISTANT: a client WITHOUT the stack CA must be refused -----
# If the service degraded to plain HTTP this fails, which is the point.
curl -sS -m 8 "https://127.0.0.1:${HOST_PORT}/nix-cache-info" >/dev/null 2>&1
if [ "$?" -ne 0 ]; then r=0; else r=1; fi
check 4 "a client without the stack CA cannot complete the TLS handshake" "$r"

# --- 5. in-enclave reachability by DNS name, with NO host mount ---------------
enc="$(_podman run --rm --network "$ENCLAVE_NET" \
        --security-opt label=disable \
        -v "$CA_DIR/intermediate.crt:/ca.crt:ro" \
        -e NO_PROXY=nix-cache -e no_proxy=nix-cache \
        "$BASE_IMAGE" \
        /bin/sh -c 'curl -sS -m 15 --cacert /ca.crt https://nix-cache:5000/nix-cache-info' 2>/dev/null)"
printf '%s' "$enc" | grep -q '^StoreDir: /nix/store'
check 5 "an enclave container reaches https://nix-cache:5000 by DNS with no host mount" "$?"

# Pick a target that is definitely in the served store: the pinned harmonia.
TARGET="$(readlink "$CHROOT_STORE/nix/var/nix/gcroots/tillandsias/nix-cache-harmonia" 2>/dev/null)"

# --- 6. POSITIVE: an empty store substitutes with the correct key -------------
if [ -n "$TARGET" ]; then
    mkdir -p "$TMP/pos"
    _ncf_nix --extra-experimental-features "nix-command flakes" copy \
        --from "https://127.0.0.1:${HOST_PORT}" --to "$TMP/pos" \
        --option require-sigs true \
        --option trusted-public-keys "$PUBKEY" \
        --option ssl-cert-file "$BUNDLE" \
        "${NIX_NOCACHE[@]}" \
        "$TARGET" >"$TMP/pos.log" 2>&1
    rc=$?
    n="$(ls "$TMP/pos/nix/store" 2>/dev/null | grep -c .)"
    [ "$rc" -eq 0 ] && [ "$n" -gt 0 ]
    check 6 "an empty store substitutes from the cache (rc=$rc paths=$n)" "$?"
else
    check 6 "pinned harmonia root resolvable" 1
fi

# --- 7. MUTATION CONTROL: the same fetch with a WRONG key must be REFUSED -----
# Non-vacuous: this fails inside nix's signature verification, not in our code.
if [ -n "$TARGET" ]; then
    nix-store --generate-binary-cache-key bogus-not-our-cache \
        "$TMP/bad.sec" "$TMP/bad.pub" >/dev/null 2>&1
    mkdir -p "$TMP/neg"
    _ncf_nix --extra-experimental-features "nix-command flakes" copy \
        --from "https://127.0.0.1:${HOST_PORT}" --to "$TMP/neg" \
        --option require-sigs true \
        --option trusted-public-keys "$(cat "$TMP/bad.pub")" \
        --option ssl-cert-file "$BUNDLE" \
        "${NIX_NOCACHE[@]}" \
        "$TARGET" >"$TMP/neg.log" 2>&1
    rc=$?
    n="$(ls "$TMP/neg/nix/store" 2>/dev/null | grep -c .)"
    if [ "$rc" -ne 0 ] && [ "$n" -eq 0 ] && grep -q 'lacks a signature by a trusted key' "$TMP/neg.log"; then
        r=0
    else
        r=1
    fi
    check 7 "an untrusted key is refused by nix signature verification (rc=$rc paths=$n)" "$r"
else
    check 7 "pinned harmonia root resolvable" 1
fi

# --- 8. substituter-args is SILENT when the cache is not answering ------------
# Point the probe at a port nothing listens on; the command must emit nothing.
args="$(TILLANDSIAS_NIX_CACHE_HOST_PORT=1 "$SVC" substituter-args 2>/dev/null)"
[ -z "$args" ]; check 8 "substituter-args emits nothing when the cache is unreachable" "$?"

if [ -z "$failed" ]; then
    echo "ok:nix-cache-fixture:${passed}/${total}"
    exit 0
fi
echo "violation:nix-cache-fixture:${passed}/${total}:failed=${failed}"
exit 1
