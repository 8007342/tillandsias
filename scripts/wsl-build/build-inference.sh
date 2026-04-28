#!/usr/bin/env bash
# scripts/wsl-build/build-inference.sh — build the Tillandsias inference WSL distro.
#
# @trace spec:cross-platform, spec:inference-container
# @cheatsheet runtime/wsl-on-windows.md
#
# Replicates images/inference/Containerfile:
#   FROM fedora-minimal:43
#   microdnf install bash curl ca-certificates zstd tar gzip pciutils
#   download + extract ollama (CPU-only)
#   useradd ollama (uid 1000)
#   COPY entrypoint.sh + external-logs.yaml
#
# Skips the build-time model bake (would require network access during
# build); runtime ollama can pull models on demand.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

SERVICE=inference
FEDORA_BASE="fedora-minimal-43"
DISTRO_TMP="tillandsias-build-${SERVICE}"
OUT_TAR="${TILL_WSL_OUT}/tillandsias-${SERVICE}.tar"
OUT_TAR_WIN=$(to_winpath "$OUT_TAR")

cleanup() {
    if [[ "$TILL_HAS_WSL" == 1 ]]; then
        wsl_unregister_quiet "$DISTRO_TMP" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

base_tar=$("${SCRIPT_DIR}/bases.sh" "$FEDORA_BASE")
base_tar_win=$(to_winpath "$base_tar")

wsl_import_temp "$DISTRO_TMP" "$base_tar_win"

log "installing packages and ollama"
wsl_run_script "$DISTRO_TMP" <<'EOF_SCRIPT'
set -eux
microdnf install -y bash curl ca-certificates zstd tar gzip pciutils
microdnf clean all

# Install ollama (CPU-only, skip GPU runners ~1.8 GB).
curl -fsSL -o /tmp/ollama.tar.zst \
  https://github.com/ollama/ollama/releases/latest/download/ollama-linux-amd64.tar.zst
mkdir -p /usr/local/bin
zstd -d /tmp/ollama.tar.zst -o /tmp/ollama.tar
tar -xf /tmp/ollama.tar -C /usr/local bin/ollama
rm -f /tmp/ollama.tar.zst /tmp/ollama.tar
test -x /usr/local/bin/ollama

useradd -u 1000 -m -s /bin/bash ollama
mkdir -p /home/ollama/.ollama/models/ /opt/baked-models /etc/tillandsias
chown -R 1000:1000 /home/ollama/.ollama /opt/baked-models
EOF_SCRIPT

log "copying image files"
wsl_copy_into "$DISTRO_TMP" "${TILL_REPO_ROOT}/images/inference/entrypoint.sh" "/usr/local/bin/entrypoint.sh"
wsl_copy_into "$DISTRO_TMP" "${TILL_REPO_ROOT}/images/inference/external-logs.yaml" "/etc/tillandsias/external-logs.yaml"
wsl_run_in "$DISTRO_TMP" 'chmod +x /usr/local/bin/entrypoint.sh'

wsl_run_in "$DISTRO_TMP" 'rm -rf /var/cache/yum/* /tmp/* 2>/dev/null || true'

mkdir -p "$(dirname "$OUT_TAR")"
wsl_export_and_unregister "$DISTRO_TMP" "$OUT_TAR_WIN"

write_meta "$SERVICE" "ollama" 1000 11434

log "DONE: ${OUT_TAR}"
ls -lh "$OUT_TAR" >&2
