#!/usr/bin/env bash
# @trace spec:host-chromium-on-demand, spec:download-telemetry, spec:chromium-safe-variant
# @cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md
# @cheatsheet security/owasp-top-10-2021.md
#
# Tillandsias userspace Chromium installer.
#
# Sourced by scripts/install.sh during `curl ... | bash`, and also invoked
# directly by the tray binary's `tillandsias --install-chromium` subcommand
# (via the embedded copy in src-tauri/src/embedded.rs in a future change).
#
# Behaviour:
#   * Downloads the pinned Chrome for Testing build into XDG_DATA_HOME/
#     tillandsias/chromium/<version>/, NOT under any cache directory.
#   * Verifies the SHA-256 of the downloaded ZIP against a per-platform
#     digest baked into install.sh by scripts/refresh-chromium-pin.sh.
#   * On macOS, strips com.apple.quarantine immediately after extraction
#     so Gatekeeper does not block the launch.
#   * Atomically repoints the `current` symlink (`ln -snf`) only after
#     the SHA-256 check passes and extraction completes.
#   * Garbage-collects old per-version directories — keeps at most TWO
#     versions on disk (current + previous, as a manual rollback safety
#     net).
#   * Honours SKIP_CHROMIUM_DOWNLOAD=1 by returning success without
#     touching the filesystem (for air-gapped installs).
#
# Sourcing model:
#   The caller (install.sh) sets CHROMIUM_VERSION and CHROMIUM_SHA256_*
#   shell variables before calling install_chromium. The variables are
#   inherited via `source`/`.`-style invocation OR exported into the
#   environment by the caller; this script does NOT read install.sh on
#   its own. That keeps the digest pin in a single file.

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Print to stderr.
_chromium_log() {
    printf '  %s\n' "$*" >&2
}

# Detect the Chrome for Testing platform identifier for the running host.
# Echoes one of: linux64, mac-arm64, mac-x64, win64. Returns 1 on unknown.
chromium_platform() {
    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    case "$os" in
        linux)
            case "$arch" in
                x86_64|amd64) echo "linux64"; return 0 ;;
                *) _chromium_log "ERROR: unsupported Linux arch for Chromium: $arch"; return 1 ;;
            esac
            ;;
        darwin)
            case "$arch" in
                arm64|aarch64) echo "mac-arm64"; return 0 ;;
                x86_64) echo "mac-x64"; return 0 ;;
                *) _chromium_log "ERROR: unsupported macOS arch for Chromium: $arch"; return 1 ;;
            esac
            ;;
        msys*|mingw*|cygwin*)
            echo "win64"
            return 0
            ;;
        *)
            _chromium_log "ERROR: unsupported OS for Chromium: $os"
            return 1
            ;;
    esac
}

# Compute the userspace install root for the running platform, per the
# `Userspace install location under XDG_DATA_HOME` requirement.
chromium_install_root() {
    local os
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    case "$os" in
        linux)
            local xdg_data
            xdg_data="${XDG_DATA_HOME:-$HOME/.local/share}"
            printf '%s/tillandsias/chromium\n' "$xdg_data"
            ;;
        darwin)
            printf '%s/Library/Application Support/tillandsias/chromium\n' "$HOME"
            ;;
        msys*|mingw*|cygwin*)
            local localappdata
            localappdata="${LOCALAPPDATA:-$HOME/AppData/Local}"
            printf '%s/tillandsias/chromium\n' "$localappdata"
            ;;
        *)
            return 1
            ;;
    esac
}

# Pick the platform-appropriate SHA-256 variable. Echoes the digest or
# empty if no variable is set.
chromium_expected_sha256() {
    local platform="$1"
    case "$platform" in
        linux64)    echo "${CHROMIUM_SHA256_LINUX64:-}" ;;
        mac-arm64)  echo "${CHROMIUM_SHA256_MAC_ARM64:-}" ;;
        mac-x64)    echo "${CHROMIUM_SHA256_MAC_X64:-}" ;;
        win64)      echo "${CHROMIUM_SHA256_WIN64:-}" ;;
        *)          return 1 ;;
    esac
}

