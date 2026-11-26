-- @env PATH HOME
-- @trace order:2377-znx4
--
-- test-codex-safe-state.lua — codex-safe-state.sh persists a named list of codex state per worker,
-- never an authentication document, and refuses any symlink in its way. Ported from the .sh of the
-- same name (2377-znx4). The helper's functions are sourced in one shell, as the entrypoint sources them;
-- the home, the project cache and the vault helper are scratch.
--
--   1 worker identities never collide, nor escape the cache     2 the default worker
--   3 HOME as CODEX_HOME, a linked base, a linked home, a failing chmod, a linked root: refused
--   4 setup     5 what is persisted, and that the auth document is not
--   6 a checkpoint refuses symlinks and directories             7 so does a restore
--   8 the restore brings back the list and nothing else         9 another worker sees none of it
--   10 the session wrapper keeps the exit status and checkpoints
--
-- Usage: tillandsias-plan script run scripts/lua/test-codex-safe-state.lua
-- Verdict: ok:codex-safe-state:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("codex-safe-state")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local w = T:scratch()
fs.write(w.rel .. "/vault-helper", [==[#!/usr/bin/env bash
case "${1:-}" in
    digest) echo missing ;;
    watch) while kill -0 "$2" 2>/dev/null; do sleep 0.02; done ;;
    harvest) exit 0 ;;
    *) exit 64 ;;
