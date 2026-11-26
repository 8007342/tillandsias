-- @env PATH
-- @trace spec:default-image, order:1437-y2wu, order:2320-b5vv
--
-- test-claude-forge-bypass-preaccepted.lua — the bypass-permissions consent is a launch-time
-- SEED: forge-gated, additive, never a value remembered from a Vault harvest (operator
-- directive 2026-09-27). Ported from the .sh of the same name (2320-b5vv). Each arm has its
-- own scratch HOME. Only seed_claude_bypass_consent is loaded: sourcing lib-common.sh whole
-- runs forge-only CA setup.
--
--   1 EMPTY     forge, no config: both keys land, true, and the files are valid JSON
--   2 KEEPS     forge, unrelated keys survive
--   3 FALSE     forge, an explicit false stays false (additive; and jq's // reads it as absent)
--   4 NOOP      not a forge: nothing is created
--   5 UNTOUCHED not a forge: existing files keep their bytes
--   6 RESTORE   the approvals restore merges vault UNDER local, so it cannot undo the seed
--   7 ORDER     the entrypoint runs first-run seed < bypass seed < restore
--
-- Usage: tillandsias-plan script run scripts/lua/test-claude-forge-bypass-preaccepted.lua
-- Verdict: ok:claude-forge-bypass-preaccepted:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("claude-forge-bypass-preaccepted")
local SH = fixture.posix_shell()
local fn = ("\n" .. fs.read("images/default/lib-common.sh")):match("\n(seed_claude_bypass_consent%(%).-\n}\n)")
if not fn then T:refuse("no-subject", "seed_claude_bypass_consent() is not in images/default/lib-common.sh") end
if not fixture.which("jq") then T:skip("no-jq") end
local ACCEPT, SKIP = "bypassPermissionsModeAccepted", "skipDangerousModePermissionPrompt"

local function seed(kind, cfg, set)
    local d = T:scratch()
    if cfg then fs.write(d.rel .. "/.claude.json", cfg) end
    if set then fs.mkdir(d.rel .. "/.claude"); fs.write(d.rel .. "/.claude/settings.json", set) end
    local r = T:run{ SH, "-s", "--", kind or "", cwd = d.abs, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 30000,
        stdin = 'export HOME="$PWD"; unset CLAUDE_CONFIG_FILE CLAUDE_SETTINGS_FILE\n[ -z "$1" ] || export TILLANDSIAS_HOST_KIND="$1"\n'
            .. "trace_lifecycle() { :; }\n" .. fn .. "seed_claude_bypass_consent </dev/null\n" }
    local function read(f) return fs.exists(d.rel .. "/" .. f) and fs.read(d.rel .. "/" .. f) or nil end
    local function parse(s) local ok, v = pcall(json.parse, s or ""); return ok and type(v) == "table" and v or {} end
    local w = { rc = r.code, cfg = read(".claude.json"), set = read(".claude/settings.json"), dir = fs.exists(d.rel .. "/.claude") }
    w.c, w.s = parse(w.cfg), parse(w.set)
    w.why = "rc=" .. tostring(r.code) .. " cfg=" .. tostring(w.cfg) .. " set=" .. tostring(w.set) .. " " .. (r.stderr or "")
    return w
end
local w = seed("forge")
T:arm("1 EMPTY both keys land, true", w.rc == 0 and w.c[ACCEPT] == true and w.s[SKIP] == true, w.why)
w = seed("forge", '{"hasCompletedOnboarding": true, "theme": "dark", "projects": {"/x": {"hasTrustDialogAccepted": true}}}\n',
    '{"someOtherSetting": "kept", "mcpServers": {"foo": {}}}\n')
T:arm("2 KEEPS unrelated keys survive beside the seed", w.rc == 0 and w.c[ACCEPT] == true and w.s[SKIP] == true
    and w.c.hasCompletedOnboarding == true and w.c.theme == "dark" and type(w.c.projects) == "table" and type(w.c.projects["/x"]) == "table"
    and w.c.projects["/x"].hasTrustDialogAccepted == true and w.s.someOtherSetting == "kept" and type(w.s.mcpServers) == "table" and w.s.mcpServers.foo ~= nil, w.why)
w = seed("forge", '{"' .. ACCEPT .. '": false}\n', '{"' .. SKIP .. '": false}\n')
T:arm("3 FALSE an explicit false stays false", w.rc == 0 and w.c[ACCEPT] == false and w.s[SKIP] == false, w.why)
w = seed(nil)
T:arm("4 NOOP not a forge creates nothing", w.rc == 0 and w.cfg == nil and w.set == nil and not w.dir, w.why)
local CFG, SET = '{"hasCompletedOnboarding": true}\n', '{"someOtherSetting": "kept"}\n'
w = seed(nil, CFG, SET)
T:arm("5 UNTOUCHED not a forge leaves existing bytes alone", w.rc == 0 and w.cfg == CFG and w.set == SET, w.why)

local av = fs.read("images/default/claude-approvals-vault.sh")
T:arm("6 RESTORE merges vault under local", text.contains(av, 'jq --argjson v "$doc"') and text.contains(av, "($v * .)"), "claude-approvals-vault.sh")
local at, n = {}, 0
for l in (fs.read("images/default/entrypoint-forge-claude.sh") .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    if l == "seed_claude_first_run_defaults" then at[1] = at[1] or n end
    if l == "seed_claude_bypass_consent" then at[2] = at[2] or n end
    if not l:find("^%s*#") and text.contains(l, "claude-approvals-vault restore") then at[3] = at[3] or n end
end
T:arm("7 ORDER first-run seed, then bypass seed, then restore", at[1] and at[2] and at[3] and at[1] < at[2] and at[2] < at[3] or false,
    tostring(at[1]) .. " " .. tostring(at[2]) .. " " .. tostring(at[3]))
T:finish()