# Compute SHA-256 of a file using the platform-standard tool.
chromium_sha256() {
    local path="$1"
    local os
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    case "$os" in
        linux)
            sha256sum "$path" | awk '{print $1}'
            ;;
        darwin)
            shasum -a 256 "$path" | awk '{print $1}'
            ;;
        msys*|mingw*|cygwin*)
            certutil -hashfile "$path" SHA256 \
                | tr -d '\r\n ' \
                | sed 's/.*://; s/CertUtil.*$//' \
                | tr '[:upper:]' '[:lower:]' \
                | head -c 64
            ;;
        *)
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Main entry point — install_chromium
# ---------------------------------------------------------------------------
#
# Arguments:
#   $1  Optional path to a pre-downloaded ZIP (air-gapped install).
#       When empty, fetches from storage.googleapis.com.
#
# Required env vars:
#   CHROMIUM_VERSION
#   CHROMIUM_SHA256_LINUX64
#   CHROMIUM_SHA256_MAC_ARM64
#   CHROMIUM_SHA256_MAC_X64
#   CHROMIUM_SHA256_WIN64
#
# Optional env vars:
#   SKIP_CHROMIUM_DOWNLOAD=1   skip everything, return success.
install_chromium() {
    local from_zip="${1:-}"

    # Skip-flag short-circuits BEFORE any work — covers the air-gapped case
    # AND the `bash install.sh` user who explicitly opted out.
    if [ "${SKIP_CHROMIUM_DOWNLOAD:-}" = "1" ]; then
        _chromium_log "Chromium download skipped (SKIP_CHROMIUM_DOWNLOAD=1)."
        _chromium_log "  Run: tillandsias --install-chromium"
        _chromium_log "  ... or: tillandsias --install-chromium --from-zip <path>"
        return 0
    fi

    if [ -z "${CHROMIUM_VERSION:-}" ]; then
        _chromium_log "ERROR: CHROMIUM_VERSION is not set. install.sh is missing the pin."
        _chromium_log "       Run scripts/refresh-chromium-pin.sh against your install.sh."
        return 1
    fi

    local platform
    if ! platform="$(chromium_platform)"; then
        return 1
    fi

    local expected_sha
    expected_sha="$(chromium_expected_sha256 "$platform")"
    if [ -z "$expected_sha" ]; then
        _chromium_log "ERROR: no SHA-256 pin for platform $platform."
        _chromium_log "       Run scripts/refresh-chromium-pin.sh against your install.sh."
        return 1
    fi

    local root
    if ! root="$(chromium_install_root)"; then
        _chromium_log "ERROR: cannot resolve XDG_DATA_HOME-equivalent install root."
        return 1
    fi

    local version_dir="$root/$CHROMIUM_VERSION"
    local extracted_subdir="chrome-$platform"
    local final_binary
    case "$platform" in
        linux64)    final_binary="$version_dir/$extracted_subdir/chrome" ;;
        mac-arm64|mac-x64)
                    final_binary="$version_dir/$extracted_subdir/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" ;;
        win64)      final_binary="$version_dir/$extracted_subdir/chrome.exe" ;;
    esac

    # Idempotency: if the extracted binary is already present, skip.
    if [ -f "$final_binary" ] || [ -e "$final_binary" ]; then
        _chromium_log "Chromium $CHROMIUM_VERSION already installed at $version_dir"
        # Still ensure the `current` symlink points at this version.
        chromium_repoint_current "$root" "$CHROMIUM_VERSION"
        chromium_gc_old_versions "$root" "$CHROMIUM_VERSION"
        return 0
    fi

    mkdir -p "$root"

    local zip_path
    if [ -n "$from_zip" ]; then
        if [ ! -f "$from_zip" ]; then
            _chromium_log "ERROR: --from-zip target does not exist: $from_zip"
            return 1
        fi
        zip_path="$from_zip"
        _chromium_log "Verifying Chromium ZIP from $zip_path..."
    else
        local url="https://storage.googleapis.com/chrome-for-testing-public/$CHROMIUM_VERSION/$platform/chrome-$platform.zip"
        zip_path="$(mktemp -t "tillandsias-chromium-XXXXXX.zip")"
        _chromium_log "Downloading Chromium $CHROMIUM_VERSION for $platform (~150 MB)..."
        # -f: fail on HTTP errors. -L: follow redirects. --retry 3: bounded retries.
        # Custom UA so storage.googleapis.com logs identify us.
        # @trace spec:download-telemetry
        if ! curl -fL --retry 3 \
            -H "User-Agent: tillandsias-installer/$CHROMIUM_VERSION" \
            -o "$zip_path" "$url"; then
            _chromium_log "ERROR: Chromium download failed."
            rm -f "$zip_path"
            return 1
        fi
    fi

    # Compute SHA-256 BEFORE extraction (the spec requires this — no chmod,
    # no unzip, no mv on a corrupt archive).
    local actual_sha
    if ! actual_sha="$(chromium_sha256 "$zip_path")"; then
        _chromium_log "ERROR: failed to compute SHA-256 of $zip_path"
        [ -z "$from_zip" ] && rm -f "$zip_path"
        return 1
    fi

    if [ "$actual_sha" != "$expected_sha" ]; then
        _chromium_log "Chromium download failed integrity check. Aborting."
        _chromium_log "  Expected: $expected_sha"
        _chromium_log "  Got:      $actual_sha"
        _chromium_log "  Re-run the installer or report at https://github.com/8007342/tillandsias/issues"
        [ -z "$from_zip" ] && rm -f "$zip_path"
        return 1
    fi

    # Extract into the per-version directory.
    mkdir -p "$version_dir"
    _chromium_log "Extracting Chromium into $version_dir..."

    local os
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    case "$os" in
        msys*|mingw*|cygwin*)
            # Windows path under Git Bash: prefer powershell Expand-Archive.
            if command -v powershell.exe >/dev/null 2>&1; then
                powershell.exe -NoProfile -Command \
                    "Expand-Archive -Force -Path '$zip_path' -DestinationPath '$version_dir'" \
                    >/dev/null
            elif command -v unzip >/dev/null 2>&1; then
                unzip -q -o "$zip_path" -d "$version_dir"
            else
                _chromium_log "ERROR: neither powershell.exe nor unzip available."
                [ -z "$from_zip" ] && rm -f "$zip_path"
                return 1
            fi
            ;;
        *)
            if ! command -v unzip >/dev/null 2>&1; then
                _chromium_log "ERROR: unzip is required but not installed."
                [ -z "$from_zip" ] && rm -f "$zip_path"
                return 1
            fi
            unzip -q -o "$zip_path" -d "$version_dir"
            ;;
    esac

    # macOS quarantine strip — bundle root only, recursive. Swallow
    # missing-attr errors per the spec's `2>/dev/null || true` requirement.
    if [ "$os" = "darwin" ]; then
        local bundle="$version_dir/$extracted_subdir/Google Chrome for Testing.app"
        if [ -d "$bundle" ]; then
            xattr -dr com.apple.quarantine "$bundle" 2>/dev/null || true
        fi
    fi

    # Atomic repoint of `current`.
    chromium_repoint_current "$root" "$CHROMIUM_VERSION"

    # GC old versions (keeps current + immediately-previous).
    chromium_gc_old_versions "$root" "$CHROMIUM_VERSION"

    # Cleanup downloaded ZIP only when we fetched it (don't touch user-supplied).
    if [ -z "$from_zip" ]; then
        rm -f "$zip_path"
    fi

    _chromium_log "Chromium $CHROMIUM_VERSION installed at $version_dir/$extracted_subdir/"
    return 0
}

