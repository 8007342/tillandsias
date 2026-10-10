#!/usr/bin/env bash
# @trace order:1437-evzi, spec:host-state-lifecycle
set -uo pipefail

# Fixture for scripts/uninstall.sh's up-front destructive confirmation.
#
# Operator ruling 2026-10-08, verbatim: "a destructive approval on uninstall,
# particularly since the vault getting destroyed means even on reinstall a user
# would need to re-login, so on uninstall a big detailed prompt is acceptable.
# Make sure it has big shiny red signs to make sure that this is a destructive
# step and cannot be undone, although it is intended during uninstall."
#
# Hermetic: a scratch HOME under <worktree>/target (never /tmp, never the real
# HOME), a fake install tree, and PATH-prefixed stubs for every external command
# uninstall.sh may call. The confirmation answer is fed through the
# TILLANDSIAS_UNINSTALL_TTY seam. Nothing touches a real keyring, podman store
# or install.
#
# UNINSTALL=<path> runs the fixture against another copy of the script (used to
# prove the arms are red on the pre-fix script).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNINSTALL="${UNINSTALL:-$ROOT/scripts/uninstall.sh}"
NAME="uninstall-confirms-before-destroying"
total=0
fail=0

[ -f "$UNINSTALL" ] || { echo "FAIL: no uninstall.sh at $UNINSTALL"; exit 1; }

check() {
    _name="$1"; _cond="$2"
    total=$((total + 1))
    if [ "$_cond" = "0" ]; then
        echo "ok: $_name"
    else
        echo "FAIL: $_name"
        fail=$((fail + 1))
    fi
}

mkdir -p "$ROOT/target"
WORK="$(mktemp -d "$ROOT/target/uninstall-confirms-fixture.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

STUBBIN="$WORK/stubbin"
mkdir -p "$STUBBIN"
for _c in podman pkill update-desktop-database userdel groupdel runuser loginctl systemctl launchctl; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBBIN/$_c"
    chmod +x "$STUBBIN/$_c"
done
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBBIN/pgrep"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBBIN/sudo"
chmod +x "$STUBBIN/pgrep" "$STUBBIN/sudo"

seed_home() {
    _h="$1"
    mkdir -p "$_h/.local/bin" "$_h/.local/lib/tillandsias" "$_h/.local/share/tillandsias/vault" \
             "$_h/.config/tillandsias" "$_h/.local/state/tillandsias" "$_h/.cache/tillandsias/models"
    echo "bin" > "$_h/.local/bin/tillandsias"
    echo "unin" > "$_h/.local/bin/tillandsias-uninstall"
    echo "lib" > "$_h/.local/lib/tillandsias/lib.so"
    echo "root-token" > "$_h/.local/share/tillandsias/vault/store"
    echo "cfg" > "$_h/.config/tillandsias/settings"
    echo "log" > "$_h/.local/state/tillandsias/log"
    echo "w" > "$_h/.cache/tillandsias/models/weights"
}

# Checksum listing of the whole fake tree: paths, modes and contents.
snapshot() {
    _snap_list="$(cd "$1" && find . \( -type f -o -type d \))"
    _snap_list="$(LC_ALL=C sort <<<"$_snap_list")"
    while read -r p; do
        if [ -f "$1/$p" ]; then
            _snap_sum="$(sha256sum "$1/$p")"
            printf "%s %s\n" "$p" "${_snap_sum%% *}"
        else
            printf "%s dir\n" "$p"
        fi
    done <<<"$_snap_list"
}

# run_u <home> <answer-file-or-path> [args...]  -> sets OUT and RC
run_u() {
    _home="$1"; _tty="$2"; shift 2
    OUT="$(HOME="$_home" PATH="$STUBBIN:$PATH" \
        TILLANDSIAS_UNINSTALL_TTY="$_tty" \
        TILLANDSIAS_UNINSTALL_APPS_DIR="$_home/Applications" \
        TILLANDSIAS_UNINSTALL_TRAY_PROC="nonce-tray-1437" \
        bash "$UNINSTALL" "$@" 2>&1 < /dev/null)"
    RC=$?
}

new_home() { _nh="$WORK/$1"; mkdir -p "$_nh"; seed_home "$_nh"; echo "$_nh"; }

cancel_arm() {
    _label="$1"; _ans="$2"
    _h="$(new_home "h-$_label")"
    printf '%s\n' "$_ans" > "$WORK/ans-$_label"
    _before="$(snapshot "$_h")"
    run_u "$_h" "$WORK/ans-$_label"
    _after="$(snapshot "$_h")"
    [ "$_before" = "$_after" ]; check "$_label-nothing-removed" "$?"
    [ "$RC" -ne 0 ]; check "$_label-rc-nonzero" "$?"
    case "$OUT" in *"Nothing was removed"*) check "$_label-says-nothing-removed" 0 ;; *) check "$_label-says-nothing-removed" 1 ;; esac
}

cancel_arm enter ""
cancel_arm no "no"
cancel_arm garbage "yes please"

