#!/usr/bin/env bash
# scripts/wsl-build/build-enclave-init.sh — smallest distro: Alpine + iptables.
#
# @trace spec:cross-platform, spec:forge-offline
# @cheatsheet runtime/wsl-on-windows.md
#
# enclave-init runs ONCE at WSL VM cold-boot (registered via [boot] command
# in its wsl.conf). It applies the uid-based iptables egress drop in the
# shared netns, then exits. The rules persist for as long as the WSL VM
# lives. See openspec/specs/forge-offline (delta in this change).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

SERVICE=enclave-init
ALPINE_BASE="alpine-3.20"
DISTRO_TMP="tillandsias-build-${SERVICE}"
OUT_TAR="${TILL_WSL_OUT}/tillandsias-${SERVICE}.tar"
OUT_TAR_WIN=$(to_winpath "$OUT_TAR")

cleanup() {
    if [[ "$TILL_HAS_WSL" == 1 ]]; then
        wsl_unregister_quiet "$DISTRO_TMP" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

base_tar=$("${SCRIPT_DIR}/bases.sh" "$ALPINE_BASE")
base_tar_win=$(to_winpath "$base_tar")

wsl_import_temp "$DISTRO_TMP" "$base_tar_win"

log "installing iptables + writing apply-egress-rules.sh"
wsl_run_in "$DISTRO_TMP" '
set -eux
apk update
apk add --no-cache iptables ip6tables
mkdir -p /etc/tillandsias /usr/local/sbin

cat > /usr/local/sbin/apply-egress-rules.sh <<EOF
#!/bin/sh
# @trace spec:forge-offline
# Layer 1 of forge-offline: uid-based iptables egress drop in the
# shared WSL2 network namespace. Forge agents always run as a uid in
# 2000-2999. proxy/git/inference/router run outside that range.
set -eux
# Idempotent: flush our chain first if it already exists, then re-apply.
iptables -F TILLANDSIAS_FORGE_EGRESS 2>/dev/null || iptables -N TILLANDSIAS_FORGE_EGRESS
iptables -F TILLANDSIAS_FORGE_EGRESS

# Allow loopback (proxy, git, inference, router live on 127.0.0.1).
iptables -A TILLANDSIAS_FORGE_EGRESS -d 127.0.0.0/8 -j ACCEPT
# Drop everything else for the forge uid range.
iptables -A TILLANDSIAS_FORGE_EGRESS -j DROP

# Hook the chain into OUTPUT scoped to forge uid range, exactly once.
if ! iptables -C OUTPUT -m owner --uid-owner 2000-2999 -j TILLANDSIAS_FORGE_EGRESS 2>/dev/null; then
    iptables -A OUTPUT -m owner --uid-owner 2000-2999 -j TILLANDSIAS_FORGE_EGRESS
fi

echo "tillandsias forge-offline egress rules applied"
EOF
chmod +x /usr/local/sbin/apply-egress-rules.sh

# wsl.conf: run apply-egress-rules.sh at cold boot.
cat > /etc/wsl.conf <<EOF
[boot]
command = /usr/local/sbin/apply-egress-rules.sh
EOF
'

wsl_run_in "$DISTRO_TMP" 'rm -rf /var/cache/apk/* /tmp/* 2>/dev/null || true'

mkdir -p "$(dirname "$OUT_TAR")"
wsl_export_and_unregister "$DISTRO_TMP" "$OUT_TAR_WIN"

# enclave-init has no service port; run as root because iptables needs CAP_NET_ADMIN.
write_meta "$SERVICE" "root" 0 0

log "DONE: ${OUT_TAR}"
ls -lh "$OUT_TAR" >&2
