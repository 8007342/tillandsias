#!/usr/bin/env bash
# @trace spec:default-image, order:1437-y2wu
#
# test-claude-forge-bypass-preaccepted.sh — the bypass-permissions consent is
# a launch-time SEED, forge-gated, additive, never a value remembered from a
# previous session's Vault harvest (operator directive 2026-09-27: "we want
# to skip that bypass permissions confirmation, and pre-accept it ... for all
# projects, for all harnesses"; this fixture covers Claude only, the sibling
# packet 1437-q9ti covers the other harnesses).
#
# Four arms, each against a fresh scratch HOME (no shared state):
#   forge-empty        TILLANDSIAS_HOST_KIND=forge, no prior config at all ->
#                       both keys land, true, in the two files the spec names.
#   forge-preserves     an existing settings.json/claude.json with unrelated
#                       keys keeps them; the seed only adds its own two keys.
#   forge-false-stays   an existing explicit `false` for either key is left
#                       alone — the seed is additive, never a revocation, and
#                       jq's `//` treats `false` as absent, so this arm also
#                       catches that footgun if it creeps back in.
#   non-forge-noop      TILLANDSIAS_HOST_KIND unset: the function writes
#                       NOTHING — neither file is created or touched.
#
# Pre-fix (origin/linux-next before this packet): seed_claude_bypass_consent
# does not exist at all, so `declare -F` fails and every arm that depends on
# calling it FAILS closed, loudly, rather than passing vacuously.
#
# lib-common.sh is never sourced whole here: its top level unconditionally
# calls init_runtime_ca_trust, which hard-fails outside the forge image
# (images/default/lib-common.sh:1, and see scripts/test-opencode-vault-auth-
# content.sh / scripts/test-forge-project-guard-hooks.sh for the same
# extraction pattern). Only the one function under test is eval'd out.
#
# No new jq call sites: every assertion below reads the written JSON with
# grep, not jq or `tillandsias-plan json get` — the files this fixture
# produces are small and fully controlled, so a plain pattern match is both
# sufficient and keeps scripts/check-jq-callsite-ratchet.sh's floor for this
# brand-new file at zero.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/images/default/lib-common.sh"

