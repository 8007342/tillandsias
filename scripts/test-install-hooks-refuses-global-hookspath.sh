#!/usr/bin/env bash
# @trace order:1442-wyf9, spec:forge-environment-discoverability
# test-install-hooks-refuses-global-hookspath.sh — scripts/install-hooks.sh must
# never write the repo guards into a GLOBAL core.hooksPath.
#
# A forge sets `git config --global core.hooksPath ~/.cache/tillandsias/git-hooks`.
# A second clone inside a forge has no local hooksPath, so `git rev-parse
# --git-path hooks` answers the global dir, and the installer used to write
# pre-commit and pre-push there, arming them in every repo on the box
# (macuahuitl-forge, 2026-09-27: 3 preflight guards refused through scratch repos).
#
# Branches:
#   1. global hooksPath, no local one → refused (exit 3), global dir untouched
#   2. local hooksPath set → installs into the LOCAL dir, global dir untouched
#   3. no hooksPath anywhere → installs into .git/hooks (unchanged behaviour)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/install-hooks-global.XXXXXX")"
trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# A scratch HOME so the fixture never reads or writes the real global config.
export HOME="$W/home" GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_GLOBAL XDG_CONFIG_HOME
mkdir -p "$HOME"
GLOBAL_HOOKS="$W/global-hooks"
mkdir -p "$GLOBAL_HOOKS"
printf '#!/bin/sh\nexit 0\n' >"$GLOBAL_HOOKS/prepare-commit-msg"

# A clone holding just what the installer reads.
make_clone() {
    local d="$1"
    mkdir -p "$d/scripts"
    cp "$ROOT/scripts/install-hooks.sh" "$d/scripts/"
    cp -R "$ROOT/scripts/hooks" "$d/scripts/"
    git -C "$d" init -q .
}
snapshot() { (cd "$GLOBAL_HOOKS" && ls -A | sort | tr '\n' ' '); }

# ── 1: global hooksPath only → refused, nothing written ─────────────────────
git config --global core.hooksPath "$GLOBAL_HOOKS"
before="$(snapshot)"
C="$W/second-clone"; make_clone "$C"
out="$(bash "$C/scripts/install-hooks.sh" 2>&1)"; rc=$?
[ "$rc" -eq 3 ] || fail "branch1: expected exit 3, got $rc: $out"
case "$out" in *"refused:install-hooks:global-hooks-path:"*) ;; *) fail "branch1: no refusal verdict: $out" ;; esac
case "$out" in *"config core.hooksPath"*) ;; *) fail "branch1: no affordance: $out" ;; esac
[ "$(snapshot)" = "$before" ] || fail "branch1: global hooks dir changed: '$before' -> '$(snapshot)'"
echo "ok: branch1 global hooksPath refused, global dir untouched ($before)"

# ── 2: local hooksPath → installs locally, global untouched ─────────────────
git -C "$C" config core.hooksPath "$C/.git/hooks"
out="$(bash "$C/scripts/install-hooks.sh" 2>&1)" || fail "branch2: installer failed: $out"
[ -x "$C/.git/hooks/pre-push" ] && [ -x "$C/.git/hooks/pre-commit" ] || fail "branch2: guards not installed locally"
[ "$(snapshot)" = "$before" ] || fail "branch2: global hooks dir changed"
echo "ok: branch2 local hooksPath installs locally"

# ── 3: no hooksPath anywhere → .git/hooks, as before ────────────────────────
git config --global --unset core.hooksPath
C3="$W/plain-clone"; make_clone "$C3"
out="$(bash "$C3/scripts/install-hooks.sh" 2>&1)" || fail "branch3: installer failed: $out"
[ -x "$C3/.git/hooks/pre-push" ] || fail "branch3: guards not installed into .git/hooks"
echo "ok: branch3 no hooksPath installs into .git/hooks"

echo "PASS: install-hooks refuses a global core.hooksPath (1442-wyf9)"
