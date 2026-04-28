#!/usr/bin/env bash
# scripts/wsl-build/build-git.sh — build the Tillandsias git-service WSL distro.
#
# @trace spec:cross-platform, spec:git-mirror-service
# @cheatsheet runtime/wsl-on-windows.md
#
# Replicates images/git/Containerfile:
#   FROM alpine:3.20
#   apk add --no-cache git git-daemon bash openssh-client github-cli
#   adduser -D -u 1000 -s /bin/bash git
#   COPY entrypoint.sh, post-receive-hook.sh, git-askpass-tillandsias.sh,
#        external-logs.yaml
#   USER git

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

SERVICE=git
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

log "installing packages and creating git user"
wsl_run_in "$DISTRO_TMP" '
set -eux
apk update
apk add --no-cache git git-daemon bash openssh-client github-cli
adduser -D -u 1000 -s /bin/bash git
mkdir -p /srv/git /var/log/git-service /etc/tillandsias /usr/local/share/git-service
chown -R git:git /srv/git /var/log/git-service
'

log "copying image files"
wsl_copy_into "$DISTRO_TMP" "${TILL_REPO_ROOT}/images/git/entrypoint.sh" "/usr/local/bin/entrypoint.sh"
wsl_copy_into "$DISTRO_TMP" "${TILL_REPO_ROOT}/images/git/post-receive-hook.sh" "/usr/local/share/git-service/post-receive-hook.sh"
wsl_copy_into "$DISTRO_TMP" "${TILL_REPO_ROOT}/images/git/git-askpass-tillandsias.sh" "/usr/local/bin/git-askpass-tillandsias.sh"
wsl_copy_into "$DISTRO_TMP" "${TILL_REPO_ROOT}/images/git/external-logs.yaml" "/etc/tillandsias/external-logs.yaml"
wsl_run_in "$DISTRO_TMP" 'chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/git-askpass-tillandsias.sh /usr/local/share/git-service/post-receive-hook.sh'

wsl_run_in "$DISTRO_TMP" 'rm -rf /var/cache/apk/* /tmp/* 2>/dev/null || true'

mkdir -p "$(dirname "$OUT_TAR")"
wsl_export_and_unregister "$DISTRO_TMP" "$OUT_TAR_WIN"

write_meta "$SERVICE" "git" 1000 9418

log "DONE: ${OUT_TAR}"
ls -lh "$OUT_TAR" >&2
