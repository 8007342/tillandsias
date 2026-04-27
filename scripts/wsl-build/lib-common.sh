#!/usr/bin/env bash
# scripts/wsl-build/lib-common.sh — shared helpers for WSL-native image builds.
#
# @trace spec:cross-platform, spec:podman-orchestration
# @cheatsheet runtime/wsl-on-windows.md
#
# These helpers are sourced by build-<service>.sh scripts. They wrap
# wsl.exe for the Windows host build path. They expect to run under
# bash (Git Bash on Windows, or any POSIX bash on Linux/macOS for the
# parity verifier path).
#
# Conventions:
#   - All host paths in the build pipeline live under target/wsl/ or
#     ~/.cache/tillandsias/wsl-bases/.
#   - WSL distro names use prefix `tillandsias-build-` for build-time
#     temp distros, `tillandsias-<service>` for runtime distros.
#   - Functions return non-zero on failure; callers must `set -e`.

set -euo pipefail

# Repo root. lib-common is at scripts/wsl-build/lib-common.sh; up 2 = repo root.
TILL_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TILL_WSL_OUT="${TILL_REPO_ROOT}/target/wsl"
TILL_WSL_CACHE="${HOME}/.cache/tillandsias/wsl-bases"
TILL_WSL_INSTALL_ROOT="${LOCALAPPDATA:-${HOME}/AppData/Local}/Tillandsias/WSL"

mkdir -p "$TILL_WSL_OUT" "$TILL_WSL_CACHE"

# Detect if we're on a Windows host with wsl.exe available.
TILL_HAS_WSL=0
if command -v wsl.exe >/dev/null 2>&1; then
    TILL_HAS_WSL=1
fi

# Convert a Unix-style path (Git Bash or Linux) to a Windows path
# suitable for wsl.exe arguments. On Linux, returns input unchanged
# (the parity verifier path doesn't shell out to wsl.exe).
to_winpath() {
    local p="$1"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$p"
    else
        printf '%s' "$p"
    fi
}

log() {
    printf '[wsl-build] %s\n' "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

# wsl_distro_exists <name> — returns 0 if the distro is registered,
# 1 otherwise. Robust against UTF-16 output of `wsl --list`.
wsl_distro_exists() {
    local name="$1"
    [[ "$TILL_HAS_WSL" == 1 ]] || die "wsl.exe not available"
    # wsl --list --quiet emits names one per line in UTF-16 LE.
    # Git Bash does not ship iconv; stripping null bytes from the
    # ASCII-range payload yields a usable line list.
    local listing
    if command -v iconv >/dev/null 2>&1; then
        listing=$(wsl.exe --list --quiet 2>/dev/null | iconv -f UTF-16LE -t UTF-8 2>/dev/null || true)
    else
        listing=$(wsl.exe --list --quiet 2>/dev/null | tr -d '\0' | tr -d '\r' || true)
    fi
    grep -Fxq "$name" <<<"$listing"
}

# wsl_unregister_quiet <name> — unregister if exists, no-op otherwise.
wsl_unregister_quiet() {
    local name="$1"
    if wsl_distro_exists "$name"; then
        log "unregistering existing distro: $name"
        wsl.exe --unregister "$name" >/dev/null
    fi
}

# wsl_import_temp <name> <tarball_winpath> — import a temp distro at
# %LOCALAPPDATA%\Tillandsias\WSL\build-tmp\<name>. Caller is responsible
# for unregistering it after use (use trap with wsl_unregister_quiet).
wsl_import_temp() {
    local name="$1"
    local tarball="$2"
    [[ "$TILL_HAS_WSL" == 1 ]] || die "wsl.exe not available"

    local install_dir_win install_dir
    install_dir="${TILL_WSL_INSTALL_ROOT}/build-tmp/${name}"
    mkdir -p "$install_dir"
    install_dir_win=$(to_winpath "$install_dir")

    # Pre-clean: if a previous build crashed mid-flight, remove the stale distro.
    wsl_unregister_quiet "$name"

    log "importing temp distro $name from $tarball -> $install_dir_win"
    wsl.exe --import "$name" "$install_dir_win" "$tarball" --version 2 >/dev/null
}

# wsl_run_in <name> <cmd...> — run a command inside the distro as root.
# Command is executed under /bin/sh -c (busybox-compatible; Alpine's
# minirootfs has no bash by default).
wsl_run_in() {
    local name="$1"; shift
    [[ "$TILL_HAS_WSL" == 1 ]] || die "wsl.exe not available"
    # MSYS_NO_PATHCONV=1 prevents Git Bash from rewriting /bin/sh into a
    # Windows path. Without it, /bin/sh would be translated to
    # `C:\Program Files\Git\usr\bin\sh` and never reach the distro.
    MSYS_NO_PATHCONV=1 wsl.exe -d "$name" --user root -- /bin/sh -c "$*"
}

# wsl_run_script <name> — read a script from stdin and run it inside
# the distro. Use this when the script contains $(...) command
# substitutions that must run inside WSL, not on the Windows side.
wsl_run_script() {
    local name="$1"; shift
    [[ "$TILL_HAS_WSL" == 1 ]] || die "wsl.exe not available"
    MSYS_NO_PATHCONV=1 wsl.exe -d "$name" --user root -- /bin/sh
}

# wsl_copy_into <name> <host_src> <distro_dest> — copy a file from the
# Windows host into the WSL distro. Uses /mnt/c/... since DrvFs is
# always mounted.
wsl_copy_into() {
    local name="$1"
    local src="$2"
    local dest="$3"
    [[ -e "$src" ]] || die "wsl_copy_into: source missing: $src"

    # Translate /c/Users/... -> /mnt/c/Users/... that wsl bash sees.
    local mnt_path
    if [[ "$src" =~ ^/([a-zA-Z])/(.*)$ ]]; then
        local drive="${BASH_REMATCH[1],,}"
        mnt_path="/mnt/${drive}/${BASH_REMATCH[2]}"
    else
        # Already a /mnt/... path, or running on Linux where the
        # parity verifier handles things differently.
        mnt_path="$src"
    fi

    local dest_dir
    dest_dir=$(dirname "$dest")
    wsl_run_in "$name" "mkdir -p '$dest_dir' && cp -a '$mnt_path' '$dest'"
}

# wsl_export_and_unregister <name> <out_tar_winpath> — snapshot the
# distro to a tarball, then unregister it.
wsl_export_and_unregister() {
    local name="$1"
    local out_tar="$2"
    [[ "$TILL_HAS_WSL" == 1 ]] || die "wsl.exe not available"

    log "exporting distro $name -> $out_tar"
    # Make sure no exec is still holding state.
    wsl.exe --terminate "$name" >/dev/null 2>&1 || true
    wsl.exe --export "$name" "$out_tar" >/dev/null
    wsl.exe --unregister "$name" >/dev/null
}

# write_meta <service> <user> <default_uid> <service_port> — write the
# sidecar JSON the tray reads at runtime.
write_meta() {
    local service="$1"
    local user="$2"
    local uid="$3"
    local port="$4"
    local meta="${TILL_WSL_OUT}/${service}.meta.json"
    cat >"$meta" <<EOF
{
  "service": "$service",
  "user": "$user",
  "default_uid": $uid,
  "service_port": $port
}
EOF
    log "wrote meta: $meta"
}
