#!/usr/bin/env bash
# @trace spec:tillandsias-vault
set -uo pipefail

[[ "${1:-}" == -- ]] || { echo "Usage: codex-oauth-session -- COMMAND [ARG...]" >&2; exit 64; }
shift
[[ $# -gt 0 ]] || { echo "codex-oauth-session: missing command" >&2; exit 64; }

child_pid=''
watch_pid=''
VAULT_HELPER="${TILLANDSIAS_CODEX_VAULT_HELPER:-/usr/local/bin/codex-oauth-vault}"
initial_digest="$("$VAULT_HELPER" digest)"

forward_signal() {
    local signal="$1"
    if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
        kill -s "$signal" "$child_pid" 2>/dev/null || true
    fi
}
trap 'forward_signal TERM' TERM
trap 'forward_signal INT' INT

"$@" &
child_pid=$!
"$VAULT_HELPER" watch "$child_pid" "$initial_digest" &
watch_pid=$!

child_rc=0
while kill -0 "$child_pid" 2>/dev/null; do
    wait "$child_pid"
    wait_rc=$?
    if ! kill -0 "$child_pid" 2>/dev/null; then
        child_rc=$wait_rc
        break
    fi
done

kill "$watch_pid" 2>/dev/null || true
wait "$watch_pid" 2>/dev/null || true

# Final bounded attempt closes the race between the last poll and process exit.
timeout 10 "$VAULT_HELPER" harvest || \
    echo "WARNING: final Codex credential harvest failed; rerun tillandsias --codex-login if the next launch requests authentication." >&2

exit "$child_rc"
