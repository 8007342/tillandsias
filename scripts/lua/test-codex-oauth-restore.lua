-- @env PATH
-- @trace order:2080-zcur
--
-- test-codex-oauth-restore.lua — images/default/codex-oauth-vault.sh restore
-- writes the Codex OAuth credentials from the Vault into ~/.codex/auth.json
-- byte-identically, mode 0600, and the tokens appear nowhere else (not in the
-- vault-cli or codex argv/env, not in the project dir).
-- Stubs on PATH: vault-cli.sh (asserts the read path and field, returns the
-- base64 value) and codex (asserts auth.json, logs argv and env).
-- Ported from scripts/test-codex-oauth-restore.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-codex-oauth-restore.lua
-- Verdict: ok:codex-oauth-restore:<n> arms | violation:codex-oauth-restore:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("codex-oauth-restore")
local ROOT = fixture.repo_root()
local W = T:scratch()
for _, d in ipairs{ "bin", "home", "project" } do fs.mkdir(W.rel .. "/" .. d) end

local EXPECTED = '{"access_token":"fixture-access","refresh_token":"fixture-refresh"}\n'
fs.write(W.rel .. "/expected.json", EXPECTED)
-- base64 without -w0 (a GNU flag): BSD/macOS base64 has no -w; join the lines here.
local b64 = T:must{ "base64", W.abs .. "/expected.json" }
fs.write(W.rel .. "/vault-value", (b64.stdout:gsub("%s", "")))

fs.write(W.rel .. "/bin/vault-cli.sh", table.concat({
    "#!/usr/bin/env bash",
    "set -euo pipefail",
    "printf '%q ' \"$@\" >>\"$CALL_LOG\"",
    "printf '\\n' >>\"$CALL_LOG\"",
    '[[ "$1" == read ]]',
    '[[ "$2" == -field=credentials_b64 ]]',
    '[[ "$3" == secret/codex/oauth ]]',
    'cat "$VAULT_VALUE"',
}, "\n") .. "\n")
fs.write(W.rel .. "/bin/codex", table.concat({
    "#!/usr/bin/env bash",
    "set -euo pipefail",
    'cmp "$HOME/.codex/auth.json" "$FIXTURE_EXPECTED_JSON"',
    "printf 'argv:' >>\"$CALL_LOG\"",
    "printf ' %q' \"$@\" >>\"$CALL_LOG\"",
    "printf '\\n' >>\"$CALL_LOG\"",
    'env | sort >>"$CALL_LOG"',
}, "\n") .. "\n")
T:must{ "chmod", "+x", W.abs .. "/bin/vault-cli.sh", W.abs .. "/bin/codex" }

local E = {
    HOME = W.abs .. "/home",
    PATH = W.abs .. "/bin:" .. (env.get("PATH") or "/usr/bin:/bin"),
    VAULT_VALUE = W.abs .. "/vault-value",
    FIXTURE_EXPECTED_JSON = W.abs .. "/expected.json",
    CALL_LOG = W.abs .. "/calls.log",
}
local AUTH = W.rel .. "/home/.codex/auth.json"

local r = T:run{ "bash", ROOT .. "/images/default/codex-oauth-vault.sh", "restore", cwd = W.abs .. "/project", env = E }
T:arm("1 restore exits 0", r.code == 0, "rc=" .. tostring(r.code) .. " " .. tostring(r.stderr))
T:arm("2 auth.json is byte-identical to the vault value", fs.exists(AUTH) and fs.read(AUTH) == EXPECTED,
    fs.exists(AUTH) and fs.read(AUTH) or "absent")
-- GNU stat -c %a, else BSD stat -f %Lp (as the .sh did)
local st = T:run{ "stat", "-c", "%a", ROOT .. "/" .. AUTH }
if st.code ~= 0 then st = T:run{ "stat", "-f", "%Lp", ROOT .. "/" .. AUTH } end
T:arm("3 auth.json is mode 0600", text.trim(st.stdout or "") == "600", st.stdout)
r = T:run{ W.abs .. "/bin/codex", "--fixture", env = E }
T:arm("4 codex finds the restored auth.json", r.code == 0, "rc=" .. tostring(r.code) .. " " .. tostring(r.stderr))

local leaks = T:run{ "grep", "-R", "-l", "-e", "fixture-access", "-e", "fixture-refresh",
    W.abs .. "/calls.log", W.abs .. "/project" }
T:arm("5 no credential outside the private auth file", leaks.code == 1,
    "leaked into: " .. tostring(leaks.stdout) .. tostring(leaks.stderr))

T:finish()
