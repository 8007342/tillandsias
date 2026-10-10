#!/usr/bin/env bash
# @trace spec:host-state-lifecycle, order:1437-8c6p
#
# test-install-macos-setup-is-quiet.sh — install-macos.sh runs the SOFT reset,
# keeps the tray's reset output in the setup log, and prints no power-user text.
#
# Operator ruling 2026-10-08, verbatim: "we do not need to print any power user
# messages during install, at all. Install should be for END USER (NOT POWER
# USER) and be a pretty installer, rather than an informational/debugging
# installer." MEASURED on the v56.10.9.1 smoke (macbookair, 2026-10-09), the
# installer's terminal carried "TILLANDSIAS_DESTRUCTIVE_RESET_OK=0 skips the
# destruction" from install-macos.sh and "Skip the reset with
# TILLANDSIAS_DESTRUCTIVE_RESET_OK=0. This is the ONLY opt-out." from the tray.
#
# HOW IT TESTS. The real installer quits a running tray and writes
# /Applications, so it never runs here. This RUNS the installer's own reset
# block (between `# BEGIN-SETUP-RESET` and `# END-SETUP-RESET`, extracted from
# the file, not copied) against a scratch HOME and a stub tray that prints the
# real banner's shape. Arms:
#   1 the reset block is found and runs
#   2 its terminal output has no TILLANDSIAS_ token and no flag name
#   3 the setup log holds the tray's banner
#   4 a failing reset exits non-zero, names the log, and stays quiet
#   5 the installer's code has exactly one reset call, --reset-state with stdin
#     from /dev/null, and no HARD path
#   6 no say/die text from the reset block to the end names a flag or variable
#   7 NEGATIVE CONTROL: the quietness detector flags the measured smoke line
# Pre-fix (origin/linux-next 259869048): FAILS arms 1-3, 5 and 6 — the block
# has no markers, and the legacy range prints both lines above.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/scripts/install-macos.sh"
fails=0
pass() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }
[ -r "$SRC" ] || { echo "could-not-run:install-macos-setup-is-quiet:no-installer"; exit 3; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Power-user text: a variable name or a flag. `--` followed by a letter.
noisy() { grep -E -- 'TILLANDSIAS_|(^|[^[:alnum:]-])--[a-z]' "$1"; }

block="$(awk '/^# BEGIN-SETUP-RESET/ { f = 1; next } /^# END-SETUP-RESET/ { f = 0 } f' "$SRC")"
if [ -n "$block" ]; then
    pass "1 the reset block is marked in the installer"
else
    bad "1 no # BEGIN-SETUP-RESET block in install-macos.sh"
    # Run what the installer has instead, so arms 2-4 measure the real text.
    block="$(awk '/ORDER 1286-4437/ { f = 1 } /^# ── login item/ { f = 0 } f' "$SRC")"
fi

# A stub tray printing the shape of the real reset banner (core
# announce_reset_plan plus the macOS SOFT body), exiting with $STUB_EXIT.
mkdir -p "$WORK/app/Contents/MacOS"
cat > "$WORK/app/Contents/MacOS/tillandsias-tray" <<'STUB'
#!/usr/bin/env bash
echo "[tillandsias] reset: SOFT" >&2
echo "[tillandsias] --reset-state: resetting local state before reprovisioning." >&2
echo "[tillandsias]   WILL BE PRESERVED:" >&2
echo "[tillandsias]   Skip the reset with TILLANDSIAS_DESTRUCTIVE_RESET_OK=0. This is the ONLY opt-out." >&2
echo "Already provisioned: /scratch/rootfs.img"
exit "${STUB_EXIT:-0}"
STUB
chmod +x "$WORK/app/Contents/MacOS/tillandsias-tray"

run_block() { # $1 = stub exit; terminal output to $WORK/term.$1
    HOME="$WORK/home.$1" DEST="$WORK/app" STUB_EXIT="$1" BLOCK="$block" \
        bash -c 'set -euo pipefail
                 say() { printf "  %s\n" "$*"; }
                 die() { printf "  ERROR: %s\n" "$*" >&2; exit 1; }
                 eval "$BLOCK"' >"$WORK/term.$1" 2>&1
}

run_block 0
rc=$?
if [ "$rc" -eq 0 ]; then pass "1b the block runs to completion against a passing tray"; else bad "1b the block exited $rc against a passing tray"; fi
if hits="$(noisy "$WORK/term.0")"; then
    bad "2 power-user text on the terminal: $(printf '%s' "$hits" | tr '\n' '|' | cut -c1-300)"
else
    pass "2 no TILLANDSIAS_ token and no flag name on the terminal"
fi
LOG="$WORK/home.0/Library/Logs/Tillandsias/setup.log"
if [ -r "$LOG" ] && grep -q 'WILL BE PRESERVED' "$LOG" && grep -q 'reset: SOFT' "$LOG"; then
    pass "3 the setup log holds the tray's banner"
else
    bad "3 the tray's banner is not in $LOG"
fi

run_block 7
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'Library/Logs/Tillandsias/setup.log' "$WORK/term.7" && ! noisy "$WORK/term.7" >/dev/null; then
    pass "4 a failing reset exits $rc, names the log, and stays quiet"
else
    bad "4 failing reset: rc=$rc, terminal: $(tr '\n' '|' < "$WORK/term.7" | cut -c1-300)"
fi

# 5 — one SOFT call, stdin from /dev/null, no HARD path in the installer's code.
code="$(sed -E 's/(^|[[:space:]])#.*//' "$SRC")"
calls="$(grep -c -- '--reset-state </dev/null' <<<"$code")" || true
hard=""
for tok in --reset-guest --approve-hard-reset TILLANDSIAS_HARD_RESET_APPROVED TILLANDSIAS_INSTALL_RESET; do
    grep -qF -- "$tok" <<<"$code" && hard="$hard $tok" # sigpipe-ok: herestring, no upstream writer
done
if [ "$calls" = 1 ] && [ -z "$hard" ]; then
    pass "5 exactly one --reset-state call, stdin from /dev/null, no HARD path"
else
    bad "5 reset calls=$calls hard=[$hard]"
fi

# 6 — the text of every say/die from the reset block to the end, variables
# dropped (a reader sees the value, not its name). The --login-item line echoes
# a flag the user passed themselves, so it is not power-user text.
tail_said="$(awk '/^# BEGIN-SETUP-RESET|ORDER 1286-4437/ { f = 1 } f' "$SRC" \
    | sed -E 's/(^|[[:space:]])#.*//' \
    | grep -E '(^|[[:space:]])(say|die)[[:space:]]' \
    | grep -vF -- '--login-item' \
    | sed -E 's/\$\{[^}]*\}//g; s/\$[A-Za-z_][A-Za-z_0-9]*//g')"
printf '%s\n' "$tail_said" > "$WORK/said"
if hits="$(noisy "$WORK/said")"; then
    bad "6 say/die text names a flag or variable: $(printf '%s' "$hits" | tr '\n' '|' | cut -c1-300)"
else
    pass "6 no say/die text after the swap names a flag or variable"
fi

# 7 — NEGATIVE CONTROL: the detector catches the line the smoke measured.
printf '  resetting local state (--reset-state); TILLANDSIAS_DESTRUCTIVE_RESET_OK=0 skips the destruction\n' > "$WORK/dirty"
if noisy "$WORK/dirty" >/dev/null; then
    pass "7 NEGATIVE CONTROL: the measured smoke line is flagged"
else
    bad "7 the detector cannot see the measured smoke line"
fi

if [ "$fails" -ne 0 ]; then
    echo "fail:install-macos-setup-is-quiet:$fails"
    exit 1
fi
echo "ok:install-macos-setup-is-quiet:7 arms"
