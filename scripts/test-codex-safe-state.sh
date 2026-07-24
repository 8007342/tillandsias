#!/usr/bin/env bash
# @trace spec:default-image
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/images/default/codex-safe-state.sh"
SESSION="$ROOT/images/default/codex-oauth-session.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
export PROJECT_CACHE="$WORK/project-cache"
mkdir -p "$HOME" "$PROJECT_CACHE"
# shellcheck source=../images/default/codex-safe-state.sh
source "$HELPER"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Worker keys are full exact-identity digests. Host-normalized pairs, newlines,
# and differences after the host's length cap remain separately namespaced.
export CODEX_HOME="$HOME/.codex-Worker.One"
unset TILLANDSIAS_CODEX_STATE_WORKER
worker_dot_key="$(codex_safe_state_worker_key)"
[[ "$worker_dot_key" =~ ^worker-[0-9a-f]{64}$ ]]
export CODEX_HOME="$HOME/.codex-worker-one"
worker_dash_key="$(codex_safe_state_worker_key)"
[[ "$worker_dash_key" =~ ^worker-[0-9a-f]{64}$ ]]
[[ "$worker_dot_key" != "$worker_dash_key" ]] \
    || fail "distinct raw worker identities collided"
export TILLANDSIAS_CODEX_STATE_WORKER="a b"
worker_space_key="$(codex_safe_state_worker_key)"
export TILLANDSIAS_CODEX_STATE_WORKER="a-b"
worker_hyphen_key="$(codex_safe_state_worker_key)"
[[ "$worker_space_key" != "$worker_hyphen_key" ]] \
    || fail "host-normalized worker identities collided"
export TILLANDSIAS_CODEX_STATE_WORKER="worker/one"
worker_slash_key="$(codex_safe_state_worker_key)"
[[ "$worker_slash_key" != "$worker_hyphen_key" ]] \
    || fail "slash-normalized worker identities collided"
export TILLANDSIAS_CODEX_STATE_WORKER=$'worker\none'
worker_newline_key="$(codex_safe_state_worker_key)"
[[ "$worker_newline_key" =~ ^worker-[0-9a-f]{64}$ ]] \
    || fail "newline reached worker path component"
long_prefix="0123456789abcdef0123456789abcdef"
export TILLANDSIAS_CODEX_STATE_WORKER="${long_prefix}a"
worker_long_a_key="$(codex_safe_state_worker_key)"
export TILLANDSIAS_CODEX_STATE_WORKER="${long_prefix}b"
worker_long_b_key="$(codex_safe_state_worker_key)"
[[ "$worker_long_a_key" != "$worker_long_b_key" ]] \
    || fail "worker identities differing after host length cap collided"
export TILLANDSIAS_CODEX_STATE_WORKER="forge-tillandsias-codex-20260723T043901Z"
ledger_agent_early_key="$(codex_safe_state_worker_key)"
export TILLANDSIAS_CODEX_STATE_WORKER="forge-tillandsias-codex-20260723T062500Z"
ledger_agent_late_key="$(codex_safe_state_worker_key)"
[[ "$ledger_agent_early_key" != "$ledger_agent_late_key" ]] \
    || fail "documented same-day ledger agent identities collided"
