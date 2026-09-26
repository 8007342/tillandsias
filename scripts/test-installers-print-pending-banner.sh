#!/usr/bin/env bash
# @trace order:1380-zmpi
#
# Fixture for the PENDING ACTIONS banner every installer ends with (design:
# plan/issues/forge-memory-swap-architecture-design-2026-09-26.md section 9.4).
# Operator, 2026-09-26: "print some big text with what's pending, like a
# restart for windows hosts where WSL was just enabled. Linux hosts should just
# print that sudo command."
#
# Each installer carries its banner between two exact-once marker lines. This
# fixture CUTS that block and RUNS it (bash for install.sh and
# install-macos.sh, PowerShell for install-windows.ps1's formatter) against
# stubbed inputs, rather than reading the source for idioms.
#
#   0  each installer has both markers exactly once (could-not-run otherwise)
#   L1 Linux, no helper installed: PENDING: none, and NO sudo line (a sudo
#      command that is not installed fails with "command not found")
#   L2 Linux, helper installed, unit absent: the exact sudo line, and no "none"
#   L3 Linux, helper installed, unit present: PENDING: none
#   M1 macOS: PENDING: none, printed rather than omitted
#   E  the banner is the LAST block of each POSIX installer (END marker is the
#      last non-blank line)
#   W1 Windows formatter, no items: PENDING: none
#   W2 Windows formatter, items: one ">> " line per item, and no "none"
#   W3 Windows wiring: reboot-pending maps to RESTART REQUIRED, and the
#      banner is printed after the install's finally block
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pending-banner-fixture.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fails=0
ran=0
skipped=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

# ARM 0: the cut, in all three.
for f in install.sh install-macos.sh install-windows.ps1; do
    src="$REPO_ROOT/scripts/$f"
    nb="$(grep -cx '# BEGIN-PENDING-BANNER' "$src")" || true
    ne="$(grep -cx '# END-PENDING-BANNER' "$src")" || true
    if [ "$nb" != "1" ] || [ "$ne" != "1" ]; then
        echo "could-not-run:pending-banner-fixture:markers:$f:begin=$nb:end=$ne"
        echo "why: the fixture runs each banner by cutting it between two marker lines, which must each occur once" >&2
        echo "fix: restore the BEGIN-PENDING-BANNER / END-PENDING-BANNER lines in scripts/$f" >&2
        exit 3
    fi
    sed -n '/^# BEGIN-PENDING-BANNER$/,/^# END-PENDING-BANNER$/p' "$src" > "$TMP/$f.cut"
done
ran=$((ran + 1))

# The POSIX banners, run with stubbed inputs. PATH is narrowed so a host that
# really has the helper cannot leak into L1.
run_linux() {   # run_linux <install-dir> <unit-path>
    env -i PATH=/usr/bin:/bin INSTALL_DIR="$1" TILLANDSIAS_SWAP_UNIT="$2" \
        bash "$TMP/install.sh.cut" 2>&1
}
idir="$TMP/bin"
mkdir -p "$idir"
unit="$TMP/tillandsias-swap@.service"

out="$(run_linux "$idir" "$unit")"
ran=$((ran + 1))
case "$out" in *"PENDING: none"*) ;; *) fail "L1 no helper — no PENDING: none: $out" ;; esac
case "$out" in *sudo*) fail "L1 no helper — printed a sudo line for a command that is not installed" ;; esac

printf '#!/bin/sh\nexit 0\n' > "$idir/tillandsias-install-swap-service"
chmod +x "$idir/tillandsias-install-swap-service"
out="$(run_linux "$idir" "$unit")"
ran=$((ran + 1))
case "$out" in *"  sudo $idir/tillandsias-install-swap-service"*) ;; *) fail "L2 helper, no unit — no exact sudo line: $out" ;; esac
case "$out" in *"PENDING: none"*) fail "L2 helper, no unit — also claimed nothing is pending" ;; esac
case "$out" in *"PENDING ACTIONS"*) ;; *) fail "L2 no PENDING ACTIONS heading" ;; esac

: > "$unit"
out="$(run_linux "$idir" "$unit")"
ran=$((ran + 1))
case "$out" in *"PENDING: none"*) ;; *) fail "L3 unit installed — still pending: $out" ;; esac

out="$(env -i PATH=/usr/bin:/bin bash "$TMP/install-macos.sh.cut" 2>&1)"
ran=$((ran + 1))
case "$out" in *"PENDING ACTIONS"*"PENDING: none"*) ;; *) fail "M1 macOS — no PENDING: none banner: $out" ;; esac

# E: nothing prints after the banner in the POSIX installers.
for f in install.sh install-macos.sh; do
    ran=$((ran + 1))
    last="$(grep -v '^[[:space:]]*$' "$REPO_ROOT/scripts/$f" | tail -1)"
    [ "$last" = "# END-PENDING-BANNER" ] || fail "E $f — the banner is not the last block (last line: $last)"
done

# W3: Windows wiring, from the source (the whole installer cannot run here).
ran=$((ran + 1))
win="$REPO_ROOT/scripts/install-windows.ps1"
grep -q "if (\$WslState -eq 'reboot-pending') {" "$win" && grep -q "RESTART REQUIRED: WSL was just enabled" "$win" \
    || fail "W3 reboot-pending does not map to RESTART REQUIRED"
fin="$(grep -n '^} finally {' "$win" | tail -1 | cut -d: -f1)"
ban="$(grep -n 'Format-PendingBanner -Items' "$win" | tail -1 | cut -d: -f1)"
[ -n "$fin" ] && [ -n "$ban" ] && [ "$ban" -gt "$fin" ] \
    || fail "W3 the banner is not printed after the install's finally block (finally=$fin banner=$ban)"

PWSH="$(command -v pwsh || command -v powershell || true)"
if [ -z "$PWSH" ]; then
    echo "skip:pending-banner-fixture:W1-W2:no-powershell-on-this-host" >&2
    skipped=$((skipped + 2))
else
    winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
    cp "$TMP/install-windows.ps1.cut" "$TMP/banner.ps1"
    cat > "$TMP/runw.ps1" <<'PS'
param([string]$Cut)
. $Cut
"---none---"
Format-PendingBanner -Items @()
"---items---"
Format-PendingBanner -Items @('RESTART REQUIRED: x', 'SIGN OUT AND BACK IN: y')
PS
    out="$("$PWSH" -NoProfile -ExecutionPolicy Bypass -File "$(winpath "$TMP/runw.ps1")" -Cut "$(winpath "$TMP/banner.ps1")" 2>&1 | tr -d '\r')"
    none="$(sed -n '/^---none---$/,/^---items---$/p' <<<"$out")"
    items="$(sed -n '/^---items---$/,$p' <<<"$out")"
    ran=$((ran + 1))
    case "$none" in *"PENDING ACTIONS"*"PENDING: none"*) ;; *) fail "W1 no items — got: $none" ;; esac
    ran=$((ran + 1))
    n="$(grep -c '^  >> ' <<<"$items")" || true
    [ "$n" = "2" ] || fail "W2 two items — got $n '>> ' lines: $items"
    case "$items" in *"PENDING: none"*) fail "W2 items present but also printed PENDING: none" ;; esac
fi

if [ "$fails" -ne 0 ]; then
    echo "refused:pending-banner-fixture:failed=$fails ran=$ran skipped=$skipped"
    exit 1
fi
echo "ok:pending-banner-fixture:ran=$ran skipped=$skipped"