# answer "delete" (case-insensitive) proceeds
h="$(new_home h-delete)"
printf 'DeLeTe\n' > "$WORK/ans-delete"
run_u "$h" "$WORK/ans-delete"
[ "$RC" -eq 0 ]; check "delete-rc-zero" "$?"
[ ! -e "$h/.local/bin/tillandsias" ] && [ ! -e "$h/.local/share/tillandsias" ] && [ ! -e "$h/.config/tillandsias" ]
check "delete-removes" "$?"
case "$OUT" in *"Uninstall complete"*) check "delete-reports-complete" 0 ;; *) check "delete-reports-complete" 1 ;; esac

# no tty, no --yes: refuse, name --yes, touch nothing
h="$(new_home h-notty)"
before="$(snapshot "$h")"
run_u "$h" "$WORK/does-not-exist"
after="$(snapshot "$h")"
[ "$before" = "$after" ]; check "notty-nothing-removed" "$?"
[ "$RC" -ne 0 ]; check "notty-rc-nonzero" "$?"
case "$OUT" in *"--yes"*) check "notty-names-yes-remedy" 0 ;; *) check "notty-names-yes-remedy" 1 ;; esac
# --yes is not advertised on the normal (asked) path
h="$(new_home h-quiet)"
printf '\n' > "$WORK/ans-quiet"
run_u "$h" "$WORK/ans-quiet"
case "$OUT" in *"--yes"*) check "yes-not-advertised-normally" 1 ;; *) check "yes-not-advertised-normally" 0 ;; esac

# no tty + --yes proceeds
h="$(new_home h-yes)"
run_u "$h" "$WORK/does-not-exist" --yes
[ "$RC" -eq 0 ] && [ ! -e "$h/.local/bin/tillandsias" ]; check "notty-yes-proceeds" "$?"

# flags in any order still set WIPE (the listing names the cache + images under WIPE)
for order in "--wipe --yes" "--yes --wipe"; do
    h="$(new_home "h-wipe-${order//[ -]/}")"
    # shellcheck disable=SC2086
    run_u "$h" "$WORK/does-not-exist" $order
    [ "$RC" -eq 0 ] && [ ! -e "$h/.cache/tillandsias" ]; check "wipe-order-[$order]-removes-cache" "$?"
done
h="$(new_home h-nowipe)"
run_u "$h" "$WORK/does-not-exist" --yes
[ -d "$h/.cache/tillandsias" ]; check "yes-alone-keeps-cache" "$?"

# colour arms
h="$(new_home h-pipe)"
printf '\n' > "$WORK/ans-pipe"
run_u "$h" "$WORK/ans-pipe"
case "$OUT" in *$'\033'*) check "pipe-has-no-escape-bytes" 1 ;; *) check "pipe-has-no-escape-bytes" 0 ;; esac
lc="$(tr "[:upper:]" "[:lower:]" <<<"$OUT")"
case "$lc" in *"cannot be undone"*"sign in again"*) check "pipe-warning-words" 0 ;; *) check "pipe-warning-words" 1 ;; esac

# Forced colour, piped (CLICOLOR_FORCE convention): red bytes and both phrases.
# The `[ -t 1 ]` branch itself is exercised only by hand (no pty tool is
# available to fixtures; scripts/ carries no extra language for one arm).
h="$(new_home h-force)"
CLICOLOR_FORCE=1 run_u "$h" "$WORK/ans-pipe"
case "$OUT" in *$'\033[1;31m'*) check "forced-has-bold-red" 0 ;; *) check "forced-has-bold-red" 1 ;; esac
fl="$(tr "[:upper:]" "[:lower:]" <<<"$OUT")"
case "$fl" in *"cannot be undone"*) check "forced-says-cannot-be-undone" 0 ;; *) check "forced-says-cannot-be-undone" 1 ;; esac
case "$fl" in *"sign in again"*) check "forced-says-sign-in-again" 0 ;; *) check "forced-says-sign-in-again" 1 ;; esac
[ -e "$h/.local/bin/tillandsias" ]; check "forced-cancel-removed-nothing" "$?"
# CLICOLOR_FORCE=0 is not force
CLICOLOR_FORCE=0 run_u "$h" "$WORK/ans-pipe"
case "$OUT" in *$'\033'*) check "force-zero-has-no-escape-bytes" 1 ;; *) check "force-zero-has-no-escape-bytes" 0 ;; esac
# NO_COLOR wins over CLICOLOR_FORCE
NO_COLOR=1 CLICOLOR_FORCE=1 run_u "$h" "$WORK/ans-pipe"
case "$OUT" in *$'\033'*) check "no-color-wins-over-force" 1 ;; *) check "no-color-wins-over-force" 0 ;; esac

if [ "$fail" -eq 0 ]; then
    echo "PASS: $NAME ($total checks)"
    exit 0
fi
echo "FAIL: $NAME ($fail of $total checks failed)"
exit 1
