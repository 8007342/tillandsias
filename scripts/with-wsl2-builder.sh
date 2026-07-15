#!/usr/bin/env bash
# =============================================================================
# with-wsl2-builder.sh — Transparent WSL2 re-exec for Windows hosts
#
# The Windows sibling of with-tillandsias-builder.sh (Silverblue toolbox
# re-exec): detects a Windows Git-Bash/MSYS host, ensures a DEDICATED
# `tillandsias-build` WSL2 distro exists and carries the build toolchain
# (idempotent), and re-execs the calling command inside it — so ./build.sh,
# local-ci, ruby YAML validation, shellcheck, and other Linux-shaped build
# work run transparently on Windows (operator directive 2026-07-15).
#
# PLEASE REVIEW: linux — shared-scope build-entry wrapper added from the
# windows lane; mirrors the toolbox wrapper's structure and guards.
#
# Source this at the very top of any build/CI entry point (after the toolbox
# wrapper — each is a no-op off its platform):
#
#   source "$(dirname "$0")/scripts/with-wsl2-builder.sh"
#
# Or run standalone:
#
#   scripts/with-wsl2-builder.sh ./build.sh --check
#
# Non-Windows hosts pass through with zero overhead.
#
# DELIBERATELY NOT the runtime `tillandsias` distro: destructive smoke e2e
# unregisters that distro on every run — coupling the build environment to
# the smoke substrate would wipe toolchains mid-cycle. The build distro is
# imported once from the same cached Fedora rootfs the tray provisions from.
#
# Environment:
#   TILLANDSIAS_SKIP_WSL2=1          — force skip, run bare on host
#   TILLANDSIAS_BUILD_DISTRO=<name>  — distro name (default tillandsias-build)
#   TILLANDSIAS_WSL2_ROOTFS=<tar>    — rootfs tarball for first import
#                                      (default: newest *.rootfs.tar in the
#                                      tray cache %LOCALAPPDATA%\tillandsias\
#                                      cache\rootfs)
#   TILLANDSIAS_WSL2_TARGET_IN_TREE=1 — keep cargo target/ in the checkout
#                                      (default: distro-native CARGO_TARGET_DIR;
#                                      9p-backed target/ makes cargo crawl)
# =============================================================================

set -euo pipefail

WSL2_SELF="${BASH_SOURCE[0]}"
BUILD_DISTRO="${TILLANDSIAS_BUILD_DISTRO:-tillandsias-build}"

_W2_DIRECT=0
[[ "${BASH_SOURCE[0]}" == "$0" ]] && _W2_DIRECT=1

