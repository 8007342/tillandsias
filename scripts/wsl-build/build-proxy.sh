#!/usr/bin/env bash
# scripts/wsl-build/build-proxy.sh — build the Tillandsias proxy WSL distro.
#
# @trace spec:cross-platform, spec:proxy-container
# @cheatsheet runtime/wsl-on-windows.md
#
# Replicates images/proxy/Containerfile imperatively in WSL:
#   FROM alpine:3.20
#   apk add --no-cache squid openssl bash ca-certificates
#   adduser -D -u 1000 -s /sbin/nologin proxy
#   COPY squid.conf, allowlist.txt, entrypoint.sh, external-logs.yaml
#   USER proxy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

SERVICE=proxy
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

# 1. Get the Alpine base.
base_tar=$("${SCRIPT_DIR}/bases.sh" "$ALPINE_BASE")
base_tar_win=$(to_winpath "$base_tar")

# 2. Import as a temp build distro.
wsl_import_temp "$DISTRO_TMP" "$base_tar_win"

# 3. RUN apk add --no-cache squid openssl bash ca-certificates
#    && adduser -D -u 1000 -s /sbin/nologin proxy
#    && mkdir -p /var/spool/squid /var/log/squid /var/run/squid /var/lib/squid /etc/squid/certs
#    && chown -R proxy:proxy /var/spool/squid /var/log/squid /var/run/squid /var/lib/squid
log "installing packages and creating proxy user"
wsl_run_in "$DISTRO_TMP" '
set -eux
apk update
apk add --no-cache squid openssl bash ca-certificates
adduser -D -u 1000 -s /sbin/nologin proxy
mkdir -p /var/spool/squid /var/log/squid /var/run/squid /var/lib/squid /etc/squid/certs
chown -R proxy:proxy /var/spool/squid /var/log/squid /var/run/squid /var/lib/squid
'

# 4. COPY squid.conf, allowlist.txt, entrypoint.sh, external-logs.yaml
log "copying image files"
wsl_copy_into "$DISTRO_TMP" "${TILL_REPO_ROOT}/images/proxy/squid.conf" "/etc/squid/squid.conf"
wsl_copy_into "$DISTRO_TMP" "${TILL_REPO_ROOT}/images/proxy/allowlist.txt" "/etc/squid/allowlist.txt"
wsl_copy_into "$DISTRO_TMP" "${TILL_REPO_ROOT}/images/proxy/entrypoint.sh" "/usr/local/bin/entrypoint.sh"
wsl_copy_into "$DISTRO_TMP" "${TILL_REPO_ROOT}/images/proxy/external-logs.yaml" "/etc/tillandsias/external-logs.yaml"
wsl_run_in "$DISTRO_TMP" 'chmod +x /usr/local/bin/entrypoint.sh'

# 5. Cleanup apk cache to shrink the tarball.
wsl_run_in "$DISTRO_TMP" 'rm -rf /var/cache/apk/* /tmp/* 2>/dev/null || true'

# 6. Export the result.
mkdir -p "$(dirname "$OUT_TAR")"
wsl_export_and_unregister "$DISTRO_TMP" "$OUT_TAR_WIN"

# 7. Sidecar metadata: tray reads this to know which user to run as
#    and what port to expect.
write_meta "$SERVICE" "proxy" 1000 3128

log "DONE: ${OUT_TAR}"
ls -lh "$OUT_TAR" >&2
