#!/usr/bin/env bash
# 1955-chrn: a podman build argv never pairs --isolation chroot with a network
# other than host. podman refuses that pair outright ("cannot set --network
# other than host with --isolation chroot"), and chroot is build-image.sh's
# default, so 1955-hq7k's unconditional --network=private failed every image
# build (mirror-sshd-posture-shape and mirror-host-cert-and-sshd-shape went red
# in the v56.11.3.1 release gate).
#
# Arms:
#   1. chroot -> build_network_args prints nothing
#   2. oci    -> build_network_args prints --network=private (the 1955-hq7k fix kept)
#   3. STATIC -> build-image.sh adds no --network of its own outside the helper,
#                and resolves BUILD_ISOLATION before it asks the helper
#   PASS: build-network-isolation 3/3
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib/build-network.sh"
BI="$ROOT/scripts/build-image.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok:   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

if [ -r "$LIB" ] && . "$LIB" && declare -F build_network_args >/dev/null; then
    out="$(build_network_args chroot)"
    if [ -z "$out" ]; then ok "ARM 1: chroot builds carry no --network"
    else bad "ARM 1: chroot builds carry '$out' (podman refuses it)"; fi
    out="$(build_network_args oci)"
    if [ "$out" = "--network=private" ]; then ok "ARM 2: oci builds keep --network=private"
    else bad "ARM 2: oci builds carry '$out', expected --network=private"; fi
else
    bad "ARM 1: no build_network_args in scripts/lib/build-network.sh"
    bad "ARM 2: no build_network_args in scripts/lib/build-network.sh"
fi

iso_line="$(grep -n '^BUILD_ISOLATION=' "$BI" | head -n 1 | cut -d: -f1)"
use_line="$(grep -n 'build_network_args "\$BUILD_ISOLATION"' "$BI" | head -n 1 | cut -d: -f1)"
raw="$(grep -nE -- '--network' "$BI" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
if [ -n "$iso_line" ] && [ -n "$use_line" ] && [ "$iso_line" -lt "$use_line" ] && [ -z "$raw" ]; then
    ok "ARM 3: build-image.sh takes its build network only from the helper, after BUILD_ISOLATION"
else
    bad "ARM 3: build-image.sh sets a build network outside the helper or before BUILD_ISOLATION (iso=$iso_line use=$use_line raw=${raw:-none})"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then echo "PASS: build-network-isolation $pass/$total"; exit 0; fi
echo "FAIL: build-network-isolation $pass/$total"; exit 1
