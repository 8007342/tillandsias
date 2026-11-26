-- @env PATH
-- @trace spec:tillandsias-vault, order:2301-4bgh
--
-- test-codex-device-auth.lua — images/default/codex-device-auth.sh, run against stub codex
-- and vault-cli.sh binaries. Ported from the .sh of the same name (2301-4bgh). No real
-- credential, vault or network: HOME, CODEX_HOME and PATH point into scratch.
--
--   1 HELPERS  both vault-cli.sh copies write on stdin and pass CA and header by file
--   2 STORE    the stored value decodes to the auth file, byte for byte
--   3 ARGV     the value reached the vault helper and is never in its argv
--   4 FAILLOUD a codex without --device-auth exits 2, refuses the fallback, stores nothing
--   5 NAMED    a codex given by TILLANDSIAS_CODEX_BIN installs nothing
--   6 REQUIRE  with none given, only require_codex runs, and the login completes
--   7 SOURCE   the login one-shot never calls the full harness updater
--
-- Usage: tillandsias-plan script run scripts/lua/test-codex-device-auth.lua
-- Verdict: ok:codex-device-auth:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("codex-device-auth")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local SCRIPT = "images/default/codex-device-auth.sh"
local DOC = '{"access_token":"fixture","refresh_token":"refresh"}\n'

local bare = {}
for _, h in ipairs{ "images/git/vault-cli.sh", "images/default/vault-cli.sh" } do
    local src = fs.read(h)
    for _, want in ipairs{ "write-stdin", '--cacert "$VAULT_CACERT"', '--header "@$header_file"' } do
        if not text.contains(src, want) then bare[#bare + 1] = h .. ": " .. want end
    end
end
T:arm("1 HELPERS write on stdin and pass CA and header by file", #bare == 0, table.concat(bare, "; "))

local STUBS = {
    ["lib-common.sh"] = [==[
require_codex() { printf 'require_codex\n' >>"$REQUIRE_LOG"; CX_BIN="$W/bin/codex-ok"; }
ensure_forge_harnesses() { echo "full harness updater must not run in the Codex login one-shot" >&2; exit 97; }
]==],
    ["bin/codex-ok"] = [==[
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == login && "${2:-}" == --help ]]; then
    echo 'Usage: codex login [--device-auth]'
elif [[ "${1:-}" == login && "${2:-}" == --device-auth ]]; then
    mkdir -p "$HOME/.codex"
    printf '{"access_token":"fixture","refresh_token":"refresh"}\n' >"$HOME/.codex/auth.json"
else
    exit 64
fi
]==],
    ["bin/codex-no-device"] = [==[
#!/usr/bin/env bash
if [[ "${1:-}" == login && "${2:-}" == --help ]]; then
    echo 'Usage: codex login'
else
    echo 'device login must not run after a failed feature probe' >&2
    exit 99
fi
]==],
    ["bin/vault-cli.sh"] = [==[
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$VAULT_ARGV_LOG"
printf '\n' >>"$VAULT_ARGV_LOG"
case "${1:-}" in
    write-stdin)
        [[ "$2" == secret/codex/oauth ]]
        [[ "$3" == credentials_b64 ]]
        cat >"$VAULT_CAPTURE"
        ;;
    read) cat "$VAULT_CAPTURE" ;;
    *) exit 64 ;;
esac
]==],
}
-- One scratch world per run. `bin`: the stub named by TILLANDSIAS_CODEX_BIN, or nil.
local function login(bin)
    local d = T:scratch()
    fs.mkdir(d.rel .. "/bin"); fs.mkdir(d.rel .. "/home/.codex")
    for f, body in pairs(STUBS) do fs.write(d.rel .. "/" .. f, body) end
    local r = proc.run{ argv = { SH, "-s", "--", bin or "" }, cwd = d.abs, timeout_ms = 60000, stdin = [==[
set -eu
W="$PWD"; chmod 755 bin/*
export W HOME="$W/home" PATH="$W/bin:$PATH" TILLANDSIAS_LIB_COMMON="$W/lib-common.sh"
export VAULT_CAPTURE="$W/vault-value" VAULT_ARGV_LOG="$W/vault-argv.log" REQUIRE_LOG="$W/require.log"
unset CODEX_HOME TILLANDSIAS_CODEX_AUTH_FILE TILLANDSIAS_CODEX_BIN || true
[ -z "$1" ] || export TILLANDSIAS_CODEX_BIN="$W/bin/$1"
rc=0; bash "]==] .. ROOT .. "/" .. SCRIPT .. [==[" </dev/null >out 2>&1 || rc=$?
[ ! -e vault-value ] || base64 -d <vault-value >restored.json
exit "$rc"
]==] }
    local function read(f) return fs.exists(d.rel .. "/" .. f) and fs.read(d.rel .. "/" .. f) or nil end
    return r.code, read, "rc=" .. tostring(r.code) .. " out=" .. tostring(read("out")) .. (r.stderr or "")
end

local rc, read, why = login("codex-ok")
T:arm("2 STORE the stored value decodes to the auth file", rc == 0 and read("restored.json") == DOC and read("home/.codex/auth.json") == DOC, why)
local argv, b64 = read("vault-argv.log") or "", text.trim(read("vault-value") or "")
T:arm("3 ARGV the value is on stdin, never in the helper's argv",
    text.contains(argv, "write-stdin secret/codex/oauth credentials_b64") and b64 ~= "" and not text.contains(argv, b64), argv)
local no_require = read("require.log") == nil

rc, read, why = login("codex-no-device")
local o = read("out") or ""
T:arm("4 FAILLOUD no --device-auth exits 2, refuses the fallback and stores nothing",
    rc == 2 and text.contains(o, "does not support 'codex login --device-auth'")
    and text.contains(o, "refusing browser or paste-token fallback") and read("vault-value") == nil, why)
T:arm("5 NAMED a codex given by name installs nothing", no_require and read("require.log") == nil, "require.log written")

rc, read, why = login(nil)
T:arm("6 REQUIRE only require_codex runs and the login completes",
    rc == 0 and read("require.log") == "require_codex\n" and read("home/.codex/auth.json") == DOC, why)
T:arm("7 SOURCE the one-shot never calls the full harness updater", not text.contains(fs.read(SCRIPT), "ensure_forge_harnesses"), SCRIPT)
T:finish()
