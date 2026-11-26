-- @env PATH HOME
-- @trace order:900-z3kv, order:2378-hcxg
--
-- test-clear-vault-host-credentials.lua — clear-vault-host-credentials.sh clears the vault's host
-- credentials in all three places, never the installation anchor, and nothing without consent.
-- Ported from the .sh of the same name (2378-hcxg). Scratch caches, a stub secret-tool, no session bus.
--
--   1 a warm room is cleared     2 PREMISE a warm room is detectable     3 the anchor is kept
--   4 a cold room succeeds       5 no consent refuses (2)                6 --dry-run changes nothing
--
-- Usage: tillandsias-plan script run scripts/lua/test-clear-vault-host-credentials.lua
-- Verdict: ok:clear-vault-host-credentials:<n> arms | violation:...

local fixture = require "common.fixture"
local bus = require "common.privatebus"
local T = fixture.new("clear-vault-host-credentials")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local PLACES = { "fallback_vault-shamir-share-v1", "fallback_vault-root-token-v1", "vault-data" }
local function room(warm)
    local d = T:scratch()
    fs.mkdir(d.rel .. "/bin"); fs.mkdir(d.rel .. "/cache/tillandsias"); fs.write(d.rel .. "/log", "")
    fs.write(d.rel .. "/bin/secret-tool", "#!/usr/bin/env bash\n[ \"${1:-}\" = clear ] || exit 1\nshift\nprintf '%s\\n' \"$*\" >>\"" .. d.abs .. "/log\"\n")
    T:must{ "chmod", "+x", d.abs .. "/bin/secret-tool" }
    if warm then
        fs.mkdir(d.rel .. "/cache/tillandsias/vault-data")
        fs.write(d.rel .. "/cache/tillandsias/" .. PLACES[1], ""); fs.write(d.rel .. "/cache/tillandsias/" .. PLACES[2], "")
    end
    return d
end
local function left(d)
    local l = {}
    for _, p in ipairs(PLACES) do
        if fs.exists(d.rel .. "/cache/tillandsias/" .. p) then l[#l + 1] = p end
    end
    return l
end
local function clear(d, consent, ...)
    -- The consent and the caches are set by the shell: the door gives a child none of them.
    local pre = 'export PATH="$1/bin:$PATH" XDG_CACHE_HOME="$1/cache"\n' .. (consent and "export TILLANDSIAS_DESTRUCTIVE_RESET_OK=" .. consent .. "\n" or "") .. 's="$2"; shift 2; exec bash "$s" "$@" </dev/null\n'
    local r = proc.run{ argv = { SH, "-s", "--", d.abs, ROOT .. "/scripts/clear-vault-host-credentials.sh", ... }, cwd = d.abs, stdin = pre, env = bus.env{ HOME = d.abs }, env_unset = { "TILLANDSIAS_*", "XDG_*" }, timeout_ms = 60000 }
    return { rc = r.code, log = fs.read(d.rel .. "/log"), left = left(d), why = "rc=" .. tostring(r.code) .. " left=" .. table.concat(left(d), ",") .. " " .. (r.stdout or ""):sub(1, 300) .. (r.stderr or ""):sub(1, 300) }
end
local x = clear(room(true))
T:arm("1a a warm room's files are gone", x.rc == 0 and #x.left == 0, x.why)
T:arm("1b and its keychain items", text.contains(x.log, "vault-shamir-share-v1") and text.contains(x.log, "vault-root-token-v1"), x.log)
T:arm("2 PREMISE a warm room has all three", #left(room(true)) == 3, "it does not")
T:arm("3 the installation anchor is never cleared", x.log ~= "" and not text.contains(x.log, "installation-uuid-v1"), x.log)
x = clear(room(false))
T:arm("4 clearing a cold room succeeds", x.rc == 0, x.why)
x = clear(room(true), "0")
T:arm("5 no consent refuses (2) and clears nothing", x.rc == 2 and #x.left == 3 and x.log == "", x.why)
x = clear(room(true), nil, "--dry-run")
T:arm("6 --dry-run removes nothing and touches no keychain item", #x.left == 3 and x.log == "", x.why)
T:finish()
