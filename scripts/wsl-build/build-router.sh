#!/usr/bin/env bash
# scripts/wsl-build/build-router.sh — build the Tillandsias router WSL distro.
#
# @trace spec:cross-platform, spec:subdomain-routing-via-reverse-proxy
# @cheatsheet runtime/wsl-on-windows.md
#
# Replicates images/router/Containerfile:
#   FROM caddy:2-alpine  (substituted with alpine:3.20 + apk add caddy)
#   apk add --no-cache curl libcap
#   setcap -r /usr/bin/caddy   (drop file capabilities)
#   COPY base.Caddyfile, entrypoint.sh, router-reload.sh,
#        tillandsias-router-sidecar, external-logs.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

SERVICE=router
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

# Pre-flight: the sidecar binary must exist. build-sidecar.sh produces it.
SIDECAR="${TILL_REPO_ROOT}/images/router/tillandsias-router-sidecar"
if [[ ! -x "$SIDECAR" && ! -f "$SIDECAR" ]]; then
    log "tillandsias-router-sidecar missing; running scripts/build-sidecar.sh"
    bash "${TILL_REPO_ROOT}/scripts/build-sidecar.sh"
fi
[[ -f "$SIDECAR" ]] || die "router sidecar binary still missing at $SIDECAR"

base_tar=$("${SCRIPT_DIR}/bases.sh" "$ALPINE_BASE")
base_tar_win=$(to_winpath "$base_tar")

wsl_import_temp "$DISTRO_TMP" "$base_tar_win"

log "installing caddy + curl + libcap, dropping caddy file caps"
wsl_run_in "$DISTRO_TMP" '
set -eux
apk update
apk add --no-cache caddy curl libcap
# Drop cap_net_bind_service from caddy so it cannot bind privileged ports.
# Tillandsias uses 8080 (unprivileged) anyway.
setcap -r /usr/bin/caddy 2>/dev/null || true
adduser -D -u 1000 -s /sbin/nologin caddy 2>/dev/null || true
mkdir -p /etc/caddy /etc/tillandsias /run/router
'

log "copying image files"
wsl_copy_into "$DISTRO_TMP" "${TILL_REPO_ROOT}/images/router/base.Caddyfile" "/etc/caddy/base.Caddyfile"
wsl_copy_into "$DISTRO_TMP" "${TILL_REPO_ROOT}/images/router/entrypoint.sh" "/usr/local/bin/entrypoint.sh"
wsl_copy_into "$DISTRO_TMP" "${TILL_REPO_ROOT}/images/router/router-reload.sh" "/usr/local/bin/router-reload.sh"
wsl_copy_into "$DISTRO_TMP" "$SIDECAR" "/usr/local/bin/tillandsias-router-sidecar"
wsl_copy_into "$DISTRO_TMP" "${TILL_REPO_ROOT}/images/router/external-logs.yaml" "/etc/tillandsias/external-logs.yaml"
wsl_run_in "$DISTRO_TMP" 'chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/router-reload.sh /usr/local/bin/tillandsias-router-sidecar'

wsl_run_in "$DISTRO_TMP" 'rm -rf /var/cache/apk/* /tmp/* 2>/dev/null || true'

mkdir -p "$(dirname "$OUT_TAR")"
wsl_export_and_unregister "$DISTRO_TMP" "$OUT_TAR_WIN"

write_meta "$SERVICE" "caddy" 1000 8080

log "DONE: ${OUT_TAR}"
ls -lh "$OUT_TAR" >&2
