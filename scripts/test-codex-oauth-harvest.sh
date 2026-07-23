#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT_HELPER="$ROOT/images/default/codex-oauth-vault.sh"
SESSION="$ROOT/images/default/codex-oauth-session.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/home/.codex" "$TMP/project" "$TMP/history"

cat >"$TMP/bin/vault-cli.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$CALL_LOG"
printf '\n' >>"$CALL_LOG"
case "$1" in
    read)
        cat "$VAULT_VALUE"
        ;;
    write-stdin)
        [[ "$2" == secret/codex/oauth ]]
        [[ "$3" == credentials_b64 ]]
        tmp="$(mktemp)"
        cat >"$tmp"
        mv "$tmp" "$VAULT_VALUE"
        count=0
        [[ -f "$HISTORY_DIR/count" ]] && count="$(cat "$HISTORY_DIR/count")"
        count=$((count + 1))
        printf '%s' "$count" >"$HISTORY_DIR/count"
        base64 -d <"$VAULT_VALUE" >"$HISTORY_DIR/$count.json"
        ;;
    *) exit 64 ;;
esac
EOF

cat >"$TMP/bin/codex-normal" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'argv:' >>"$CALL_LOG"
printf ' %q' "$@" >>"$CALL_LOG"
printf '\n' >>"$CALL_LOG"
mkdir -p "${CODEX_HOME:-$HOME/.codex}"
printf '{"models":["shared-wrapper-no-setup"]}\n' \
    >"${CODEX_HOME:-$HOME/.codex}/models_cache.json"
printf '{"access_token":"created-token"}\n' >"$TILLANDSIAS_CODEX_AUTH_FILE"
sleep 0.2
printf '{"access_token":"rotated-token"}\n' >"$TILLANDSIAS_CODEX_AUTH_FILE"
sleep 0.2
EOF

cat >"$TMP/bin/codex-signal" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
finish() {
    printf '{"access_token":"signal-token"}\n' >"$TILLANDSIAS_CODEX_AUTH_FILE"
    exit 143
}
trap finish TERM INT
# The agent runs in the FOREGROUND under the session wrapper (owns the tty),
# so a real terminal signal (Ctrl-C / SIGHUP on close) reaches THIS process
# directly, not the wrapper. Publish our pid so the test can signal the
# foreground app the way a terminal does.
echo "$$" >"$CHILD_PID_FILE"
touch "$READY_FILE"
while :; do sleep 1; done
EOF
chmod 755 "$TMP/bin/"*

export HOME="$TMP/home"
export PATH="$TMP/bin:$PATH"
export TILLANDSIAS_CODEX_AUTH_FILE="$HOME/.codex/auth.json"
export TILLANDSIAS_CODEX_VAULT_HELPER="$VAULT_HELPER"
export TILLANDSIAS_CODEX_STATE_HELPER="$ROOT/images/default/codex-safe-state.sh"
export PROJECT_CACHE="$TMP/project-cache"
export TILLANDSIAS_OAUTH_POLL_SECS=0.05
export VAULT_VALUE="$TMP/vault-value"
export HISTORY_DIR="$TMP/history"
export CALL_LOG="$TMP/calls.log"

# Claude and Antigravity also call this shared foreground wrapper. Even with a
# CODEX_HOME-shaped directory, merely sourcing the helper must not infer or
# flush a Codex state root unless the Codex entrypoint completed setup.
export CODEX_HOME="$HOME/.codex-shared-wrapper-fixture"
printf '{"access_token":"initial-token"}\n' >"$TILLANDSIAS_CODEX_AUTH_FILE"
"$SESSION" -- "$TMP/bin/codex-normal"
[[ ! -e "$PROJECT_CACHE/codex-state" ]]
unset CODEX_HOME

grep -R -Fq created-token "$HISTORY_DIR"
grep -R -Fq rotated-token "$HISTORY_DIR"
base64 -d <"$VAULT_VALUE" >"$TMP/final-normal.json"
grep -Fq rotated-token "$TMP/final-normal.json"

printf '{"access_token":"before-signal"}\n' >"$TILLANDSIAS_CODEX_AUTH_FILE"
export READY_FILE="$TMP/signal-ready"
export CHILD_PID_FILE="$TMP/signal-child-pid"
set +e
"$SESSION" -- "$TMP/bin/codex-signal" >"$TMP/session.log" 2>&1 &
session_pid=$!
set -e
for _ in {1..50}; do
    [[ -s "$CHILD_PID_FILE" ]] && break
    sleep 0.05
done
[[ -f "$READY_FILE" ]]
# Signal the FOREGROUND agent directly (what a terminal Ctrl-C/SIGHUP does),
# not the wrapper: with a tty-correct foreground child the wrapper cannot
# forward a wrapper-directed signal.
kill -TERM "$(cat "$CHILD_PID_FILE")"
set +e
timeout 5 tail --pid="$session_pid" -f /dev/null
wait "$session_pid"
signal_rc=$?
set -e
[[ "$signal_rc" -eq 143 ]]
base64 -d <"$VAULT_VALUE" >"$TMP/final-signal.json"
grep -Fq signal-token "$TMP/final-signal.json"

for secret in created-token rotated-token signal-token; do
    if grep -R -Fq "$secret" "$CALL_LOG" "$TMP/session.log" "$TMP/project"; then
        echo "credential leaked to argv, logs, or project" >&2
        exit 1
    fi
done

echo "PASS: Codex OAuth creation, rotation, and signal-exit harvest"
