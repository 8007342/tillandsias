#!/usr/bin/env bash
# @trace order:1505-42zx
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
launcher="${1:-$root/scripts/configure-codex.sh}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

if ! bash "$launcher" --help >"$scratch/help"; then
  echo 'FAIL: launcher help did not succeed' >&2
  exit 1
fi
if rg -q -- '--seed-github-token' "$scratch/help"; then
  echo 'FAIL: rejected token-seeding mode is advertised' >&2
  exit 1
fi
for mode in --check --launch --login-codex; do
  if ! rg -q -- "$mode" "$scratch/help"; then
    echo "FAIL: missing launcher mode $mode" >&2
    exit 1
  fi
done

# Reject the old mode during parsing, before trying git, a terminal, stdin,
# or a credential command. An empty PATH stub cannot satisfy those calls.
if bash "$launcher" --seed-github-token < /dev/null >"$scratch/out" 2>"$scratch/err"; then
  echo 'FAIL: rejected mode succeeded' >&2
  exit 1
fi
if ! rg -q '^Usage: ' "$scratch/err"; then
  echo 'FAIL: rejected mode did not stop at usage' >&2
  exit 1
fi
if rg -q 'GitHub token for this host|Token entry requires' "$scratch/err"; then
  echo 'FAIL: rejected mode reached credential handling' >&2
  exit 1
fi
if rg -q -- 'seed-github-token|read -r -s token|--github-login --with-token' "$launcher"; then
  echo 'FAIL: credential-seeding path remains in launcher' >&2
  exit 1
fi
if ! rg -q 'exec tillandsias --codex-login' "$launcher" ||
   ! rg -q 'export TILLANDSIAS_FORGE_INSTANCE=' "$launcher" ||
   ! rg -q 'exec tillandsias "\$root" --codex' "$launcher"; then
  echo 'FAIL: device-login or namespaced launch dispatch changed' >&2
  exit 1
fi
echo 'ok:configure-codex:no-token-prompt'
