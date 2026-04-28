#!/usr/bin/env bash
# scripts/wsl-build/bases.sh — fetch + verify upstream base rootfs tarballs.
#
# @trace spec:cross-platform
# @cheatsheet runtime/wsl-on-windows.md
#
# Usage:
#   scripts/wsl-build/bases.sh alpine-3.20    -> ~/.cache/tillandsias/wsl-bases/alpine-3.20.tar.gz
#   scripts/wsl-build/bases.sh fedora-43      -> ~/.cache/tillandsias/wsl-bases/fedora-43.tar
#
# Alpine: direct download + SHA-256 verify against
#   https://dl-cdn.alpinelinux.org/alpine/v<x.y>/releases/x86_64/latest-releases.yaml
# Fedora: skopeo copy docker://registry.fedoraproject.org/fedora:43 oci:<dir>,
#   then layer-flatten into a single tarball.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
source "${SCRIPT_DIR}/lib-common.sh"

BASE="${1:-}"
[[ -n "$BASE" ]] || die "usage: bases.sh <alpine-3.20|fedora-43>"

case "$BASE" in
    alpine-*)
        version="${BASE#alpine-}"
        out="${TILL_WSL_CACHE}/alpine-${version}.tar.gz"
        if [[ -f "$out" ]]; then
            log "alpine-${version} cached at $out"
            printf '%s\n' "$out"
            exit 0
        fi

        log "fetching latest-releases.yaml for alpine v${version}"
        meta=$(curl -fsSL "https://dl-cdn.alpinelinux.org/alpine/v${version}/releases/x86_64/latest-releases.yaml")

        # Find the minirootfs entry: walk lines, set found=1 when we see
        # `flavor: alpine-minirootfs`, then capture the FIRST file: and
        # sha256: lines that follow (within that same YAML entry, they
        # appear adjacent to flavor:).
        file_name=$(printf '%s\n' "$meta" | awk '
            /^[[:space:]]*flavor:[[:space:]]*alpine-minirootfs/ { found=1; next }
            found && /^[[:space:]]*file:/ { print $2; exit }
        ' | tr -d '\r')
        sha=$(printf '%s\n' "$meta" | awk '
            /^[[:space:]]*flavor:[[:space:]]*alpine-minirootfs/ { found=1; next }
            found && /^[[:space:]]*sha256:/ { print $2; exit }
        ' | tr -d '\r')

        [[ -n "$file_name" && -n "$sha" ]] || die "could not parse alpine release manifest"
        log "alpine minirootfs: $file_name  sha256=$sha"

        url="https://dl-cdn.alpinelinux.org/alpine/v${version}/releases/x86_64/${file_name}"
        log "downloading $url"
        tmp="${out}.tmp.$$"
        curl -fsSL -o "$tmp" "$url"

        # Verify SHA-256.
        if command -v sha256sum >/dev/null 2>&1; then
            actual=$(sha256sum "$tmp" | awk '{print $1}')
        else
            actual=$(shasum -a 256 "$tmp" | awk '{print $1}')
        fi
        if [[ "$actual" != "$sha" ]]; then
            rm -f "$tmp"
            die "SHA-256 mismatch for $file_name: expected $sha got $actual"
        fi
        mv "$tmp" "$out"
        log "alpine ${version} verified and cached: $out"
        printf '%s\n' "$out"
        ;;

    fedora-*|fedora-minimal-*)
        # Image reference: fedora:43 OR fedora-minimal:43.
        if [[ "$BASE" =~ ^fedora-minimal-(.*)$ ]]; then
            image="fedora-minimal"
            version="${BASH_REMATCH[1]}"
            cache_name="fedora-minimal-${version}"
        else
            image="fedora"
            version="${BASE#fedora-}"
            cache_name="fedora-${version}"
        fi
        out="${TILL_WSL_CACHE}/${cache_name}.tar"
        if [[ -f "$out" ]]; then
            log "${cache_name} cached at $out"
            printf '%s\n' "$out"
            exit 0
        fi

        # Strategy: bootstrap a temp Alpine WSL distro with skopeo
        # installed via apk, use it to pull the Fedora image into an
        # OCI directory, then layer-flatten into a single rootfs
        # tarball. No skopeo binary required on the Windows host.
        # The Alpine base is fetched recursively (cached after first run).
        alpine_tar=$("${SCRIPT_DIR}/bases.sh" alpine-3.20)

        bootstrap="tillandsias-bases-skopeo"
        # shellcheck source=lib-common.sh
        source "${SCRIPT_DIR}/lib-common.sh"

        cleanup_bootstrap() {
            wsl_unregister_quiet "$bootstrap" >/dev/null 2>&1 || true
        }
        trap cleanup_bootstrap EXIT

        alpine_tar_win=$(to_winpath "$alpine_tar")
        wsl_import_temp "$bootstrap" "$alpine_tar_win"

        log "installing skopeo in bootstrap distro"
        wsl_run_in "$bootstrap" 'apk update && apk add --no-cache skopeo tar'

        log "pulling docker://registry.fedoraproject.org/${image}:${version} via skopeo"
        # OCI dir lives inside the bootstrap distro; we tar it out from /oci/.
        # Pass via stdin so $(...) command substitutions evaluate inside WSL,
        # not in the calling Bash on Windows.
        wsl_run_script "$bootstrap" <<EOF_SCRIPT
set -eux
rm -rf /oci /work
mkdir -p /oci /work
skopeo copy 'docker://registry.fedoraproject.org/${image}:${version}' 'oci:/oci:latest'

# Layer-flatten:
#   - read /oci/index.json -> top-level manifest digest
#   - read manifest -> layer digests in order
#   - extract each layer into /work, preserving order
#   - tar /work into /tmp/${cache_name}.tar
cd /oci
manifest_digest=\$(grep -oE 'sha256:[a-f0-9]+' index.json | head -n1 | sed 's/sha256://')
manifest=blobs/sha256/\${manifest_digest}
# Print just layer digests (skip the first match, which is the
# config blob digest).
layers=\$(grep -oE 'sha256:[a-f0-9]+' "\$manifest" | tail -n +2 | sed 's/sha256://')
for d in \$layers; do
    tar -xf blobs/sha256/\$d -C /work
done
cd /work
tar -cf /tmp/${cache_name}.tar .
ls -l /tmp/${cache_name}.tar
EOF_SCRIPT

        # Pull the produced tarball out via /mnt/c.
        out_in_distro="/mnt/c$(echo "$out" | sed 's|^/c||')"
        log "moving tarball out of bootstrap distro -> $out"
        wsl_run_in "$bootstrap" "mkdir -p \$(dirname '$out_in_distro') && cp /tmp/${cache_name}.tar '$out_in_distro'"

        log "${cache_name} cached: $out"
        printf '%s\n' "$out"
        ;;

    *)
        die "unknown base: $BASE (expected alpine-X.Y or fedora-N)"
        ;;
esac
