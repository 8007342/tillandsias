#!/usr/bin/env bash
# @trace spec:ci-release
#
# Build both guest binaries (x86_64 and aarch64) using Nix (since the flake
# is hermetic and release.yml uses it) and stage them into target-guest/
# for consumption by tray builders.
#
# Usage:
#   ./scripts/build-guest-binaries.sh           # Build and stage binaries
#   ./scripts/build-guest-binaries.sh --verify  # Verify staged binaries

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_VAL="$(tr -d '[:space:]' < "$ROOT/VERSION")"
TARGET_DIR="$ROOT/target-guest"

X86_64_NAME="tillandsias-headless-x86_64-unknown-linux-musl"
AARCH64_NAME="tillandsias-headless-aarch64-unknown-linux-musl"

X86_64_DEST="$TARGET_DIR/$X86_64_NAME"
AARCH64_DEST="$TARGET_DIR/$AARCH64_NAME"

verify_binaries() {
    echo "[build-guest-binaries] Verifying staged binaries in $TARGET_DIR..."
    
    # 1. Existence and executability
    if [[ ! -f "$X86_64_DEST" ]]; then
        echo "[build-guest-binaries] ERROR: Missing x86_64 binary at $X86_64_DEST" >&2
        return 1
    fi
    if [[ ! -f "$AARCH64_DEST" ]]; then
        echo "[build-guest-binaries] ERROR: Missing aarch64 binary at $AARCH64_DEST" >&2
        return 1
    fi
    
    if [[ ! -x "$X86_64_DEST" ]]; then
        echo "[build-guest-binaries] ERROR: $X86_64_DEST is not executable" >&2
        return 1
    fi
    if [[ ! -x "$AARCH64_DEST" ]]; then
        echo "[build-guest-binaries] ERROR: $AARCH64_DEST is not executable" >&2
        return 1
    fi

    # 2. File static + arch check
    local x86_file_info
    x86_file_info="$(file "$X86_64_DEST")"
    if [[ ! "$x86_file_info" =~ "x86-64" || ! "$x86_file_info" =~ "statically linked" ]]; then
        echo "[build-guest-binaries] ERROR: $X86_64_DEST is not a statically linked x86-64 ELF" >&2
        echo "File info: $x86_file_info" >&2
        return 1
    fi

    local arm_file_info
    arm_file_info="$(file "$AARCH64_DEST")"
    if [[ ! "$arm_file_info" =~ "aarch64" || ! "$arm_file_info" =~ "statically linked" ]]; then
        echo "[build-guest-binaries] ERROR: $AARCH64_DEST is not a statically linked aarch64 ELF" >&2
        echo "File info: $arm_file_info" >&2
        return 1
    fi

    # 3. Version stamp check
    # For x86_64, if running on x86_64 architecture, we can execute it directly to check version
    if [[ "$(uname -m)" == "x86_64" ]]; then
        local x86_version
        x86_version="$("$X86_64_DEST" --version)"
        if [[ "$x86_version" != "Tillandsias v$VERSION_VAL" ]]; then
            echo "[build-guest-binaries] ERROR: $X86_64_DEST version '$x86_version' does not match VERSION 'Tillandsias v$VERSION_VAL'" >&2
            return 1
        fi
        echo "[build-guest-binaries] ✓ x86_64 version check passed: $x86_version"
    else
        # Fallback to strings check if not on x86_64
        if ! strings "$X86_64_DEST" | grep -F "$VERSION_VAL" >/dev/null; then
            echo "[build-guest-binaries] ERROR: $X86_64_DEST does not contain version string '$VERSION_VAL'" >&2
            return 1
        fi
        echo "[build-guest-binaries] ✓ x86_64 strings version check passed"
    fi

    # For aarch64, we can do strings check as we cannot run aarch64 on x86_64 natively
    if ! strings "$AARCH64_DEST" | grep -F "$VERSION_VAL" >/dev/null; then
        echo "[build-guest-binaries] ERROR: $AARCH64_DEST does not contain version string '$VERSION_VAL'" >&2
        return 1
    fi
    echo "[build-guest-binaries] ✓ aarch64 strings version check passed"

    echo "[build-guest-binaries] ✓ Verification SUCCESS: both binaries are correct and match VERSION $VERSION_VAL."
    return 0
}

# Parse argument
VERIFY_ONLY=false
if [[ $# -gt 0 ]]; then
    if [[ "$1" == "--verify" ]]; then
        VERIFY_ONLY=true
    else
        echo "Usage: $0 [--verify]" >&2
        exit 3
    fi
fi

if [[ "$VERIFY_ONLY" == true ]]; then
    verify_binaries
    exit 0
fi

# Build path
# First check if current staged files are already present and valid.
# If so, skip the build step to keep dev fast.
if verify_binaries >/dev/null 2>&1; then
    echo "[build-guest-binaries] Staged binaries are up-to-date. Skipping build."
    verify_binaries
    exit 0
fi

# We need to build. Check if nix is installed.
if ! command -v nix >/dev/null 2>&1; then
    echo "[build-guest-binaries] ERROR: nix is required to build guest binaries." >&2
    echo "[build-guest-binaries] Please install Nix or ensure it is on your PATH." >&2
    exit 1
fi

echo "[build-guest-binaries] Building guest binaries using Nix..."

# Perform the builds
mkdir -p "$ROOT/.nix-output"
nix build -L .#tillandsias-headless-x86_64-musl   --out-link "$ROOT/.nix-output/result-hx"
nix build -L .#tillandsias-headless-aarch64-musl  --out-link "$ROOT/.nix-output/result-ha"

mkdir -p "$TARGET_DIR"

install -m 0755 "$ROOT/.nix-output/result-hx/bin/tillandsias" "$X86_64_DEST"
install -m 0755 "$ROOT/.nix-output/result-ha/bin/tillandsias" "$AARCH64_DEST"

# Remove symlinks to keep directory clean
rm -rf "$ROOT/.nix-output/result-hx" "$ROOT/.nix-output/result-ha"

verify_binaries
