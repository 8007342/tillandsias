#!/usr/bin/env bash
# ./launch.sh — launch THE local build, idempotently, without guessing which binary.
#
# "The local build" means exactly one thing on each platform: the binary that
# `./build.sh --install` put on this host (Linux: ~/.local/bin/tillandsias;
# macOS: the installed Tillandsias.app). Everything else — target/, dist/,
# builds/, a stray copy in Applications — is a build ARTIFACT, and picking one
# of those by hand is how the fleet ends up running skewed versions. This
# script refuses to guess: it launches the install target or tells you the one
# command that produces it.
#
# The version autoincrement is part of the contract: every `./build.sh
# --install` bumps VERSION (locally, never committed) so the installed binary
# names the build it came from, and this script prints that name beside the
# tree's VERSION and the newest image tag so a skew is visible before a lane
# launch is DOA. Do NOT install with TILLANDSIAS_SKIP_VERSION_BUMP=1.
#
# Usage:
#   ./launch.sh            launch the tray (no-op if it is already running from the install target)
#   ./launch.sh --which    print the resolved binary, its version, the tree VERSION, the newest image tag; launch nothing
#   ./launch.sh --restart  stop a running tray (any binary) and launch the install target
# Exit 0 = running from the install target (already or just launched); 2 = no install target; 3 = a DIFFERENT binary is running (use --restart).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode="${1:-launch}"

resolve() {
    case "$(uname -s)" in
        Linux)
            printf '%s\n' "${TILLANDSIAS_INSTALL_BIN:-$HOME/.local/bin/tillandsias}" ;;
        Darwin)
            for app in "/Applications/Tillandsias.app" "$HOME/Applications/Tillandsias.app"; do
                [ -d "$app" ] && { printf '%s\n' "$app/Contents/MacOS/$(ls "$app/Contents/MacOS" 2>/dev/null | head -1)"; return; }
            done
            printf '%s\n' "/Applications/Tillandsias.app/Contents/MacOS/tillandsias-macos-tray" ;;
        *)  echo "launch.sh: unsupported platform $(uname -s) — on Windows use the installed tray from the Start menu" >&2; exit 2 ;;
    esac
}

bin="$(resolve)"
tree_version="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || echo unknown)"
if [ ! -x "$bin" ]; then
    echo "launch.sh: no install target at $bin" >&2
    echo "  Produce it with:  ./build.sh --install      (keeps the version autoincrement; do not skip it)" >&2
    echo "  Artifacts under target/, dist/ or builds/ are NOT the local build; this script will not launch them." >&2
    exit 2
fi
bin_version="$("$bin" --version 2>/dev/null | head -1 | sed -E 's/^Tillandsias v?//')"   # 56.9.2.1 — no leading v
newest_image="$(command -v podman >/dev/null 2>&1 && podman images --format '{{.Tag}}' 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1 || true)"
echo "local build: $bin"
echo "  binary version : ${bin_version:-unknown}"
echo "  tree VERSION   : $tree_version"
echo "  newest image   : ${newest_image:-none}"
if [ -n "$newest_image" ] && [ "$newest_image" != "v${bin_version}" ]; then
    echo "  NOTE: newest image tag != binary version — the first lane launch rebakes images at v${bin_version}, or REFUSES as a downgrade if that newest tag is an orphan of a build that was never installed (prune superseded tags first)."
fi
[ "$mode" = "--which" ] && exit 0

running_pid="$(pgrep -x "$(basename "$bin")" | head -1 || true)"
if [ -n "$running_pid" ]; then
    running_exe="$(readlink "/proc/$running_pid/exe" 2>/dev/null || echo unknown)"
    if [ "$running_exe" = "$bin" ] && [ "$mode" != "--restart" ]; then
        echo "already running from the install target (pid $running_pid) — nothing to do"; exit 0
    fi
    if [ "$mode" = "--restart" ]; then
        echo "stopping pid $running_pid ($running_exe)"; kill "$running_pid" 2>/dev/null; sleep 2
    else
        echo "a tray is running from a DIFFERENT binary: $running_exe (pid $running_pid) — re-run with --restart to replace it" >&2; exit 3
    fi
fi
echo "launching $bin"
setsid nohup "$bin" >/dev/null 2>&1 < /dev/null &
sleep 3
if p="$(pgrep -x "$(basename "$bin")" | head -1)" && [ -n "$p" ]; then echo "running: pid $p"; exit 0; fi
echo "launch.sh: the process did not stay up — run '$bin' in a terminal to see why" >&2; exit 1
