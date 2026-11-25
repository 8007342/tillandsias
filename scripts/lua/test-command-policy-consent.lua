-- @env PATH HOME
-- @trace order:1443-9f5w, order:2372-snfs
--
-- test-command-policy-consent.lua — a consent token is minted by a person outside a forge, spent
-- once, for its own argv on its own host. Ported from the .sh of the same name (2372-snfs). Tokens
-- and the audit log are scratch; the reset programs are stubs named by absolute path, and the run
-- stops before any arm if their argv leaves its class.
--
--   1 grant: one 0600 token             2 eval inspects, the run door spends, a replay asks again
--   3 foreign host, expired, other argv: refused at the run door
--   4 a forge cannot grant              5 the smoke skill's env takes soft-reset only
--   6 no self-consent                   7 no argv, unknown class
--   8 in a forge a planted token is neither honoured nor spent   9 one token, one rm
--
-- Usage: tillandsias-plan script run scripts/lua/test-command-policy-consent.lua
-- Verdict: ok:command-policy-consent:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("command-policy-consent")
local SH, PLAN = fixture.posix_shell(), fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end
local d = T:scratch()
local CD = d.abs .. "/consent"
fs.mkdir(d.rel .. "/bin")
-- A workspace of its own, so a sibling of it is outside.
T:must{ "git", "init", "-q", d.abs .. "/cwd" }
for _, p in ipairs{ "podman", "wsl" } do
    fs.write(d.rel .. "/bin/" .. p, "#!/bin/sh\necho \"STUB-" .. p .. " $*\"\n")
    T:must{ "chmod", "+x", d.abs .. "/bin/" .. p }