[ -r "$LIB" ] || { echo "FAIL: cannot read $LIB" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed on this host" >&2; exit 0; }

fails=0
fail() {
    echo "FAIL: $*" >&2
    fails=$((fails + 1))
}

# trace_lifecycle is a lib-common.sh helper called by the function under
# test; stub it exactly as the sibling extraction fixtures do.
trace_lifecycle() { :; }

# Source only seed_claude_bypass_consent — never the whole file.
eval "$(sed -n '/^seed_claude_bypass_consent()/,/^}/p' "$LIB")"
declare -F seed_claude_bypass_consent >/dev/null \
    || { echo "FAIL: could not load seed_claude_bypass_consent from lib-common.sh (pre-fix: expected)" >&2; exit 1; }

# key_true FILE KEY -> 0 if FILE contains KEY set to boolean true
key_true() {
    [ -f "$1" ] && grep -qE '"'"$2"'"[[:space:]]*:[[:space:]]*true' "$1"
}
# key_false FILE KEY -> 0 if FILE contains KEY set to boolean false
key_false() {
    [ -f "$1" ] && grep -qE '"'"$2"'"[[:space:]]*:[[:space:]]*false' "$1"
}
# has_key FILE KEY -> 0 if FILE mentions KEY at all (true or false)
has_key() {
    [ -f "$1" ] && grep -qE '"'"$2"'"[[:space:]]*:' "$1"
}

fresh_home() {
    WORK="$(mktemp -d)"
    export HOME="$WORK/home"
    mkdir -p "$HOME"
    unset CLAUDE_CONFIG_FILE CLAUDE_SETTINGS_FILE
}

# ── Arm 1: forge, empty HOME, no prior config ───────────────────────────────
fresh_home
export TILLANDSIAS_HOST_KIND=forge
seed_claude_bypass_consent || fail "arm forge-empty: seed_claude_bypass_consent returned non-zero"
CFG="$HOME/.claude.json"
SET="$HOME/.claude/settings.json"
key_true "$CFG" bypassPermissionsModeAccepted \
    || fail "arm forge-empty: bypassPermissionsModeAccepted not true in $CFG"
key_true "$SET" skipDangerousModePermissionPrompt \
    || fail "arm forge-empty: skipDangerousModePermissionPrompt not true in $SET"
rm -rf "$WORK"

# ── Arm 2: forge, existing files with unrelated keys ────────────────────────
fresh_home
export TILLANDSIAS_HOST_KIND=forge
CFG="$HOME/.claude.json"
SET="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
printf '{"hasCompletedOnboarding": true, "theme": "dark", "projects": {"/x": {"hasTrustDialogAccepted": true}}}\n' >"$CFG"
printf '{"someOtherSetting": "kept", "mcpServers": {"foo": {}}}\n' >"$SET"
seed_claude_bypass_consent || fail "arm forge-preserves: seed_claude_bypass_consent returned non-zero"
key_true "$CFG" bypassPermissionsModeAccepted \
    || fail "arm forge-preserves: bypassPermissionsModeAccepted not seeded true in $CFG"
key_true "$SET" skipDangerousModePermissionPrompt \
    || fail "arm forge-preserves: skipDangerousModePermissionPrompt not seeded true in $SET"
grep -qE '"hasCompletedOnboarding"[[:space:]]*:[[:space:]]*true' "$CFG" \
    || fail "arm forge-preserves: pre-existing hasCompletedOnboarding lost from $CFG"
grep -qE '"/x"' "$CFG" \
    || fail "arm forge-preserves: pre-existing projects entry lost from $CFG"
grep -qE '"someOtherSetting"[[:space:]]*:[[:space:]]*"kept"' "$SET" \
    || fail "arm forge-preserves: pre-existing someOtherSetting lost from $SET"
grep -qE '"mcpServers"' "$SET" \
    || fail "arm forge-preserves: pre-existing mcpServers lost from $SET"
rm -rf "$WORK"

# ── Arm 3: forge, an existing explicit false stays false (additive, never a
#    revocation; also the jq `//`-treats-false-as-absent regression guard) ──
fresh_home
export TILLANDSIAS_HOST_KIND=forge
CFG="$HOME/.claude.json"
SET="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
printf '{"bypassPermissionsModeAccepted": false}\n' >"$CFG"
printf '{"skipDangerousModePermissionPrompt": false}\n' >"$SET"
seed_claude_bypass_consent || fail "arm forge-false-stays: seed_claude_bypass_consent returned non-zero"
key_false "$CFG" bypassPermissionsModeAccepted \
    || fail "arm forge-false-stays: explicit false in $CFG was overwritten"
key_false "$SET" skipDangerousModePermissionPrompt \
    || fail "arm forge-false-stays: explicit false in $SET was overwritten"
rm -rf "$WORK"

# ── Arm 4: non-forge (TILLANDSIAS_HOST_KIND unset) writes NOTHING ──────────
fresh_home
unset TILLANDSIAS_HOST_KIND
CFG="$HOME/.claude.json"
SET="$HOME/.claude/settings.json"
seed_claude_bypass_consent
rc=$?
[ "$rc" -eq 0 ] || fail "arm non-forge-noop: seed_claude_bypass_consent returned $rc (expected 0, a clean no-op)"
[ ! -e "$CFG" ] || fail "arm non-forge-noop: $CFG was created though TILLANDSIAS_HOST_KIND is unset"
[ ! -e "$SET" ] || fail "arm non-forge-noop: $SET was created though TILLANDSIAS_HOST_KIND is unset"
[ ! -e "$HOME/.claude" ] || fail "arm non-forge-noop: $HOME/.claude was created though TILLANDSIAS_HOST_KIND is unset"
rm -rf "$WORK"

# ── Arm 4b: non-forge over an EXISTING config also touches nothing ─────────
fresh_home
unset TILLANDSIAS_HOST_KIND
CFG="$HOME/.claude.json"
SET="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
printf '{"hasCompletedOnboarding": true}\n' >"$CFG"
printf '{"someOtherSetting": "kept"}\n' >"$SET"
before_cfg="$(cat "$CFG")"
before_set="$(cat "$SET")"
seed_claude_bypass_consent
rc=$?
[ "$rc" -eq 0 ] || fail "arm non-forge-existing: seed_claude_bypass_consent returned $rc (expected 0)"
[ "$(cat "$CFG")" = "$before_cfg" ] || fail "arm non-forge-existing: $CFG was modified though TILLANDSIAS_HOST_KIND is unset"
[ "$(cat "$SET")" = "$before_set" ] || fail "arm non-forge-existing: $SET was modified though TILLANDSIAS_HOST_KIND is unset"
has_key "$CFG" bypassPermissionsModeAccepted \
    && fail "arm non-forge-existing: bypassPermissionsModeAccepted appeared in $CFG"
has_key "$SET" skipDangerousModePermissionPrompt \
    && fail "arm non-forge-existing: skipDangerousModePermissionPrompt appeared in $SET"
rm -rf "$WORK"

if [ "$fails" -gt 0 ]; then
    echo "FAIL: $fails assertion(s) failed" >&2
    exit 1
fi
echo "PASS: claude forge bypass-permissions consent pre-accepted (4 arms, 6 assertions grouped)"