esac
]==])
fs.write(w.rel .. "/codex-child", "#!/usr/bin/env bash\nprintf '{\"models\":[\"wrapper-checkpoint\"]}\\n' >\"$CODEX_HOME/models_cache.json\"\nexit 7\n")
T:must{ "chmod", "755", w.abs .. "/vault-helper", w.abs .. "/codex-child" }
local SCRIPT = [==[
set -u
WORK="$1"; HELPER="$2/images/default/codex-safe-state.sh"; SESSION="$2/images/default/codex-oauth-session.sh"
export HOME="$WORK/home" PROJECT_CACHE="$WORK/project-cache"; mkdir -p "$HOME" "$PROJECT_CACHE"
. "$HELPER"; set +e +u +o pipefail
yes() { n="$1"; shift; if "$@"; then echo "arm $n"; else echo "NOT $n"; fi; }
no() { n="$1"; shift; if "$@"; then echo "NOT $n"; else echo "arm $n"; fi; }
key() { codex_safe_state_worker_key; }
as() { TILLANDSIAS_CODEX_STATE_WORKER="$1"; export TILLANDSIAS_CODEX_STATE_WORKER; key; }
hexkey() { [[ "$1" =~ ^worker-[0-9a-f]{64}$ ]]; }
same() { [ "$1" = "$2" ]; }
unready() { [ -z "${TILLANDSIAS_CODEX_SAFE_STATE_READY:-}${TILLANDSIAS_CODEX_SAFE_STATE_ROOT:-}${CODEX_SQLITE_HOME:-}" ]; }
sentinel() { [ "$(cat "$WORK/external-target")" = external-sentinel ]; }
unset TILLANDSIAS_CODEX_STATE_WORKER
export CODEX_HOME="$HOME/.codex-Worker.One"; a="$(key)"; export CODEX_HOME="$HOME/.codex-worker-one"; b="$(key)"
yes 1-home-key-shape hexkey "$a"; yes 1-home-key-shape-2 hexkey "$b"; no 1-raw-homes-collide same "$a" "$b"
h="$(as "a-b")"; no 1-space-collides same "$(as "a b")" "$h"; no 1-slash-collides same "$(as "worker/one")" "$h"
yes 1-newline-key hexkey "$(as $'worker\none')"
L=0123456789abcdef0123456789abcdef; no 1-long-collide same "$(as "${L}a")" "$(as "${L}b")"
no 1-same-day-collide same "$(as forge-tillandsias-codex-20260723T043901Z)" "$(as forge-tillandsias-codex-20260723T062500Z)"
bad=""
for raw in . .. ../.. ../../escape worker/../../two A.B; do
    k="$(as "$raw")"; export TILLANDSIAS_CODEX_STATE_WORKER="$raw"; r="$(codex_safe_state_root)"
    case "$k" in .|..|*/*) bad="$bad key:$raw" ;; esac
    case "$r" in "$PROJECT_CACHE"/codex-state/*) ;; *) bad="$bad root:$raw" ;; esac
done
yes 1-no-escape same "$bad" ""
unset TILLANDSIAS_CODEX_STATE_WORKER; export CODEX_HOME="$HOME/.codex"
yes 2-default-key same "$(key)" default; yes 2-default-root same "$(codex_safe_state_root)" "$PROJECT_CACHE/codex-state/default"
export CODEX_HOME="$HOME/.codex-.."; yes 2-dots-are-a-worker hexkey "$(key)"
touch "$HOME/home-sentinel"; export CODEX_HOME="$HOME"; no 3-home-accepted codex_safe_state_setup; yes 3-home-kept test -f "$HOME/home-sentinel"
export CODEX_HOME="$HOME/.codex-worker-one"; ln -s "$HOME" "$PROJECT_CACHE/codex-state"; no 3-linked-base-accepted codex_safe_state_setup; rm "$PROJECT_CACHE/codex-state"
mkdir -p "$HOME/.codex-victim/cache"; echo victim-sentinel >"$HOME/.codex-victim/cache/sentinel"; ln -s "$HOME/.codex-victim" "$HOME/.codex-worker-link"
export CODEX_HOME="$HOME/.codex-worker-link"; no 3-linked-home-accepted codex_safe_state_setup
yes 3-victim-kept same "$(cat "$HOME/.codex-victim/cache/sentinel")" victim-sentinel; no 3-victim-linked test -L "$HOME/.codex-victim/cache"; rm "$HOME/.codex-worker-link"
(
    export CODEX_HOME="$HOME/.codex-permission-fixture"; chmod() { return 1; }
    no 3-chmod-failure-accepted codex_safe_state_setup; yes 3-chmod-failure-unready unready; no 3-chmod-failure-linked test -L "$CODEX_HOME/cache"
)
export CODEX_HOME="$HOME/.codex-worker-one"; R="$(codex_safe_state_root)"; mkdir -p "$CODEX_HOME/cache" "$R/direct"; ln -s "$HOME" "$R/direct/sessions"
no 3-linked-root-accepted codex_safe_state_setup; no 3-linked-root-linked test -L "$CODEX_HOME/cache"; yes 3-linked-root-unready unready; rm "$R/direct/sessions"
yes 4-setup codex_safe_state_setup; R="${TILLANDSIAS_CODEX_SAFE_STATE_ROOT:-none}"
yes 4-root same "$R" "$(codex_safe_state_root)"; yes 4-ready same "${TILLANDSIAS_CODEX_SAFE_STATE_READY:-}" 1; yes 4-sqlite same "${CODEX_SQLITE_HOME:-}" "$R/sqlite"
yes 4-cache-link same "$(readlink "$CODEX_HOME/cache")" "$R/direct/cache"; yes 4-sessions-link same "$(readlink "$CODEX_HOME/sessions")" "$R/direct/sessions"
AUTH=provider-auth-document-do-not-persist-428; PASTED=pasted-project-secret-may-persist-428
echo "cache-state:$PASTED" >"$CODEX_HOME/cache/model-index"; echo "session-state:$PASTED" >"$CODEX_HOME/sessions/session.jsonl"; echo "sqlite-state:$PASTED" >"$CODEX_SQLITE_HOME/state_5.sqlite"
echo '{"models":["gpt-fixture"]}' >"$CODEX_HOME/models_cache.json"; echo '{"latest":"fixture"}' >"$CODEX_HOME/version.json"; echo install-fixture >"$CODEX_HOME/installation_id"; echo migrated >"$CODEX_HOME/.sandbox_migration"
for f in auth.json config.toml history.jsonl future-unknown-state; do echo "$AUTH" >"$CODEX_HOME/$f"; done; mkdir -p "$CODEX_HOME/shell_snapshots"; echo "$AUTH" >"$CODEX_HOME/shell_snapshots/snapshot.sh"
yes 5-direct-state test -f "$R/direct/cache/model-index" -a -f "$R/direct/sessions/session.jsonl" -a -f "$R/sqlite/state_5.sqlite"; no 5-file-early test -e "$R/files/models_cache.json"
yes 5-flush codex_safe_state_flush
for f in models_cache.json version.json installation_id .sandbox_migration; do yes "5-persisted-$f" test -f "$R/files/$f"; done
no 5-auth-file test -e "$R/auth.json" -o -e "$R/files/auth.json"; no 5-auth-anywhere grep -R -Fq "$AUTH" "$R"
for f in direct/cache/model-index direct/sessions/session.jsonl sqlite/state_5.sqlite; do yes "5-kept-$f" grep -Fq "$PASTED" "$R/$f"; done
echo external-sentinel >"$WORK/external-target"; V="$R/files/version.json"
rm "$V"; ln -s "$WORK/external-target" "$V"; no 6-link-destination codex_safe_state_flush; yes 6-link-target-kept sentinel
rm "$V"; mkdir "$V"; no 6-dir-destination codex_safe_state_flush; rmdir "$V"
touch "$R/files/.version.json.checkpoint.$$"; yes 6-stale-temp-recovers codex_safe_state_flush; yes 6-regular-file test -f "$V" -a ! -L "$V"; no 6-temp-left test -e "$R/files/.version.json.checkpoint.$$"; yes 6-target-kept sentinel
ln -s "$WORK/external-target" "$R/files/.version.json.checkpoint.attack"; no 6-link-temp codex_safe_state_flush; yes 6-temp-target-kept sentinel; rm "$R/files/.version.json.checkpoint.attack"
touch "$R/files/.models_cache.json.checkpoint.hard-kill"
rm -rf "$CODEX_HOME"; mkdir -p "$CODEX_HOME"; ln -s "$WORK/external-target" "$CODEX_HOME/version.json"; no 7-link-destination codex_safe_state_setup; yes 7-link-unready unready; yes 7-link-target-kept sentinel; rm "$CODEX_HOME/version.json"
mkdir "$CODEX_HOME/version.json"; no 7-dir-destination codex_safe_state_setup; yes 7-dir-unready unready; rmdir "$CODEX_HOME/version.json"
ln -s "$WORK/external-target" "$CODEX_HOME/.version.json.restore.$$"; no 7-link-temp codex_safe_state_setup; yes 7-temp-target-kept sentinel; rm "$CODEX_HOME/.version.json.restore.$$"; touch "$CODEX_HOME/.version.json.restore.$$"
yes 8-restore codex_safe_state_setup; yes 8-target-kept sentinel; no 8-restore-temp-left test -e "$CODEX_HOME/.version.json.restore.$$"; no 8-checkpoint-temp-left test -e "$R/files/.models_cache.json.checkpoint.hard-kill"
yes 8-models grep -Fq gpt-fixture "$CODEX_HOME/models_cache.json"; yes 8-cache grep -Fq cache-state "$CODEX_HOME/cache/model-index"; yes 8-sessions grep -Fq session-state "$CODEX_HOME/sessions/session.jsonl"
for f in auth.json config.toml history.jsonl shell_snapshots future-unknown-state; do no "8-restored-$f" test -e "$CODEX_HOME/$f"; done
export CODEX_HOME="$HOME/.codex-worker-two"; yes 9-setup codex_safe_state_setup; R2="${TILLANDSIAS_CODEX_SAFE_STATE_ROOT:-none}"
yes 9-root same "$R2" "$(codex_safe_state_root)"; no 9-shared-root same "$R2" "$R"; no 9-sees-models test -e "$CODEX_HOME/models_cache.json"; no 9-sees-cache test -e "$CODEX_HOME/cache/model-index"
export TILLANDSIAS_CODEX_STATE_HELPER="$HELPER" TILLANDSIAS_CODEX_VAULT_HELPER="$WORK/vault-helper"
rc=0; "$SESSION" -- "$WORK/codex-child" >/dev/null 2>&1 </dev/null || rc=$?
yes 10-exit-status same "$rc" 7; yes 10-checkpoint grep -Fq wrapper-checkpoint "$R2/files/models_cache.json"
echo end
]==]
-- `arm <name>` is a pass and `NOT <name>` a failure, for a name that says what must not happen too.
local r = proc.run{ argv = { SH, "-s", "--", w.abs, ROOT }, cwd = w.abs, stdin = SCRIPT, env = { PATH = env.get("PATH"), HOME = w.abs }, env_unset = { "TILLANDSIAS_*", "CODEX_*" }, timeout_ms = 120000 }
local o, n = "\n" .. (r.stdout or ""):gsub("\r", ""), 0
for verdict_, name in o:gmatch("\n(%u*%l*) (%d+%-[^\n]+)") do
    n = n + 1
    T:arm(name, verdict_ == "arm", (r.stderr or ""):sub(-400))
end
T:arm("every arm ran", o:match("\nend\n$") ~= nil and n == 77, n .. " arms, rc=" .. tostring(r.code) .. " " .. o:sub(-200) .. (r.stderr or ""):sub(-600))
T:finish()