end
local SOFT, WSL = { d.abs .. "/bin/podman", "system", "reset", "--force" }, { d.abs .. "/bin/wsl", "--unregister" }
local function cat(a, ...)
    local l = {}
    for _, v in ipairs(a) do l[#l + 1] = v end
    for _, v in ipairs{ ... } do l[#l + 1] = v end
    return l
end
-- The door under test is the CHILD's: a shell starts it, so this door judges nothing but the shell.
local function plan(e, verb, argv)
    local env_ = { PATH = env.get("PATH"), HOME = env.get("HOME") }
    local pre = "export TILLANDSIAS_CONSENT_DIR='" .. CD .. "' TILLANDSIAS_POLICY_AUDIT_LOG='" .. d.abs .. "/audit.jsonl'\n"
    for k, v in pairs(e or {}) do pre = pre .. "export " .. k .. "='" .. v .. "'\n" end
    local a = { SH, "-s", "--", PLAN }
    for _, v in ipairs(verb) do a[#a + 1] = v end
    if argv then
        a[#a + 1] = "--"
        for _, v in ipairs(argv) do a[#a + 1] = v end
    end
    local r = proc.run{ argv = a, cwd = d.abs .. "/cwd", env = env_, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 30000, stdin = pre .. 'exec "$@" </dev/null\n' }
    local o = text.trim(r.stdout or "")
    return { rc = r.code, out = o, why = "rc=" .. tostring(r.code) .. " [" .. o:sub(1, 500) .. "] " .. (r.stderr or ""):sub(1, 200) }
end
local function eval(argv, e) return plan(e, { "policy", "eval" }, argv) end
local function grant(class, argv, e) return plan(e, { "policy", "consent", "grant", class }, argv) end
local function go(argv, e)
    local x = plan(e, { "run", "--json" }, argv)
    local ok, j = pcall(json.parse, x.out)
    x.j = ok and type(j) == "table" and j or {}
    x.p = type(x.j.policy) == "table" and x.j.policy or {}
    return x
end
local function tokens()
    local n = 0
    if fs.exists(d.rel .. "/consent") then
        for _, f in ipairs(fs.list(d.rel .. "/consent")) do
            if f:match("%.json$") then n = n + 1 end
        end
    end
    return n
end
local HOST = text.trim(T:must{ "uname", "-n" }.stdout):lower()
local function plant(id, class, host, expires)
    fs.mkdir(d.rel .. "/consent")
    fs.write(d.rel .. "/consent/" .. id .. ".json", '{"version":1,"id":"' .. id .. '","class":"' .. class .. '","host":"' .. host
        .. '","argv_digest":"x","argv_shown":"x","granted_at":"2026-01-01T00:00:00Z","expires_at":"' .. expires .. '"}\n')
end
local function planted(id) return fs.exists(d.rel .. "/consent/" .. id .. ".json") end
local function source()
    local last
    if not fs.exists(d.rel .. "/audit.jsonl") then return nil end
    for l in fs.read(d.rel .. "/audit.jsonl"):gmatch("[^\n]+") do last = l end
    local ok, j = pcall(json.parse, last or "")
    return ok and j.consent_source or nil
end
local a, b = eval(SOFT), eval(cat(WSL, "x"))
if a.out ~= "consent:policy:soft-reset" or b.out ~= "consent:policy:hard-reset" then T:refuse("stub-argv-left-its-class", a.why .. b.why) end

local x = grant("soft-reset", SOFT, { TILLANDSIAS_HOST_KIND = "forge" })
T:arm("4 a forge cannot grant, and nothing is written", x.rc == 1 and x.out == "refused:consent:not-grantable-in-forge" and tokens() == 0, x.why)
x = eval{ "tillandsias-plan", "policy", "consent", "grant", "hard-reset", "--", "wsl", "--unregister", "x" }
T:arm("6 minting through an agent door is refused", x.rc == 1 and x.out == "refused:policy:no-self-consent", x.why)
a, b = grant("hard-reset"), grant("everything", { "true" })
T:arm("7 a grant with no argv, or an unknown class, is refused by name", a.rc == 1 and a.out == "refused:consent:no-argv" and b.rc == 1 and b.out == "refused:consent:unknown-class:everything", a.why .. b.why)

local rec = T:run{ "cat", "/run/.containerenv" }
local img = rec.code == 0 and ("\n" .. (rec.stdout or "")):match('\nimage="([^"\n]*)"') or ""
local base = img:match("([^/]*)$")
if base:match("^tillandsias%-forge$") or base:match("^tillandsias%-forge[:@]") then
    plant("workspace-destroy-planted", "workspace-destroy", HOST, "2099-01-01T00:00:00Z")
    x = eval{ "rm", "-rf", "/srv/elsewhere" }
    T:arm("8 in a forge a planted token is not honoured and not spent", x.rc == 4 and x.out == "consent:policy:workspace-destroy" and planted("workspace-destroy-planted"), x.why)
    out.line("skip: 1 2 3 5 9 this is a forge, where consent is never granted; run on bare metal")
    T:finish()
end
out.line("skip: 8 not a forge")
x = plan(nil, { "policy", "consent", "grant", "soft-reset", "--ttl", "30m" }, SOFT)
local file = fs.exists(d.rel .. "/consent") and fs.list(d.rel .. "/consent")[1] or ""
local m = T:run{ "stat", "-c", "%a", CD .. "/" .. file }
if m.code ~= 0 then m = T:run{ "stat", "-f", "%Lp", CD .. "/" .. file } end
T:arm("1 grant prints its expiry and writes one 0600 token", x.rc == 0 and x.out:match("^ok:consent:soft%-reset:until=20[0-9-]+T[0-9:]+Z$") ~= nil and tokens() == 1 and text.trim(m.stdout or "") == "600", x.why .. " mode=" .. (m.stdout or ""))
x = eval(SOFT)
T:arm("2a eval asks and spends nothing", x.rc == 4 and x.out == "consent:policy:soft-reset" and tokens() == 1, x.why)
x = go(SOFT)
T:arm("2b the run door spends it for one run", x.rc == 0 and x.j.status == "exited" and text.contains(tostring(x.j.stdout), "STUB-podman system reset --force") and source() == "token", x.why .. tostring(source()))
x = go(SOFT)
T:arm("2c the replay asks again and says it was spent", x.rc == 4 and x.j.status == "policy_consent" and text.contains(tostring(x.p.why), "already spent"), x.why)
plant("soft-reset-foreign", "soft-reset", "not-" .. HOST, "2099-01-01T00:00:00Z")
x = go(SOFT)
T:arm("3a a foreign host's token is refused, named and deleted", x.rc == 1 and x.j.status == "policy_denied" and text.contains(tostring(x.p.why), "minted on another host") and not planted("soft-reset-foreign"), x.why)
plant("soft-reset-old", "soft-reset", HOST, "2020-01-01T00:00:00Z")
x = go(SOFT)
T:arm("3b so is an expired one", x.rc == 1 and text.contains(tostring(x.p.why), "expired unused") and not planted("soft-reset-old"), x.why)
a = grant("hard-reset", cat(WSL, "distro-a"))
x = go(cat(WSL, "distro-b"))
T:arm("3c a token for another argv is refused and kept for its own run", a.rc == 0 and x.rc == 1 and text.contains(tostring(x.p.why), "DIFFERENT argv") and tokens() == 1, a.why .. x.why)
T:must{ "rm", "-r", CD }
local OK, SMOKE = { TILLANDSIAS_DESTRUCTIVE_RESET_OK = "1" }, { TILLANDSIAS_DESTRUCTIVE_RESET_OK = "1", TILLANDSIAS_SKILL = "smoke-curl-install-and-test-e2e" }
x = go(SOFT, SMOKE)
T:arm("5a the smoke skill's env runs a soft reset", x.rc == 0 and x.j.status == "exited" and source() == "env", x.why .. tostring(source()))
x = eval(SOFT, SMOKE)
T:arm("5b while eval still only inspects", x.rc == 4 and x.out == "consent:policy:soft-reset", x.why)
x = go(SOFT, OK)
T:arm("5c without the skill it asks", x.rc == 4 and x.p.rule_id == "soft-reset", x.why)
x = go(cat(WSL, "x"), SMOKE)
T:arm("5d and a hard reset never takes it", x.rc == 4 and x.p.rule_id == "hard-reset", x.why)
fs.mkdir(d.rel .. "/victim")
local RM = { "rm", "-rf", d.abs .. "/victim" }
a = grant("workspace-destroy", RM)
x = go(RM)
T:arm("9a a token lets its rm run once", a.rc == 0 and x.rc == 0 and x.j.status == "exited" and x.p.rule_id == "workspace-destroy" and not fs.exists(d.rel .. "/victim"), a.why .. x.why)
fs.mkdir(d.rel .. "/victim")
x = go(RM)
T:arm("9b the next identical rm asks and removes nothing", x.rc == 4 and x.j.status == "policy_consent" and fs.exists(d.rel .. "/victim"), x.why)
T:finish()
