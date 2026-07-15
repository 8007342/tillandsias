#!/usr/bin/env bash
# @trace spec:tillandsias-vault
# Run an interactive agent in the FOREGROUND while a background watcher
# harvests OAuth credential-file rotations to Vault, plus a final harvest on
# exit. So a mid-session refresh-token rotation and the final document both
# reach Vault, and the NEXT launch does not re-prompt.
#
# 2026-07-15 redesign: the previous version backgrounded the AGENT (`"$@" &`)
# and ran the harvest loop in the foreground. Backgrounding an interactive
# TUI detaches its stdin from the controlling terminal (and a background
# reader of the tty gets SIGTTIN), so `codex`/`claude`/`agy` died with
# "stdin is not a terminal" (operator repro 2026-07-15). Fix: the AGENT runs
# in the foreground (owns the tty, receives terminal signals directly), and
# the cheap credential-file WATCHER is the background job instead. The
# watcher polls until this wrapper's own PID exits; a final harvest closes
# the race between the last poll and exit. A hard `podman kill` of the whole
# container skips the final harvest — acceptable: the next login re-establishes.
set -uo pipefail

[[ "${1:-}" == -- ]] || { echo "Usage: codex-oauth-session -- COMMAND [ARG...]" >&2; exit 64; }
shift
[[ $# -gt 0 ]] || { echo "codex-oauth-session: missing command" >&2; exit 64; }

VAULT_HELPER="${TILLANDSIAS_CODEX_VAULT_HELPER:-/usr/local/bin/codex-oauth-vault}"
initial_digest="$("$VAULT_HELPER" digest)"

watch_pid=''
final_harvest() {
    [[ -n "$watch_pid" ]] && kill "$watch_pid" 2>/dev/null
    [[ -n "$watch_pid" ]] && wait "$watch_pid" 2>/dev/null
    timeout 10 "$VAULT_HELPER" harvest 2>/dev/null || \
        echo "WARNING: final credential harvest failed; rerun the provider login if the next launch requests authentication." >&2
}
trap final_harvest EXIT

# Background watcher tracks THIS wrapper's lifetime ($$) and harvests each
# credential-file change live. It never touches the terminal.
"$VAULT_HELPER" watch "$$" "$initial_digest" &
watch_pid=$!

# Foreground: the agent owns the controlling terminal — its stdin IS the tty,
# and Ctrl-C / terminal-close (SIGHUP) reach it directly. The EXIT trap
# harvests the final document after it returns.
"$@"
