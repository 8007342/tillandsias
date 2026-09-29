#!/usr/bin/env bash
# Host-side Codex launcher. Run as the logged-in operator, never with sudo.
# @trace spec:git-mirror-service, order:1312-i6da, order:1025-a896, order:1505-42zx
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

usage() {
  printf '%s\n' \
    'Usage: scripts/configure-codex.sh [--check | --launch | --login-codex] [--instance NAME]' \
    '  --check              Diagnose this execution context (default; no writes)' \
    '  --launch             Check prerequisites, then start a namespaced Tillandsias Codex forge' \
    '  --login-codex        Operator-only: start Tillandsias Codex device login' \
    '  --instance NAME      Forge namespace (default: codex-worker)'
}

mode=check
instance=codex-worker
while (($#)); do
  case "$1" in
    --check|--launch|--login-codex) mode="${1#--}" ;;
    --instance) shift; (($#)) || { usage >&2; exit 2; }; instance="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

case "$instance" in
  ''|*[!a-zA-Z0-9_-]*) echo 'Invalid --instance: use letters, digits, _ or -.' >&2; exit 2 ;;
esac

if (( EUID == 0 )); then
  echo 'Run as your logged-in user, not sudo/root: root has a different keyring and Podman store.' >&2
  exit 1
fi

# A child cannot undo the mount/network policy of the process that launched it.
git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null || true)"
if [[ -z "$git_dir" || ! -w "$git_dir" ]]; then
  echo "blocked:git-dir-read-only:${git_dir:-missing}" >&2
  echo 'Run this script from your real host terminal (or a fresh Tillandsias forge); no token or Codex flag can make this existing mount writable.' >&2
  exit 1
fi

if [[ "$mode" == check ]]; then
  printf 'ok:git-dir-writable:%s\n' "$git_dir"
  if command -v tillandsias >/dev/null 2>&1; then
    printf 'ok:tillandsias:%s\n' "$(command -v tillandsias)"
  else
    echo 'blocked:tillandsias-not-installed' >&2
    exit 1
  fi
  if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    echo 'ok:podman-reachable'
  else
    echo 'blocked:podman-unreachable (use the real host user session)' >&2
    exit 1
  fi
  if [[ -x scripts/check-credential-channel.sh ]]; then
    scripts/check-credential-channel.sh
  else
    echo 'blocked:credential-check-missing' >&2
    exit 1
  fi
  exit 0
fi

if ! command -v tillandsias >/dev/null 2>&1; then
  echo 'Install the Tillandsias host binary before using this launcher.' >&2
  exit 1
fi

if [[ "$mode" == login-codex ]]; then
  [[ -t 0 ]] || { echo 'Codex device login requires an interactive terminal.' >&2; exit 1; }
  exec tillandsias --codex-login
fi

if ! command -v podman >/dev/null 2>&1 || ! podman info >/dev/null 2>&1; then
  echo 'Podman is not reachable from this shell; use the real host user session.' >&2
  exit 1
fi

# The credential guard verifies the host push channel, but a forge uses its
# own mirror/Vault channel. Its startup validates that channel independently.
# Do not copy host gh tokens or ~/.gitconfig into the forge.
echo "Launching a new Codex forge session with TILLANDSIAS_FORGE_INSTANCE=$instance."
echo 'This does not resume a session created by another API/managed harness.'
export TILLANDSIAS_FORGE_INSTANCE="$instance"
exec tillandsias "$root" --codex