for raw in "." ".." "../.." "../../escape" "worker/../../two" "A.B"; do
    export TILLANDSIAS_CODEX_STATE_WORKER="$raw"
    key="$(codex_safe_state_worker_key)"
    state_root="$(codex_safe_state_root)"
    [[ "$key" != "." && "$key" != ".." && "$key" != *"/"* ]] \
        || fail "unsafe worker key for $raw: $key"
    case "$state_root" in
        "$PROJECT_CACHE"/codex-state/*) ;;
        *) fail "state root escaped project cache for $raw: $state_root" ;;
    esac
done
unset TILLANDSIAS_CODEX_STATE_WORKER

export CODEX_HOME="$HOME/.codex"
[[ "$(codex_safe_state_worker_key)" == default ]]
[[ "$(codex_safe_state_root)" == "$PROJECT_CACHE/codex-state/default" ]]
export CODEX_HOME="$HOME/.codex-.."
[[ "$(codex_safe_state_worker_key)" == worker-* ]]
[[ "$(codex_safe_state_worker_key)" != default ]]

# Unsafe CODEX_HOME and redirected state-base paths fail before any copy/remove.
touch "$HOME/home-sentinel"
export CODEX_HOME="$HOME"
if codex_safe_state_setup; then
    fail "CODEX_HOME equal to HOME was accepted"
fi
[[ -f "$HOME/home-sentinel" ]]
export CODEX_HOME="$HOME/.codex-worker-one"
ln -s "$HOME" "$PROJECT_CACHE/codex-state"
if codex_safe_state_setup; then
    fail "symlinked codex-state base escaped the project cache"
fi
rm "$PROJECT_CACHE/codex-state"

# A CODEX_HOME symlink cannot redirect setup into another worker's otherwise
# valid-looking home directory.
mkdir -p "$HOME/.codex-victim/cache"
printf 'victim-sentinel\n' >"$HOME/.codex-victim/cache/sentinel"
ln -s "$HOME/.codex-victim" "$HOME/.codex-worker-link"
export CODEX_HOME="$HOME/.codex-worker-link"
if codex_safe_state_setup; then
    fail "symlinked CODEX_HOME was accepted"
fi
grep -Fxq victim-sentinel "$HOME/.codex-victim/cache/sentinel"
[[ ! -L "$HOME/.codex-victim/cache" ]]
rm "$HOME/.codex-worker-link"

export CODEX_HOME="$HOME/.codex-worker-one"

# Permission enforcement is part of the persistence boundary. A setup whose
# chmod cannot establish mode 0700 fails with no ready/root/SQLite exports.
(
    export CODEX_HOME="$HOME/.codex-permission-fixture"
    chmod() { return 1; }
    if codex_safe_state_setup; then
        fail "setup ignored persistent permission failure"
    fi
    [[ -z "${TILLANDSIAS_CODEX_SAFE_STATE_READY:-}" ]]
    [[ -z "${TILLANDSIAS_CODEX_SAFE_STATE_ROOT:-}" ]]
    [[ -z "${CODEX_SQLITE_HOME:-}" ]]
    [[ ! -L "$CODEX_HOME/cache" ]]
)

# A late-class preflight defect must not leave an earlier cache link behind.
ATTACK_ROOT="$(codex_safe_state_root)"
mkdir -p "$CODEX_HOME/cache" "$ATTACK_ROOT/direct"
ln -s "$HOME" "$ATTACK_ROOT/direct/sessions"
if codex_safe_state_setup; then
    fail "setup accepted a symlinked sessions persistence root"
fi
[[ ! -L "$CODEX_HOME/cache" ]]
[[ -z "${TILLANDSIAS_CODEX_SAFE_STATE_READY:-}" ]]
[[ -z "${TILLANDSIAS_CODEX_SAFE_STATE_ROOT:-}" ]]
[[ -z "${CODEX_SQLITE_HOME:-}" ]]
rm "$ATTACK_ROOT/direct/sessions"

codex_safe_state_setup
STATE_ROOT="$TILLANDSIAS_CODEX_SAFE_STATE_ROOT"
[[ "$STATE_ROOT" == "$(codex_safe_state_root)" ]]
[[ "$TILLANDSIAS_CODEX_SAFE_STATE_ROOT" == "$STATE_ROOT" ]]
[[ "$TILLANDSIAS_CODEX_SAFE_STATE_READY" == 1 ]]
[[ "$CODEX_SQLITE_HOME" == "$STATE_ROOT/sqlite" ]]
[[ "$(readlink "$CODEX_HOME/cache")" == "$STATE_ROOT/direct/cache" ]]
[[ "$(readlink "$CODEX_HOME/sessions")" == "$STATE_ROOT/direct/sessions" ]]

provider_auth_marker="provider-auth-document-do-not-persist-428"
pasted_secret_marker="pasted-project-secret-may-persist-428"
printf 'cache-state:%s\n' "$pasted_secret_marker" >"$CODEX_HOME/cache/model-index"
printf 'session-state:%s\n' "$pasted_secret_marker" >"$CODEX_HOME/sessions/session.jsonl"
printf 'sqlite-state:%s\n' "$pasted_secret_marker" >"$CODEX_SQLITE_HOME/state_5.sqlite"
printf '{"models":["gpt-fixture"]}\n' >"$CODEX_HOME/models_cache.json"
printf '{"latest":"fixture"}\n' >"$CODEX_HOME/version.json"
printf 'install-fixture\n' >"$CODEX_HOME/installation_id"
printf 'migrated\n' >"$CODEX_HOME/.sandbox_migration"
printf '{"access_token":"%s"}\n' "$provider_auth_marker" >"$CODEX_HOME/auth.json"
printf 'token = "%s"\n' "$provider_auth_marker" >"$CODEX_HOME/config.toml"
printf '%s\n' "$provider_auth_marker" >"$CODEX_HOME/history.jsonl"
mkdir -p "$CODEX_HOME/shell_snapshots"
printf '%s\n' "$provider_auth_marker" >"$CODEX_HOME/shell_snapshots/snapshot.sh"
printf '%s\n' "$provider_auth_marker" >"$CODEX_HOME/future-unknown-state"

# Direct state is hard-kill durable immediately; copied metadata is not claimed
# durable until the normal wrapper checkpoint.
[[ -f "$STATE_ROOT/direct/cache/model-index" ]]
[[ -f "$STATE_ROOT/direct/sessions/session.jsonl" ]]
[[ -f "$STATE_ROOT/sqlite/state_5.sqlite" ]]
[[ ! -e "$STATE_ROOT/files/models_cache.json" ]]

codex_safe_state_flush
for name in models_cache.json version.json installation_id .sandbox_migration; do
    [[ -f "$STATE_ROOT/files/$name" ]] || fail "missing whitelisted file $name"
done
[[ ! -e "$STATE_ROOT/auth.json" ]]
[[ ! -e "$STATE_ROOT/files/auth.json" ]]
if grep -R -Fq "$provider_auth_marker" "$STATE_ROOT"; then
    fail "provider authentication document reached persistent state"
fi
grep -Fq "$pasted_secret_marker" "$STATE_ROOT/direct/cache/model-index"
grep -Fq "$pasted_secret_marker" "$STATE_ROOT/direct/sessions/session.jsonl"
grep -Fq "$pasted_secret_marker" "$STATE_ROOT/sqlite/state_5.sqlite"

# Checkpoint and restore reject persisted destination links/directories. Temp
# names use mktemp and non-following mv -T. Regular hard-kill artifacts are
# cleaned; link/directory temp attacks fail closed.
printf 'external-sentinel\n' >"$WORK/external-target"
rm "$STATE_ROOT/files/version.json"
ln -s "$WORK/external-target" "$STATE_ROOT/files/version.json"
if codex_safe_state_flush; then
    fail "checkpoint accepted a symlink destination"
fi
grep -Fxq external-sentinel "$WORK/external-target"
rm "$STATE_ROOT/files/version.json"
mkdir "$STATE_ROOT/files/version.json"
if codex_safe_state_flush; then
    fail "checkpoint accepted a directory destination"
fi
rmdir "$STATE_ROOT/files/version.json"
touch "$STATE_ROOT/files/.version.json.checkpoint.$$"
codex_safe_state_flush
grep -Fxq external-sentinel "$WORK/external-target"
[[ -f "$STATE_ROOT/files/version.json" && ! -L "$STATE_ROOT/files/version.json" ]]
[[ ! -e "$STATE_ROOT/files/.version.json.checkpoint.$$" ]]
ln -s "$WORK/external-target" "$STATE_ROOT/files/.version.json.checkpoint.attack"
if codex_safe_state_flush; then
    fail "checkpoint accepted a symlink temp artifact"
fi
grep -Fxq external-sentinel "$WORK/external-target"
rm "$STATE_ROOT/files/.version.json.checkpoint.attack"
touch "$STATE_ROOT/files/.models_cache.json.checkpoint.hard-kill"

# A fresh ephemeral CODEX_HOME restores only the reviewed whitelist.
rm -rf "$CODEX_HOME"
mkdir -p "$CODEX_HOME"
ln -s "$WORK/external-target" "$CODEX_HOME/version.json"
if codex_safe_state_setup; then
    fail "restore accepted a symlink destination"
fi
[[ -z "${TILLANDSIAS_CODEX_SAFE_STATE_READY:-}" ]]
[[ -z "${TILLANDSIAS_CODEX_SAFE_STATE_ROOT:-}" ]]
[[ -z "${CODEX_SQLITE_HOME:-}" ]]
grep -Fxq external-sentinel "$WORK/external-target"
rm "$CODEX_HOME/version.json"
mkdir "$CODEX_HOME/version.json"
if codex_safe_state_setup; then
    fail "restore accepted a directory destination"
fi
[[ -z "${TILLANDSIAS_CODEX_SAFE_STATE_READY:-}" ]]
[[ -z "${TILLANDSIAS_CODEX_SAFE_STATE_ROOT:-}" ]]
[[ -z "${CODEX_SQLITE_HOME:-}" ]]
rmdir "$CODEX_HOME/version.json"
ln -s "$WORK/external-target" "$CODEX_HOME/.version.json.restore.$$"
if codex_safe_state_setup; then
    fail "restore accepted a symlink temp artifact"
fi
grep -Fxq external-sentinel "$WORK/external-target"
rm "$CODEX_HOME/.version.json.restore.$$"
touch "$CODEX_HOME/.version.json.restore.$$"
codex_safe_state_setup
grep -Fxq external-sentinel "$WORK/external-target"
[[ ! -e "$CODEX_HOME/.version.json.restore.$$" ]]
[[ ! -e "$STATE_ROOT/files/.models_cache.json.checkpoint.hard-kill" ]]
grep -Fq gpt-fixture "$CODEX_HOME/models_cache.json"
grep -Fq cache-state "$CODEX_HOME/cache/model-index"
grep -Fq session-state "$CODEX_HOME/sessions/session.jsonl"
for excluded in auth.json config.toml history.jsonl shell_snapshots future-unknown-state; do
    [[ ! -e "$CODEX_HOME/$excluded" ]] || fail "excluded state restored: $excluded"
done

# A second worker gets a distinct root and none of worker one's state.
export CODEX_HOME="$HOME/.codex-worker-two"
codex_safe_state_setup
STATE_ROOT_TWO="$TILLANDSIAS_CODEX_SAFE_STATE_ROOT"
[[ "$STATE_ROOT_TWO" == "$(codex_safe_state_root)" ]]
[[ "$TILLANDSIAS_CODEX_SAFE_STATE_ROOT" == "$STATE_ROOT_TWO" ]]
[[ "$STATE_ROOT_TWO" != "$STATE_ROOT" ]]
[[ ! -e "$CODEX_HOME/models_cache.json" ]]
[[ ! -e "$CODEX_HOME/cache/model-index" ]]

# Normal wrapper exit checkpoints copied metadata without backgrounding the
# foreground command or changing its exit status.
cat >"$WORK/vault-helper" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    digest) echo missing ;;
    watch)
        while kill -0 "$2" 2>/dev/null; do sleep 0.02; done
        ;;
    harvest) exit 0 ;;
    *) exit 64 ;;
esac
EOF
cat >"$WORK/codex-child" <<'EOF'
#!/usr/bin/env bash
printf '{"models":["wrapper-checkpoint"]}\n' >"$CODEX_HOME/models_cache.json"
exit 7
EOF
chmod 755 "$WORK/vault-helper" "$WORK/codex-child"
export TILLANDSIAS_CODEX_STATE_HELPER="$HELPER"
export TILLANDSIAS_CODEX_VAULT_HELPER="$WORK/vault-helper"
set +e
"$SESSION" -- "$WORK/codex-child"
session_rc=$?
set -e
[[ "$session_rc" -eq 7 ]] || fail "wrapper changed foreground exit status: $session_rc"
grep -Fq wrapper-checkpoint "$STATE_ROOT_TWO/files/models_cache.json"

echo "PASS: Codex state is explicit, provider-auth-excluding, worker-namespaced, and normally checkpointed"
