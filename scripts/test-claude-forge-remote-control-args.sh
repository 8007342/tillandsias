#!/usr/bin/env bash
# @trace spec:default-image
#
# test-claude-forge-remote-control-args.sh — the Claude forge entrypoint joins
# Remote Control named after TILLANDSIAS_CLAUDE_SESSION_NAME, only when the
# installed claude advertises --remote-control.
#
# Arms (stub CC_BIN, function eval'd out of the entrypoint):
#   supported   name set, --help mentions --remote-control -> args appended
#   unsupported name set, --help lacks it                  -> nothing appended
#   unset       no name                                    -> nothing appended
# Pre-fix: append_claude_remote_control_args does not exist -> FAIL.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EP="$ROOT/images/default/entrypoint-forge-claude.sh"
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

eval "$(sed -n '/^append_claude_remote_control_args()/,/^}/p' "$EP")"
declare -F append_claude_remote_control_args >/dev/null \
    || { echo "FAIL: append_claude_remote_control_args missing from $EP" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-rc-args.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
printf '#!/bin/sh\necho "  --remote-control [name]  Start remote control"\n' >"$WORK/claude-rc"
printf '#!/bin/sh\necho "  -p, --print"\n' >"$WORK/claude-old"
chmod +x "$WORK/claude-rc" "$WORK/claude-old"

CC_BIN="$WORK/claude-rc"
TILLANDSIAS_CLAUDE_SESSION_NAME="tillandsias-forge"
claude_forge_args=(--dangerously-skip-permissions)
append_claude_remote_control_args
[ "${claude_forge_args[*]}" = "--dangerously-skip-permissions --remote-control tillandsias-forge --name tillandsias-forge" ] \
    || fail "supported: got '${claude_forge_args[*]}'"

CC_BIN="$WORK/claude-old"
claude_forge_args=()
append_claude_remote_control_args
[ "${#claude_forge_args[@]}" -eq 0 ] || fail "unsupported: got '${claude_forge_args[*]}'"

CC_BIN="$WORK/claude-rc"
unset TILLANDSIAS_CLAUDE_SESSION_NAME
claude_forge_args=()
append_claude_remote_control_args
[ "${#claude_forge_args[@]}" -eq 0 ] || fail "unset: got '${claude_forge_args[*]}'"

# Wiring: the entrypoint actually calls it.
grep -q '^append_claude_remote_control_args$' "$EP" || fail "entrypoint never calls append_claude_remote_control_args"

[ "$fails" -eq 0 ] || exit 1
echo "PASS: claude forge remote-control args (3 arms + wiring)"
