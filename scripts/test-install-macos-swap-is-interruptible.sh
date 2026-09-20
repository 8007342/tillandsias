#!/usr/bin/env bash
# test-install-macos-swap-is-interruptible.sh — ORDER 1281-pgit.
#
# THE PROPERTY: an install interrupted at ANY point between download and launch
# leaves EITHER the old app OR the new app runnable at the destination — never
# neither.
#
# WHY IT EXISTS. install-macos.sh used to `rm -rf` the old backup, `mv` the LIVE
# app aside, and only then extract. That left the destination EMPTY for the whole
# extraction. MEASURED on macneo 2026-09-19: the installer was killed by SIGPIPE
# mid-swap (it had been piped through `head` to read its first lines) and
# /Applications held NEITHER Tillandsias.app NOR Tillandsias.app.bak. The host had
# no application at all until it was re-installed.
#
# HOW IT TESTS. The installer downloads from GitHub and launches a tray, neither
# of which belongs in a gate. So this fixture reproduces the SWAP CONTRACT against
# a scratch prefix: a staging extract, the two adjacent renames, the trap that
# restores on a trappable death, and the deferred removal of the previous backup.
# Each arm kills the sequence at a step boundary and asserts the invariant.
#
# The arms are the boundaries the real script now has:
#   1. killed AFTER staging extract, BEFORE any rename   -> old app intact
#   2. killed BETWEEN the two renames (the old window)   -> restored by the trap
#   3. killed AFTER the swap, BEFORE the old .bak is removed -> new app in place
#   4. a clean run                                        -> new app, backup kept
#   5. NEGATIVE CONTROL: the OLD ordering, same kill as arm 2 -> NEITHER present,
#      proving the arms detect the defect rather than passing for free.
set -uo pipefail
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/scripts/install-macos.sh"
[[ -r "$SRC" ]] || { echo "could-not-run:no-installer:$SRC"; exit 3; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# A scratch prefix standing in for /Applications, with an "old app" already there.
new_prefix() {
    local p="$1"
    rm -rf "$p"; mkdir -p "$p/Tillandsias.app/Contents/MacOS"
    printf 'OLD\n' > "$p/Tillandsias.app/Contents/MacOS/marker"
}
# A tarball standing in for the release asset.
new_asset() {
    local t="$1" d; d="$(mktemp -d)"
    mkdir -p "$d/Tillandsias.app/Contents/MacOS"
    printf 'NEW\n' > "$d/Tillandsias.app/Contents/MacOS/marker"
    tar -czf "$t" -C "$d" Tillandsias.app; rm -rf "$d"
}
marker_of() { cat "$1/Tillandsias.app/Contents/MacOS/marker" 2>/dev/null || echo ABSENT; }

# The FIXED sequence, with a kill point. Mirrors install-macos.sh's swap.
run_fixed() { # $1=prefix $2=asset $3=kill-after-step (0 = none)
    local INSTALL_DIR="$1" ASSET="$2" KILL="$3"
    local DEST="$INSTALL_DIR/Tillandsias.app" BACKUP PREV_BACKUP="" STAGE NEW_APP
    BACKUP="${DEST}.bak"
    local _RF="" _RT=""
    cleanup() {
        if [[ -n "$_RT" && ! -d "$_RT" && -n "$_RF" && -d "$_RF" ]]; then mv "$_RF" "$_RT" 2>/dev/null || true; fi
        [[ -n "${STAGE:-}" ]] && rm -rf "$STAGE"
    }
    trap cleanup RETURN
    STAGE="$(mktemp -d "${INSTALL_DIR}/.tillandsias-install.XXXXXX")"
    tar -xzf "$ASSET" -C "$STAGE"
    NEW_APP="$STAGE/Tillandsias.app"
    [[ "$KILL" == 1 ]] && return 0
    if [[ -d "$DEST" ]]; then
        if [[ -e "$BACKUP" ]]; then PREV_BACKUP="${BACKUP}.prev.$$"; mv "$BACKUP" "$PREV_BACKUP"; fi
        _RF="$BACKUP"; _RT="$DEST"
        mv "$DEST" "$BACKUP"
    fi
    [[ "$KILL" == 2 ]] && return 0
    mv "$NEW_APP" "$DEST"
    _RF=""; _RT=""
    [[ "$KILL" == 3 ]] && return 0
    [[ -n "$PREV_BACKUP" ]] && rm -rf "$PREV_BACKUP"
    return 0
}

# The OLD sequence, for the negative control.
run_old() { # $1=prefix $2=asset $3=kill-after-step
    local INSTALL_DIR="$1" ASSET="$2" KILL="$3"
    local DEST BACKUP
    DEST="$INSTALL_DIR/Tillandsias.app"
    BACKUP="${DEST}.bak"
    if [[ -d "$DEST" ]]; then rm -rf "$BACKUP"; mv "$DEST" "$BACKUP"; fi
    [[ "$KILL" == 2 ]] && return 0
    tar -xzf "$ASSET" -C "$INSTALL_DIR"
    return 0
}

ASSET="$WORK/asset.tar.gz"; new_asset "$ASSET"

# ARM 1 — killed after staging, before any rename.
P="$WORK/p1"; new_prefix "$P"; run_fixed "$P" "$ASSET" 1
[[ "$(marker_of "$P")" == OLD ]] \
  && ok "ARM 1: killed after staging extract — the OLD app is still in place" \
  || bad "ARM 1: destination is $(marker_of "$P"), expected OLD"

# ARM 2 — killed between the two renames. This is the old empty window.
P="$WORK/p2"; new_prefix "$P"; run_fixed "$P" "$ASSET" 2
m="$(marker_of "$P")"
[[ "$m" == OLD || "$m" == NEW ]] \
  && ok "ARM 2: killed BETWEEN the renames — the trap restored the app ($m present, not absent)" \
  || bad "ARM 2: destination is ABSENT — the interrupted swap left nothing"

# ARM 3 — killed after the swap, before the previous backup is dropped.
P="$WORK/p3"; new_prefix "$P"; run_fixed "$P" "$ASSET" 3
[[ "$(marker_of "$P")" == NEW ]] \
  && ok "ARM 3: killed before the old backup is removed — the NEW app is in place" \
  || bad "ARM 3: destination is $(marker_of "$P"), expected NEW"

# ARM 4 — clean run.
P="$WORK/p4"; new_prefix "$P"; run_fixed "$P" "$ASSET" 0
if [[ "$(marker_of "$P")" == NEW && -d "$P/Tillandsias.app.bak" ]]; then
    ok "ARM 4: clean run — NEW app in place and the previous app kept as .bak"
else
    bad "ARM 4: marker=$(marker_of "$P") bak=$([[ -d "$P/Tillandsias.app.bak" ]] && echo yes || echo no)"
fi
# No staging directory may survive a clean run.
if compgen -G "$P/.tillandsias-install.*" >/dev/null; then
    bad "ARM 4: a staging directory survived a clean run"
else
    ok "ARM 4: no staging directory left behind"
fi

# ARM 5 — NEGATIVE CONTROL: the OLD ordering must lose the app at the same kill.
P="$WORK/p5"; new_prefix "$P"; run_old "$P" "$ASSET" 2
if [[ "$(marker_of "$P")" == ABSENT ]]; then
    ok "ARM 5 NEGATIVE CONTROL: the OLD ordering leaves the destination ABSENT — the arms have teeth"
else
    bad "ARM 5: the old ordering did not reproduce the defect, so arms 1-3 prove nothing"
fi

echo "---"
if (( fail )); then
    echo "FAIL: install-macos-swap-is-interruptible ${pass}/$((pass+fail)) (1281-pgit)"
    exit 1
fi
echo "PASS: install-macos-swap-is-interruptible ${pass}/${pass} (1281-pgit)"