# ── Guard: only trigger on Windows Git-Bash/MSYS hosts ────────────────────
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *)
        [[ "$_W2_DIRECT" == 1 && $# -gt 0 ]] && exec "$@"
        return 0 2>/dev/null || exit 0
        ;;
esac

# ── Guard: explicit skip ──────────────────────────────────────────────────
if [[ "${TILLANDSIAS_SKIP_WSL2:-}" == "1" ]]; then
    [[ "$_W2_DIRECT" == 1 && $# -gt 0 ]] && exec "$@"
    return 0 2>/dev/null || exit 0
fi

# ── Guard: wsl.exe must be available ──────────────────────────────────────
if ! command -v wsl.exe &>/dev/null; then
    echo "[wsl2-builder] ERROR: wsl.exe not found — install WSL2 first:" >&2
    echo "    wsl --install --no-distribution   (then restart Windows)" >&2
    exit 1
fi

# wsl.exe pipe output is UTF-16LE — NUL-strip before any parse (same
# discipline as the tray's wsl_list_quiet).
_wsl_clean() { tr -d '\0' | tr -d '\r'; }

_build_distro_registered() {
    wsl.exe --list --quiet 2>/dev/null | _wsl_clean | grep -qxF "$BUILD_DISTRO"
}

# ── Ensure the build distro exists (import from the tray's cached rootfs) ─
if ! _build_distro_registered; then
    ROOTFS="${TILLANDSIAS_WSL2_ROOTFS:-}"
    if [[ -z "$ROOTFS" ]]; then
        CACHE_DIR="$(cygpath -u "${LOCALAPPDATA}")/tillandsias/cache/rootfs"
        ROOTFS="$(ls -t "$CACHE_DIR"/*.rootfs.tar 2>/dev/null | head -1 || true)"
    fi
    if [[ -z "$ROOTFS" || ! -f "$ROOTFS" ]]; then
        echo "[wsl2-builder] ERROR: no rootfs tarball for the first import." >&2
        echo "[wsl2-builder] Launch the Tillandsias tray once (it caches the Fedora" >&2
        echo "[wsl2-builder] rootfs under %LOCALAPPDATA%\\tillandsias\\cache\\rootfs)," >&2
        echo "[wsl2-builder] or point TILLANDSIAS_WSL2_ROOTFS at a Fedora rootfs tar." >&2
        exit 1
    fi
    INSTALL_DIR_WIN="${LOCALAPPDATA}\\tillandsias\\wsl-build"
    echo "[wsl2-builder] Importing '$BUILD_DISTRO' from $(basename "$ROOTFS") (first run)..."
    wsl.exe --import "$BUILD_DISTRO" "$INSTALL_DIR_WIN" "$(cygpath -w "$ROOTFS")" --version 2 \
        2>&1 | _wsl_clean
    _build_distro_registered || {
        echo "[wsl2-builder] ERROR: import did not register '$BUILD_DISTRO'." >&2
        exit 1
    }
fi

# ── Ensure the toolchain is initialized (idempotent, marker-gated) ────────
# Marker probe goes via STDIN: Git Bash (MSYS) rewrites leading-slash
# ARGUMENTS into C:/Program Files/Git/... paths, so `-- test -f /root/...`
# can never match; stdin bytes are never converted.
if ! echo 'test -f /root/.cache/tillandsias/wsl2-builder-initialized' \
        | wsl.exe -d "$BUILD_DISTRO" -u root -- sh 2>/dev/null; then
    echo "[wsl2-builder] Initializing '$BUILD_DISTRO' with build tools (one-time)..."
    # Same package set as the Silverblue toolbox init, plus curl for rustup
    # and shellcheck/git for the CI helpers. stdin-delivered script: wsl
    # arg-joined multi-line scripts get re-parsed by the guest login shell
    # and arrive shredded (order-326 live repro, 2026-07-15).
    wsl.exe -d "$BUILD_DISTRO" -u root -- sh <<'WSL2_INIT'
set -eu
dnf install -y \
    gcc pkg-config file cmake make \
    openssl-devel systemd-devel \
    ruby perl-FindBin \
    procps-ng findutils diffutils \
    git curl tar xz ShellCheck awk \
    2>&1 | sed 's/^/  [dnf] /'
if ! command -v rustup >/dev/null 2>&1 && [ ! -x /root/.cargo/bin/rustup ]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup-init.sh
    sh /tmp/rustup-init.sh -y 2>&1 | sed 's/^/  [rustup] /'
    rm -f /tmp/rustup-init.sh
fi
. /root/.cargo/env
rustup target add x86_64-unknown-linux-musl aarch64-unknown-linux-musl \
    2>&1 | sed 's/^/  [rustup] /'
mkdir -p /root/.cache/tillandsias
touch /root/.cache/tillandsias/wsl2-builder-initialized
echo "[wsl2-builder] init complete"
WSL2_INIT
fi

# ── Re-exec inside the build distro ───────────────────────────────────────
# `wsl --cd` accepts the Windows path and translates it (the checkout lands
# at /mnt/c/... via automount, which the build distro keeps enabled —
# unlike the runtime distro). Cargo's target dir defaults to a
# distro-NATIVE path: metadata-heavy cargo I/O over 9p is unusably slow,
# and check/clippy/test consumers don't need in-tree artifacts.
PWD_WIN="$(pwd -W 2>/dev/null || cygpath -w "$(pwd)")"
REPO_BASENAME="$(basename "$(pwd)")"

ARGS_QUOTED=""
for arg in "$@"; do
    ARGS_QUOTED="$ARGS_QUOTED$(printf '%q ' "$arg")"
done

_ENV_PREFIX="export TILLANDSIAS_SKIP_WSL2=1; . /root/.cargo/env 2>/dev/null || true;"
if [[ "${TILLANDSIAS_WSL2_TARGET_IN_TREE:-}" != "1" ]]; then
    _ENV_PREFIX="$_ENV_PREFIX export CARGO_TARGET_DIR=\"/root/.cache/tillandsias-wsl2-target/$REPO_BASENAME\";"
fi

echo "[wsl2-builder] Re-execing inside '$BUILD_DISTRO' WSL2 distro..."

if [[ "$_W2_DIRECT" == 1 ]]; then
    if [[ $# -eq 0 ]]; then
        echo "usage: $WSL2_SELF <command> [args...]" >&2
        exit 2
    fi
    exec wsl.exe -d "$BUILD_DISTRO" -u root --cd "$PWD_WIN" -- \
        bash -c "$_ENV_PREFIX exec $ARGS_QUOTED"
fi

# Sourced from a build script: $0/$@ are the calling script and its args.
# Re-exec it via a path RELATIVE to the checkout (the absolute Git-Bash
# /c/... form does not exist inside the distro).
SCRIPT_REL="$(realpath --relative-to="$(pwd)" "$0")"
exec wsl.exe -d "$BUILD_DISTRO" -u root --cd "$PWD_WIN" -- \
    bash -c "$_ENV_PREFIX exec bash $(printf '%q' "./$SCRIPT_REL") $ARGS_QUOTED"