# Atomically repoint <root>/current to <version>. ln -snf is the standard
# atomic-symlink-replace idiom on Unix; on Windows under Git Bash we use
# a directory junction (mklink /J), recreated each call.
chromium_repoint_current() {
    local root="$1"
    local version="$2"
    local os
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    case "$os" in
        msys*|mingw*|cygwin*)
            local current="$root/current"
            local current_win
            current_win="$(cygpath -w "$current" 2>/dev/null || echo "$current")"
            local target_win
            target_win="$(cygpath -w "$root/$version" 2>/dev/null || echo "$root/$version")"
            if [ -e "$current" ] || [ -L "$current" ]; then
                cmd.exe /C "rmdir \"$current_win\"" >/dev/null 2>&1 || rm -rf "$current"
            fi
            cmd.exe /C "mklink /J \"$current_win\" \"$target_win\"" >/dev/null
            ;;
        *)
            ln -snf "$version" "$root/current"
            ;;
    esac
}

# Keep at most TWO version directories on disk: the new current and the
# immediately-previous version (rollback safety net). Earlier versions are
# removed.
chromium_gc_old_versions() {
    local root="$1"
    local current="$2"
    local previous=""
    local entry name
    # Build a sorted list of sibling version directories (lexicographic
    # sort is fine — versions are dotted ints which sort the same way).
    local -a versions=()
    while IFS= read -r entry; do
        name="$(basename "$entry")"
        # Skip the symlink/junction and any non-version entries.
        [ "$name" = "current" ] && continue
        [ -d "$entry" ] || continue
        versions+=("$name")
    done < <(find "$root" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) 2>/dev/null | sort)

    # Find the previous version (the largest one strictly less than current).
    for name in "${versions[@]}"; do
        if [ "$name" != "$current" ]; then
            # versions[] is sorted ascending; the LAST one less than current
            # is the immediate predecessor.
            if printf '%s\n%s\n' "$name" "$current" | sort -C 2>/dev/null; then
                previous="$name"
            fi
        fi
    done

    # Remove everything except current + previous.
    for name in "${versions[@]}"; do
        if [ "$name" = "$current" ] || [ "$name" = "$previous" ]; then
            continue
        fi
        _chromium_log "GC: removing old Chromium version $name"
        rm -rf "${root:?}/${name:?}"
    done
}

# ---------------------------------------------------------------------------
# Direct invocation: `bash install-chromium.sh [--from-zip <path>]`
# ---------------------------------------------------------------------------
#
# When sourced from install.sh the caller drives install_chromium directly.
# When invoked as a script we accept --from-zip; we still expect the four
# CHROMIUM_SHA256_* + CHROMIUM_VERSION variables in the env (the tray sets
# them via env when shelling out to this script).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    from_zip=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --from-zip)
                shift
                if [ $# -eq 0 ]; then
                    _chromium_log "ERROR: --from-zip requires a path argument."
                    exit 1
                fi
                from_zip="$1"
                ;;
            *)
                _chromium_log "ERROR: unknown argument: $1"
                exit 1
                ;;
        esac
        shift
    done
    install_chromium "$from_zip"
fi
