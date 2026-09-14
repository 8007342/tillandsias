#!/bin/bash
# The single macOS destroy path both smoke runbooks call (803-49re: a second
# copy is where the fix does not go). Kills the tray, removes the VM state
# dir unconditionally, and removes the cache dir — unless
# TILLANDSIAS_RESET_KEEP_MODELS=1, in which case everything directly under
# the cache dir is removed EXCEPT models/, which is spared byte-identical
# (operator ruling 2026-09-14; 1181-bkem). Opt-in, per run, never the
# default: the 2026-09-13 reset ruling is that the clean room stays clean.
#
# Runs on any host: every path is derived from $HOME, and the only
# macOS-specific command is `pkill`, which is harmless (typically a no-op,
# since the pattern never matches) elsewhere.
#
# Usage: scripts/e2e-step2-macos.sh <LOG_DIR>
set -uo pipefail

LOG_DIR="$1"
mkdir -p "$LOG_DIR"

pkill -KILL -f 'Tillandsias.app/Contents/MacOS/tillandsias-tray' 2>/dev/null || true

VM_DIR="$HOME/Library/Application Support/tillandsias"
CACHE_DIR="$HOME/Library/Caches/tillandsias"
MODELS_DIR="$CACHE_DIR/models"

{ echo "[before]"; du -sh "$VM_DIR" "$CACHE_DIR" 2>/dev/null; } | tee "$LOG_DIR/02-destroy-before.txt"

rm -rf "$VM_DIR"

KEPT_MODELS=0
if [ "${TILLANDSIAS_RESET_KEEP_MODELS:-}" = "1" ]; then
  if [ -d "$CACHE_DIR" ]; then
    # Remove everything directly under CACHE_DIR except models/ itself.
    # A depth-1 find listing, not a glob, so dotfiles are swept too.
    find "$CACHE_DIR" -mindepth 1 -maxdepth 1 ! -name models -exec rm -rf {} +
    if [ -d "$MODELS_DIR" ]; then
      KEPT_MODELS=1
      MODELS_SIZE="$(du -sh "$MODELS_DIR" 2>/dev/null | cut -f1)"
      printf 'keep-models: spared %s (%s)\n' "$MODELS_DIR" "$MODELS_SIZE"
    else
      # Nothing to spare: the flag must not leave an EMPTY cache dir behind
      # as residue (the verifier's refutation, 2026-09-14). Say so by name
      # and fall through to the plain destroy.
      printf 'keep-models: nothing to spare (no models dir at %s)\n' "$MODELS_DIR"
      rm -rf "$CACHE_DIR"
    fi
  fi
else
  rm -rf "$CACHE_DIR"
fi

# Residue assertion: VM_DIR must be gone unconditionally. CACHE_DIR must be
# gone, OR (flag set) contain ONLY models/ — anything else under it is
# residue, named so a kept-models run cannot misread as a clean room.
MACOS_RESIDUE=""
[ -e "$VM_DIR" ] && MACOS_RESIDUE="${MACOS_RESIDUE}${VM_DIR}"$'\n'
if [ -e "$CACHE_DIR" ]; then
  if [ "$KEPT_MODELS" -eq 1 ]; then
    CACHE_ENTRIES="$(find "$CACHE_DIR" -mindepth 1 -maxdepth 1)"
    if [ -n "$CACHE_ENTRIES" ]; then
      while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        [ "$entry" = "$MODELS_DIR" ] && continue
        MACOS_RESIDUE="${MACOS_RESIDUE}${entry}"$'\n'
      done <<EOF
$CACHE_ENTRIES
EOF
    fi
  else
    MACOS_RESIDUE="${MACOS_RESIDUE}${CACHE_DIR}"$'\n'
  fi
fi

{
  echo "[after]"
  ls -la "$VM_DIR" 2>&1
  ls -la "$CACHE_DIR" 2>&1
  printf '[macos-residue]\n%s' "$MACOS_RESIDUE"
} | tee "$LOG_DIR/02-destroy-after.txt" >/dev/null
printf '[macos-residue]\n%s' "$MACOS_RESIDUE" | tee "$LOG_DIR/02-macos-residue.txt" >/dev/null

if [ -n "$MACOS_RESIDUE" ]; then
  echo "FAIL: residue"
  exit 1
fi

if [ "$KEPT_MODELS" -eq 1 ]; then
  echo 'ok:e2e-step2-macos:destroyed:kept-models'
else
  echo 'ok:e2e-step2-macos:destroyed'
fi
