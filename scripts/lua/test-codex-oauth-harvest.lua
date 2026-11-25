-- @env PATH
-- @trace spec:tillandsias-vault, order:1914-twan, order:2320-b5vv
--
-- test-codex-oauth-harvest.lua — images/default/codex-oauth-session.sh copies a created, a
-- rotated and a signal-exit Codex credential to Vault. Ported from the .sh of the same name
-- (2320-b5vv). Stub codex and vault-cli.sh; HOME, PATH and every state path are in scratch.
--
--   1 ROTATE  a created and then a rotated document both reach Vault, the last one kept
--   2 NOSTATE the shared wrapper flushes no Codex state root it did not set up
--   3 SIGNAL  a foreground agent killed by TERM exits 143 through the wrapper
--   4 LAST    what it wrote on the way out is in Vault
--   5 LEAK    no token reaches a helper's argv, the session log or the project
--
-- Usage: tillandsias-plan script run scripts/lua/test-codex-oauth-harvest.lua
-- Verdict: ok:codex-oauth-harvest:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("codex-oauth-harvest")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
if not fixture.which("jq") then T:skip("no-jq") end
local d = T:scratch()
for _, p in ipairs{ "bin", "home/.codex", "project", "history" } do fs.mkdir(d.rel .. "/" .. p) end
local function put(f, body) fs.write(d.rel .. "/" .. f, body) end
put("bin/vault-cli.sh", [==[
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$CALL_LOG"
printf '\n' >>"$CALL_LOG"
case "$1" in
    read) cat "$VAULT_VALUE" ;;
    write-stdin)
        [[ "$2" == secret/codex/oauth ]]
        [[ "$3" == credentials_b64 ]]
        tmp="$VAULT_VALUE.$$"
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
]==])
put("bin/codex-normal", [==[
#!/usr/bin/env bash
set -euo pipefail
printf 'argv:' >>"$CALL_LOG"
printf ' %q' "$@" >>"$CALL_LOG"
printf '\n' >>"$CALL_LOG"
mkdir -p "${CODEX_HOME:-$HOME/.codex}"
printf '{"models":["shared-wrapper-no-setup"]}\n' >"${CODEX_HOME:-$HOME/.codex}/models_cache.json"
printf '{"access_token":"created-token"}\n' >"$TILLANDSIAS_CODEX_AUTH_FILE"
# The watcher must see each document: wait for its copy, bounded, then move on.
for _ in {1..100}; do grep -Fqs created-token "$HISTORY_DIR"/*.json && break; sleep 0.05; done
printf '{"access_token":"rotated-token"}\n' >"$TILLANDSIAS_CODEX_AUTH_FILE"
sleep 0.2
]==])
put("bin/codex-signal", [==[
#!/usr/bin/env bash
set -euo pipefail
finish() {
    printf '{"access_token":"signal-token"}\n' >"$TILLANDSIAS_CODEX_AUTH_FILE"
    exit 143
}
trap finish TERM INT
echo "$$" >"$W/child-pid"
for _ in {1..600}; do sleep 0.05; done
]==])
-- The agent runs in the FOREGROUND under the wrapper (it owns the tty), so a terminal signal
-- reaches it directly: the script signals the agent, never the wrapper.
local SCRIPT = [==[
set -uo pipefail
R=$1; export W="$PWD"
chmod 755 bin/*
unset CODEX_HOME
export HOME="$W/home" PATH="$W/bin:$PATH" TILLANDSIAS_CODEX_AUTH_FILE="$W/home/.codex/auth.json"
export TILLANDSIAS_CODEX_VAULT_HELPER="$R/images/default/codex-oauth-vault.sh" TILLANDSIAS_CODEX_STATE_HELPER="$R/images/default/codex-safe-state.sh"
export PROJECT_CACHE="$W/project-cache" TILLANDSIAS_OAUTH_POLL_SECS=0.05 TILLANDSIAS_LIFECYCLE_LOG="$W/lifecycle.log"
export TILLANDSIAS_CODEX_RELOGIN_HELPER="$W/no-relogin" VAULT_VALUE="$W/vault-value" HISTORY_DIR="$W/history" CALL_LOG="$W/calls.log"
SESSION="$R/images/default/codex-oauth-session.sh"
printf '{"access_token":"initial-token"}\n' >"$TILLANDSIAS_CODEX_AUTH_FILE"
# Claude and Antigravity use this wrapper too: a CODEX_HOME-shaped dir must not make it flush.
# The root is named but never made READY, so no flush may create it.
rc=0; CODEX_HOME="$HOME/.codex-shared" TILLANDSIAS_CODEX_SAFE_STATE_ROOT="$PROJECT_CACHE/codex-state" bash "$SESSION" -- "$W/bin/codex-normal" </dev/null >normal.log 2>&1 || rc=$?
echo "$rc" >normal.rc
base64 -d <"$VAULT_VALUE" >final-normal.json
if [ -e "$PROJECT_CACHE/codex-state" ]; then echo flushed >state; else echo none >state; fi
printf '{"access_token":"before-signal"}\n' >"$TILLANDSIAS_CODEX_AUTH_FILE"
bash "$SESSION" -- "$W/bin/codex-signal" </dev/null >session.log 2>&1 & s=$!
for _ in {1..100}; do [ -s child-pid ] && break; sleep 0.05; done
[ -s child-pid ] || { kill "$s"; exit 91; }
kill -TERM "$(cat child-pid)"
rc=0; wait "$s" || rc=$?
echo "$rc" >signal.rc
base64 -d <"$VAULT_VALUE" >final-signal.json
]==]
local r = T:run{ SH, "-s", "--", ROOT, cwd = d.abs, stdin = SCRIPT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
if r.code ~= 0 then T:refuse("setup-failed", "rc=" .. tostring(r.code) .. " " .. (r.stderr or "")) end
local function read(f) return fs.exists(d.rel .. "/" .. f) and fs.read(d.rel .. "/" .. f) or "" end
local history = ""
for _, f in ipairs(fs.walk(d.rel .. "/history", { suffix = ".json" })) do history = history .. fs.read(f) end
local why = "rc " .. read("normal.rc") .. read("signal.rc") .. "history " .. history .. read("normal.log") .. read("session.log")
T:arm("1 ROTATE a created and a rotated document both reach Vault and the last is kept", text.trim(read("normal.rc")) == "0"
    and text.contains(history, "created-token") and text.contains(history, "rotated-token") and text.contains(read("final-normal.json"), "rotated-token"), why)
T:arm("2 NOSTATE no Codex state root is flushed without its setup", text.trim(read("state")) == "none", read("state"))
T:arm("3 SIGNAL an agent killed by TERM exits 143 through the wrapper", text.trim(read("signal.rc")) == "143", why)
T:arm("4 LAST what it wrote on the way out is in Vault", text.contains(read("final-signal.json"), "signal-token"), why)
local seen = read("calls.log") .. read("normal.log") .. read("session.log") .. read("lifecycle.log")
for _, f in ipairs(fs.walk(d.rel .. "/project", {})) do seen = seen .. fs.read(f) end
local leaked = {}
for _, s in ipairs{ "initial-token", "created-token", "rotated-token", "before-signal", "signal-token" } do
    if text.contains(seen, s) then leaked[#leaked + 1] = s end
end
T:arm("5 LEAK no token in a helper's argv, the logs or the project", text.contains(read("calls.log"), "write-stdin secret/codex/oauth credentials_b64") and #leaked == 0, table.concat(leaked, " ") .. read("calls.log"))
T:finish()
