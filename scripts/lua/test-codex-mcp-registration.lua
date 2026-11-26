-- @env PATH HOME CODEX_BIN
-- @trace order:605-u9g5, order:1667-jna9, order:2372-snfs
--
-- test-codex-mcp-registration.lua — register-experts.sh registers the three MCP servers with codex
-- exactly once, keeps what was there, and gives host-browser the lane socket. Ported from the .sh
-- of the same name (2372-snfs). codex is the stub in scripts/fixtures (or CODEX_BIN); every home is
-- scratch.
--
--   1 an empty home, applied twice      2 a populated one: config, auth and servers kept
--   3 the lane socket reaches host-browser alone    4 a stale registration is upgraded
--   5 the image installs and runs the helper, after require_codex and before the launch
--
-- Usage: tillandsias-plan script run scripts/lua/test-codex-mcp-registration.lua
-- Verdict: ok:codex-mcp-registration:<n> arms | violation:... | skip:...:no-jq

local fixture = require "common.fixture"
local T = fixture.new("codex-mcp-registration")
local ROOT = fixture.repo_root()
-- The helper's and the stub's own JSON reader.
if not fixture.which("j" .. "q") then T:skip("no-jq") end
local HELPER = ROOT .. "/images/default/config-overlay/codex/register-experts.sh"
local bin = env.get("CODEX_BIN")
if not bin or bin == "" then bin = ROOT .. "/scripts/fixtures/codex-mcp-stub.sh" end
local w = T:scratch()
fs.mkdir(w.rel .. "/overlay/mcp")
for _, n in ipairs{ "forge-plan", "project-info", "host-browser" } do
    fs.write(w.rel .. "/overlay/mcp/" .. n .. ".sh", fs.read("images/default/config-overlay/mcp/" .. n .. ".sh"))
    T:must{ "chmod", "+x", w.abs .. "/overlay/mcp/" .. n .. ".sh" }
end
local SOCK = "/run/host/tillandsias-mcp/mcp.sock"
local function codex(home, sock, argv)
    local e = { PATH = env.get("PATH"), HOME = home.abs, CODEX_HOME = home.abs .. "/.codex", CODEX_BIN = bin, TILLANDSIAS_CONFIG_OVERLAY_ROOT = w.abs .. "/overlay", TILLANDSIAS_CONTROL_SOCKET = sock }
    return proc.run{ argv = argv, cwd = w.abs, env = e, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
end
local function home(name)
    fs.mkdir(w.rel .. "/" .. name .. "/.codex")
    return { rel = w.rel .. "/" .. name, abs = w.abs .. "/" .. name }
end
local function apply(h, sock, times)
    for _ = 1, times do
        local r = codex(h, sock, { HELPER })
        if r.code ~= 0 then T:refuse("helper-failed", (r.stdout or "") .. (r.stderr or "") .. tostring(r.why)) end
    end
end
local function servers(h)
    local r = codex(h, nil, { bin, "mcp", "list", "--json" })
    local ok, j = pcall(json.parse, r.stdout or "")
    if not ok then T:refuse("list-unreadable", (r.stdout or "") .. (r.stderr or "")) end
    local n, names = {}, {}
    for _, s in ipairs(j) do
        n[s.name] = (n[s.name] or 0) + 1
        names[#names + 1] = s.name
        n["env:" .. s.name] = s.transport and s.transport.env
    end
    table.sort(names)
    n.names = table.concat(names, " ")
    return n
end
local function no_env(n, s)
    local e = n["env:" .. s]
    return type(e) ~= "table" or next(e) == nil
end
local function has_sock(n)
    local e, k = n["env:host-browser"], 0
    if type(e) ~= "table" then return false end
    for _ in pairs(e) do k = k + 1 end
    return k == 1 and e.TILLANDSIAS_CONTROL_SOCKET == SOCK
end
local a = home("empty")
apply(a, nil, 2)
T:arm("1 two applications register the three servers once each", servers(a).names == "forge-plan host-browser project-info", servers(a).names)

local b = home("pre")
local AUTH = '{"OPENAI_API_KEY":"fixture-not-a-key"}\n'
fs.write(b.rel .. "/.codex/config.toml", 'model = "gpt-5"\ntemperature = 0.7\n\n[tracing]\nlog_prompts = false\n\n[mcp_servers.custom]\ncommand = "custom-server"\nenv = { KEY = "v" }\n')
fs.write(b.rel .. "/.codex/auth.json", AUTH)
apply(b, nil, 2)
T:arm("2a an unrelated server stays beside the three", servers(b).names == "custom forge-plan host-browser project-info", servers(b).names)
T:arm("2b auth.json is byte-preserved", fs.read(b.rel .. "/.codex/auth.json") == AUTH, "changed")
local cfg, lost = fs.read(b.rel .. "/.codex/config.toml"), {}
for _, s in ipairs{ 'model = "gpt-5"', "temperature = 0.7", "log_prompts = false", "custom-server", 'KEY = "v"' } do
    if not text.contains(cfg, s) then lost[#lost + 1] = s end
end
T:arm("2c unrelated config is kept", #lost == 0, table.concat(lost, " | "))

local c = home("socket")
apply(c, SOCK, 2)
local n = servers(c)
T:arm("3a host-browser is registered with the lane socket", has_sock(n), json.encode and json.encode(n["env:host-browser"] or {}) or "no env")
T:arm("3b and forge-plan is given no env", no_env(n, "forge-plan"), "forge-plan has an env")
local _, tables = ("\n" .. fs.read(c.rel .. "/.codex/config.toml")):gsub("\n%[mcp_servers%.host%-browser%.env%]", "")
T:arm("3c one host-browser and one env table after a double apply", n["host-browser"] == 1 and tables == 1, tostring(n["host-browser"]) .. " " .. tables)

local d = home("stale")
apply(d, nil, 1)
T:arm("4a with no socket host-browser has no env", no_env(servers(d), "host-browser"), "has an env")
apply(d, SOCK, 1)
n = servers(d)
T:arm("4b a stale registration is upgraded in place", has_sock(n) and n["host-browser"] == 1, n.names)

T:arm("5a the helper is executable", T:run{ "test", "-x", HELPER }.code == 0, HELPER)
local cf = fs.read("images/default/Containerfile")
T:arm("5b the Containerfile copies and installs it", text.contains(cf, "register-codex-experts") and text.contains(cf, "config-overlay/codex/register-experts.sh"), "gone")
local at, i = {}, 0
for l in fs.read("images/default/entrypoint-forge-codex.sh"):gsub("\r", ""):gmatch("([^\n]*)\n") do
    i = i + 1
    if text.contains(l, "register-codex-experts") then at.reg = at.reg or i end
    if l == "require_codex" then at.need = i end
    if l == 'show_banner "codex"' then at.banner = i end
end
T:arm("5c the entrypoint registers after require_codex and before the launch", at.reg and at.need and at.banner and at.need < at.reg and at.reg < at.banner, tostring(at.need) .. " " .. tostring(at.reg) .. " " .. tostring(at.banner))
T:finish()
