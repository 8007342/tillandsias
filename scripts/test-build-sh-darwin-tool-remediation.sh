#!/usr/bin/env bash
# @trace order:851-gpb5, spec:dev-build
#
# Fixture for _require_host_build_tools' per-OS remediation (order 851-gpb5).
#
# WHAT WAS BROKEN. The function requires pkg-config (among others) and, on any
# failure, told EVERY host to "Install the Fedora build dependencies" — the
# first macOS host's very first `./build.sh --check` ended in remediation
# advice for a distribution it does not run. 723-whrx already established that
# --check/--test are supported paths on Darwin, so the message is reachable
# there, not hypothetical.
#
# HOW THIS TESTS IT. The function is extracted from build.sh (awk over the
# real bytes — a copy would drift) and run against a shim PATH that has every
# required tool EXCEPT pkg-config, with a shim `uname` whose output the
# scenario controls. That makes the behavioural arm hermetic and runnable on
# every host in the fleet, not only on a Mac: Linux hosts exercise the Darwin
# branch through the shim exactly as a Mac exercises it natively.
#
# MUTATION CONTROL. A mutant with the Darwin test neutered must turn exactly
# the Darwin scenario red (Fedora advice on a Mac) while the Linux scenario
# stays green — proving the branch, not the message, is what the fixture
# pins. The mutation is cmp-verified to have changed bytes; a sed that
# matched nothing removes nothing and certifies everything.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build.sh"
SKILL="$ROOT/skills/meta-orchestration/SKILL.md"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/darwin-tool-remediation.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
check() { # <name> <rc>
    if [ "$2" = "0" ]; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi
}

[ -f "$BUILD" ] || { echo "FAIL: no build.sh at $BUILD"; exit 1; }
bash -n "$BUILD"; check "build-sh-parses" "$?"

# ── Extract the function under test from the real file ───────────────────────
awk '/^_require_host_build_tools\(\) \{/,/^\}$/' "$BUILD" > "$WORK/fn.sh"
grep -q '_require_host_build_tools' "$WORK/fn.sh"
check "function-extracted" "$?"

# ── Shim PATH: every required tool but pkg-config; uname under our control ───
SHIMS="$WORK/shims"
mkdir -p "$SHIMS"
for t in cargo rustc rustfmt clippy-driver gcc; do
    printf '#!/bin/sh\nexit 0\n' > "$SHIMS/$t"
    chmod +x "$SHIMS/$t"
done
printf '#!/bin/sh\necho "${UNAME_FLAVOR:-Linux}"\n' > "$SHIMS/uname"
chmod +x "$SHIMS/uname"

# bash must be named ABSOLUTELY here: with the temporary PATH assignment in
# effect, the shell resolves the command word against the shim PATH, which
# deliberately contains no bash.
BASH_BIN="${BASH:-$(command -v bash)}"

run_fn() { # <uname-flavor> <fn-file> -> combined output; rc in $?
    UNAME_FLAVOR="$1" PATH="$SHIMS" "$BASH_BIN" -c '
        _error() { printf "%s\n" "$*"; }
        FLAG_INSTALL=false
        . "$1"
        _require_host_build_tools
    ' _ "$2" 2>&1
}

# ── Darwin: macOS remediation, not Fedora ────────────────────────────────────
out="$(run_fn Darwin "$WORK/fn.sh")"
rc=$?
[ "$rc" -ne 0 ]; check "darwin-missing-tool-still-refuses" "$?"
printf '%s' "$out" | grep -q 'Missing host build tools: pkg-config'
check "darwin-names-the-missing-tool" "$?"
printf '%s' "$out" | grep -q 'xcode-select --install'
check "darwin-remediation-names-xcode-clt" "$?"
printf '%s' "$out" | grep -q 'brew install pkg-config'
check "darwin-remediation-names-homebrew" "$?"
! printf '%s' "$out" | grep -q 'Fedora'
check "darwin-remediation-is-not-fedora" "$?"

# ── Linux (NEGATIVE CONTROL): Fedora advice survives, no macOS advice ────────
out="$(run_fn Linux "$WORK/fn.sh")"
rc=$?
[ "$rc" -ne 0 ]; check "linux-missing-tool-still-refuses" "$?"
printf '%s' "$out" | grep -q 'Fedora build dependencies'
check "linux-remediation-still-fedora" "$?"
! printf '%s' "$out" | grep -q 'xcode-select'
check "linux-remediation-is-not-macos" "$?"

# ── MUTATION CONTROL: neuter the Darwin test, Darwin scenario must go red ────
sed 's/"\$(uname -s)" == "Darwin"/"NEVER" == "Darwin"/' "$WORK/fn.sh" > "$WORK/fn-mutant.sh"
if cmp -s "$WORK/fn.sh" "$WORK/fn-mutant.sh"; then
    echo "FAIL  mutation-applied: sed changed nothing — the control proves nothing"
    fail=1
else
    echo "PASS  mutation-applied"
fi
out="$(run_fn Darwin "$WORK/fn-mutant.sh")"
printf '%s' "$out" | grep -q 'Fedora'
check "mutation-control-neutered-branch-gives-fedora-on-darwin" "$?"
out="$(run_fn Linux "$WORK/fn-mutant.sh")"
printf '%s' "$out" | grep -q 'Fedora build dependencies'
check "mutation-control-linux-path-unchanged" "$?"

# ── Docs pin (851-gpb5 defect 4): the skill names the macOS build path ───────
# build.sh's install refusal already names scripts/build-macos-tray.sh
# (723-whrx); the meta-orchestration skill did not, so the correct build path
# was undiscoverable from the loop's own runbook.
if [ -f "$SKILL" ]; then
    grep -q 'scripts/build-macos-tray.sh' "$SKILL"
    check "skill-names-the-macos-build-path" "$?"
else
    echo "PASS  skill-pin-skipped (no skills/meta-orchestration/SKILL.md here)"
fi

if [ "$fail" -eq 0 ]; then
    echo "ok:build-sh-darwin-tool-remediation-fixture:14"
    exit 0
fi
echo "FAIL: build-sh-darwin-tool-remediation fixture had failures"
exit 1
