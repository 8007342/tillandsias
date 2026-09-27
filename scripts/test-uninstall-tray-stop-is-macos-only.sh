#!/usr/bin/env bash
# test-uninstall-tray-stop-is-macos-only.sh — 1231-cbie, the platform-guard half.
#
# THE TEETH ARE ARM 1: a DECOY process whose argv merely CONTAINS the literal
# `tillandsias-tray` must survive a Linux uninstall. Pre-fix it did not — the
# ladder sat at column 0 under a macOS heading and sent SIGTERM then SIGKILL to
# anything matching `-f` on every platform, in a SHIPPED release artifact.
#
# A source-shape check ("is the block indented?") would be the mention-versus-use
# shape this tree has now hit six times. This runs the uninstaller and looks at
# whether the decoy is alive.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

U="$ROOT/scripts/uninstall.sh"
[ -f "$U" ] || { echo "skip:uninstall-tray-stop:no-uninstaller"; echo "uninstall-tray-stop-is-macos-only: 0 passed, 0 failed (skipped)"; exit 0; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT INT TERM

# A decoy that merely MENTIONS the literal. Split so this fixture does not carry
# the string it tests for — the guard's own scan would otherwise match the
# fixture (learned on 1234-zade, same night).
_lit="tillandsias""-tray"
decoy_script="$W/decoy.sh"
printf '#!/usr/bin/env bash\nsleep 120\n' > "$decoy_script"; chmod +x "$decoy_script"
"$decoy_script" "$_lit" >/dev/null 2>&1 &
decoy_pid=$!
sleep 0.3

if ! kill -0 "$decoy_pid" 2>/dev/null; then
    bad "SETUP: the decoy did not start; nothing below measures anything"
else
    # ARM 1 — the teeth.
    TILLANDSIAS_UNINSTALL_APPS_DIR="$W/Applications" \
    TILLANDSIAS_UNINSTALL_TRAY_PROC="nonce-tray-1401" \
    TILLANDSIAS_UNINSTALL_FAKE_UNAME="Linux" \
    TILLANDSIAS_UNINSTALL_INSTALL_DIR="$W/bin" \
    HOME="$W" bash "$U" --yes >/dev/null 2>&1 || true
    sleep 1.2
    if kill -0 "$decoy_pid" 2>/dev/null; then
        ok "ARM 1 (teeth): a process merely MENTIONING the literal survives a Linux uninstall — the ladder no longer fires off-Darwin"
    else
        bad "ARM 1: the decoy was KILLED by a Linux uninstall — the platform guard is not holding"
    fi
    kill -9 "$decoy_pid" 2>/dev/null || true
fi

# ARM 2 — POSITIVE CONTROL on the guard's own condition. Arm 1 passing because
# the uninstaller crashed early would look identical, so assert the Darwin arm
# is reachable and takes the branch.
out_mac="$(TILLANDSIAS_UNINSTALL_APPS_DIR="$W/Applications" TILLANDSIAS_UNINSTALL_TRAY_PROC="nonce-tray-1401" TILLANDSIAS_UNINSTALL_FAKE_UNAME="Darwin" TILLANDSIAS_UNINSTALL_INSTALL_DIR="$W/bin2" HOME="$W" bash -x "$U" --yes 2>&1 | grep -c 'IS_MACOS.*=.*true' || true)"
if [ "${out_mac:-0}" -gt 0 ]; then
    ok "ARM 2 (positive control): the Darwin arm is REACHED and sets IS_MACOS=true — arm 1 is a guard holding, not an uninstaller dying early"
else
    bad "ARM 2: could not observe the Darwin arm being taken; arm 1 may be passing for the wrong reason"
fi

# ARM 3 — the guard is a PLATFORM test, not a deletion. The stop must still
# exist in the source for the Darwin path; a fix that removed it would pass
# arm 1 and lose the 12-minute-survivor defect uninstall.sh:248-254 records.
# MATCHER-AGNOSTIC BY CONSTRUCTION (1231-cbie, second half). This arm used to
# assert the literal `pkill -KILL -f tillandsias-tray`, which pinned the very
# spelling this packet exists to replace: narrowing `-f` to `-x` made the arm
# report "the tray stop was removed" about a stop that is still there. The
# PROPERTY is that a two-stage stop (TERM then KILL) still targets the tray on
# the Darwin path; HOW the tray is identified is deliberately not pinned.
#
# It stays TEXTUAL for the reason the sibling fixture records: a behavioural
# arm would have to run the real matcher and would kill a developer's live
# tray. A future move to a pidfile or launchctl WILL need this arm revisited —
# that is honest, and better than an assertion that silently accepts anything.
# 1401-p3k7: the stop targets a seam whose DEFAULT is the tray's name, so accept
# either spelling, and require the default when the seam is used.
_tgt='(tillandsias-tray|"[$]_tray")'
if /usr/bin/grep -qE "pkill -TERM( -[a-zA-Z])? $_tgt" "$U" \
   && /usr/bin/grep -qE "pkill -KILL( -[a-zA-Z])? $_tgt" "$U" \
   && { ! /usr/bin/grep -qF '"$_tray"' "$U" || /usr/bin/grep -qF 'TILLANDSIAS_UNINSTALL_TRAY_PROC:-tillandsias-tray}' "$U"; }; then
    ok "ARM 3: the two-stage stop still EXISTS for the Darwin path — guarded, not deleted"
else
    bad "ARM 3: the tray stop was removed rather than guarded — that trades this defect for the one 978/848 recorded"
fi

# ARM 4 (1401-p3k7) — a faked uname WITHOUT the sandbox seams is REFUSED before
# anything runs. Every fixture faked HOME, but the /Applications sweep is
# absolute and the tray stop is by name, so on a Mac each gate run deleted the
# installed app. This arm runs under a stub PATH that only RECORDS rm, pkill and
# pgrep, so even an uninstaller that lost the refusal touches nothing real and
# the record is the evidence. PRE-FIX RESULT: FAILS, the record naming
# /Applications/Tillandsias.app and the tray stop.
S4="$W/stub4"; L4="$W/calls4.log"; mkdir -p "$S4" "$W/h4"; : > "$L4"
for c in rm pkill pgrep podman launchctl sleep; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 0\n' "$c" "$L4" > "$S4/$c"; chmod +x "$S4/$c"
done
out4="$(PATH="$S4:$PATH" TILLANDSIAS_UNINSTALL_FAKE_UNAME="Darwin" TILLANDSIAS_UNINSTALL_INSTALL_DIR="$W/bin4" HOME="$W/h4" bash "$U" --yes 2>&1)"; rc4=$?
if [ "$rc4" -eq 3 ] && [[ "$out4" == *"refused:uninstall:fake-uname-without-sandbox-seams"* ]] && [ ! -s "$L4" ]; then
    ok "ARM 4: a faked uname without the APPS_DIR/TRAY_PROC seams is refused (rc=3) before any rm or pkill"
else
    bad "ARM 4: a faked-Darwin uninstall without the seams was NOT refused (rc=$rc4); it would have run: $(tr '\n' ';' < "$L4")"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "ok:uninstall-tray-stop-is-macos-only"; echo "PASS: uninstall-tray-stop-is-macos-only $pass/$total (1231-cbie)"; exit 0; fi
echo "FAIL: uninstall-tray-stop-is-macos-only $pass/$total (1231-cbie)"; exit 1
