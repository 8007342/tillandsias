-- @env PATH HOME TILLANDSIAS_TEST_REAL_AGY
-- @trace order:1447-nmq3, order:2387-b6v2
--
-- test-forge-project-trust-seeds.lua — the forge entrypoints pre-accept each harness's trust prompt
-- for the project, idempotently, without eating the harness's own settings, and only in a forge.
-- Ported from the .sh of the same name (2387-b6v2). The three seed functions are cut from
-- images/default/lib-common.sh and run by bash in a scratch HOME; Lua reads what they wrote.
--
--   claude/codex/agy: one entry keyed without the trailing slash, after two runs
--   merges keep the other keys; an existing codex project entry and a non-JSON agy file are left
--   a non-forge HOME gets nothing; each entrypoint seeds after find_project_dir; claude's order
--   optional: a real codex loads the seeded config (and rejects a wrong-typed one); a real agy
--   (TILLANDSIAS_TEST_REAL_AGY=1, it starts a sign-in) loads it (and rejects a map-shaped one)
--
-- Usage: tillandsias-plan script run scripts/lua/test-forge-project-trust-seeds.lua
-- Verdict: ok:forge-project-trust-seeds:<n> arms | violation:... | skip:...:no-jq

local fixture = require "common.fixture"
-- Git's own bash on native Windows, never WSL's (2246-fkea).
local BASH = fixture.posix_shell()
local T = fixture.new("forge-project-trust-seeds")
local ROOT = fixture.repo_root()
local LIB = ROOT .. "/images/default/lib-common.sh"
if not fixture.which("jq") then T:skip("no-jq") end
local w = T:scratch()
-- Cut the three functions, then run them in order; trace_lifecycle is a no-op as in the image.
local SEED = [[lib="$1"; proj="$2"; shift 2
trace_lifecycle() { :; }
for fn in seed_claude_project_trust seed_codex_project_trust seed_agy_workspace_trust; do
    eval "$(sed -n "/^$fn()/,/^}/p" "$lib")"
    declare -F "$fn" >/dev/null || { echo "undefined:$fn"; exit 7; }
done
for fn in "$@"; do "$fn" "$proj"; done
]]
local ALL = { "seed_claude_project_trust", "seed_codex_project_trust", "seed_agy_workspace_trust" }
-- A fresh HOME; PROJ is what find_project_dir returns (trailing slash), KEY how the harnesses key it.
local function home(name)
    local h = { rel = w.rel .. "/" .. name, abs = w.abs .. "/" .. name }
    T:must{ "rm", "-rf", h.abs }; fs.mkdir(h.rel .. "/src/demo")
    h.proj, h.key, h.codex = h.abs .. "/src/demo/", h.abs .. "/src/demo", h.abs .. "/.codex-worker"
    return h
end
local function seed(h, kind, fns)
    local argv = { BASH, "-s", "--", LIB, h.proj }
    for _, f in ipairs(fns or ALL) do argv[#argv + 1] = f end
    local e = { PATH = env.get("PATH"), HOME = h.abs, CODEX_HOME = h.codex, TILLANDSIAS_HOST_KIND = kind }
    local r = proc.run{ argv = argv, stdin = SEED, env = e, env_unset = { "TILLANDSIAS_*", "CLAUDE_CONFIG_FILE", "AGY_SETTINGS_FILE" }, timeout_ms = 60000 }
    if r.code == 7 then T:refuse("seed-undefined", r.stdout) end
    return r
end
local function read(p) local r = T:run{ "cat", p }; return r.code == 0 and r.stdout or nil end
local function J(p) local s = read(p); if not s then return nil end local ok, v = pcall(json.parse, s); return ok and v or nil end
local function lines(s) local l = {}; for x in ((s or "") .. "\n"):gmatch("([^\n]*)\n") do l[#l + 1] = x end; return l end
local function count(s, want) local n = 0; for _, x in ipairs(lines(s)) do if x == want then n = n + 1 end end; return n end
local function keys(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end
local AGY = "/.gemini/antigravity-cli/settings.json"

local h = home("forge1")
seed(h, "forge"); seed(h, "forge")
local c = J(h.abs .. "/.claude.json")
T:arm("claude: projects[KEY].hasTrustDialogAccepted = true, and no trailing-slash key",
    c and c.projects and c.projects[h.key] and c.projects[h.key].hasTrustDialogAccepted == true and keys(c.projects) == 1, read(h.abs .. "/.claude.json"))
local toml = read(h.codex .. "/config.toml") or ""
local hdr, after = '[projects."' .. h.key .. '"]', nil
for i, x in ipairs(lines(toml)) do if x == hdr then after = lines(toml)[i + 1] end end
T:arm("codex: exactly one [projects.\"KEY\"] with trust_level = \"trusted\" after two runs", count(toml, hdr) == 1 and after == 'trust_level = "trusted"', toml)
local a = J(h.abs .. AGY)
T:arm("agy: trustedWorkspaces = [KEY] and approvalMode = \"auto\" after two runs",
    a and type(a.trustedWorkspaces) == "table" and #a.trustedWorkspaces == 1 and a.trustedWorkspaces[1] == h.key and a.approvalMode == "auto", read(h.abs .. AGY))

h = home("forge2")
fs.write(h.rel .. "/.claude.json", '{"hasCompletedOnboarding": true, "bypassPermissionsModeAccepted": true,\n "projects": {"' .. h.key .. '": {"hasTrustDialogAccepted": false, "allowedTools": ["Bash"]},\n              "/other/project": {"hasTrustDialogAccepted": false}}}\n')
fs.mkdir(h.rel .. "/.codex-worker")
fs.write(h.rel .. "/.codex-worker/config.toml", '[mcp_servers.forge-plan]\ncommand = "tillandsias-plan"')   -- no trailing newline
fs.mkdir(h.rel .. "/.gemini/antigravity-cli")
fs.write(h.rel .. AGY, '{"colorScheme": "dark", "trustedWorkspaces": ["/else/where"]}\n')
seed(h, "forge")
c = J(h.abs .. "/.claude.json")
local p = c and c.projects and c.projects[h.key]
T:arm("claude: Claude's own not-yet-asked false becomes true; other keys and projects preserved",
    c and c.hasCompletedOnboarding == true and c.bypassPermissionsModeAccepted == true and p and p.hasTrustDialogAccepted == true
    and type(p.allowedTools) == "table" and #p.allowedTools == 1 and p.allowedTools[1] == "Bash" and c.projects["/other/project"].hasTrustDialogAccepted == false, read(h.abs .. "/.claude.json"))
toml = read(h.codex .. "/config.toml") or ""
T:arm("codex: the mcp_servers table survives; the project table is appended on its own line",
    count(toml, "[mcp_servers.forge-plan]") == 1 and count(toml, 'command = "tillandsias-plan"') == 1 and count(toml, hdr:gsub("forge1", "forge2")) == 1, toml)
a = J(h.abs .. AGY)
T:arm("agy: other settings and trusted workspaces preserved, approvalMode auto seeded, project appended",
    a and a.colorScheme == "dark" and a.approvalMode == "auto" and type(a.trustedWorkspaces) == "table" and #a.trustedWorkspaces == 2
    and a.trustedWorkspaces[1] == "/else/where" and a.trustedWorkspaces[2] == h.key, read(h.abs .. AGY))
local untrusted = '[projects."' .. h.key .. '"]\ntrust_level = "untrusted"\n'
fs.write(h.rel .. "/.codex-worker/config.toml", untrusted)
seed(h, "forge", { "seed_codex_project_trust" })
T:arm("codex: an existing [projects.\"<path>\"] entry is never rewritten", read(h.codex .. "/config.toml") == untrusted, read(h.codex .. "/config.toml"))
fs.write(h.rel .. AGY, "not json")
seed(h, "forge", { "seed_agy_workspace_trust" })
T:arm("agy: a settings.json that is not a JSON object is left untouched", read(h.abs .. AGY) == "not json", read(h.abs .. AGY))

h = home("baremetal")
seed(h, nil)
local written = text.trim(T:run{ "find", h.abs, "-type", "f" }.stdout or "")
T:arm("non-forge: no file written under HOME", written == "", written)

-- Line of the first line containing a literal, in an entrypoint.
local function line_of(ep, lit)
    for i, x in ipairs(lines(fs.read("images/default/" .. ep))) do if text.contains(x, lit) then return i end end
end
for _, pr in ipairs{ { "entrypoint-forge-claude.sh", 'seed_claude_project_trust "$PROJECT_DIR"' },
                     { "entrypoint-forge-codex.sh", 'seed_codex_project_trust "$PROJECT_DIR"' },
                     { "entrypoint-forge-antigravity.sh", 'seed_agy_workspace_trust "$PROJECT_DIR"' } } do
    local cl, fl = line_of(pr[1], pr[2]), line_of(pr[1], "find_project_dir")
    T:arm(pr[1] .. " calls the seed after find_project_dir", cl and fl and cl > fl, "seed call line=[" .. tostring(cl) .. "], find_project_dir line=[" .. tostring(fl) .. "]")
end
local ct = line_of("entrypoint-forge-claude.sh", 'seed_claude_project_trust "$PROJECT_DIR"')
local rs = line_of("entrypoint-forge-claude.sh", "claude-approvals-vault restore")
local bp = line_of("entrypoint-forge-claude.sh", "seed_claude_bypass_consent")
T:arm("claude order: bypass seed < approvals restore < project trust seed", rs and bp and ct and bp < rs and rs < ct, "bypass=" .. tostring(bp) .. " restore=" .. tostring(rs) .. " trust=" .. tostring(ct))

-- Optional arms against the real harnesses, when they are installed.
local agy = env.get("TILLANDSIAS_TEST_REAL_AGY") == "1" and fixture.which("agy")
if agy then
    h = home("agyreal"); seed(h, "forge", { "seed_agy_workspace_trust" })
    local function ping() proc.run{ argv = { "timeout", "12", agy, "-p", "ping" }, cwd = h.key, env = { PATH = env.get("PATH"), HOME = h.abs }, stdin = "", timeout_ms = 20000 } end
    local function logs() return T:run{ "sh", "-s", "--", h.abs, stdin = 'cat "$1"/.gemini/antigravity-cli/log/*.log 2>/dev/null\n' }.stdout or "" end
    ping(); local lg = logs()
    T:arm("agy: loads the seeded settings.json without 'invalid settings'", lg ~= "" and not text.contains(lg, "invalid settings"), lg:sub(1, 300))
    fs.write(h.rel .. AGY, '{"trustedWorkspaces": {"' .. h.key .. '": true}}\n'); T:must{ "rm", "-rf", h.abs .. "/.gemini/antigravity-cli/log" }
    ping()
    T:arm("agy control: a map-shaped trustedWorkspaces IS rejected (so the check above can fail)", text.contains(logs(), "invalid settings: trustedWorkspaces"), "the map form was not rejected")
elseif env.get("TILLANDSIAS_TEST_REAL_AGY") == "1" then
    out.line("note:forge-project-trust-seeds:optional-arm-skipped:real-agy-absent")
else
    out.line("note:forge-project-trust-seeds:optional-arm-skipped:real-agy-not-opted-in (TILLANDSIAS_TEST_REAL_AGY=1; it starts a sign-in)")
end
local codex = fixture.which("codex")
if codex then
    h = home("codexreal"); fs.mkdir(h.rel .. "/.codex-worker")
    fs.write(h.rel .. "/.codex-worker/config.toml", '[mcp_servers.demo]\ncommand = "true"')
    seed(h, "forge", { "seed_codex_project_trust" })
    local function list() local r = proc.run{ argv = { "timeout", "30", codex, "mcp", "list" }, env = { PATH = env.get("PATH"), HOME = h.abs, CODEX_HOME = h.codex }, timeout_ms = 40000 }; return r, (r.stdout or "") .. (r.stderr or "") end
    local r, o = list()
    T:arm("codex: loads the seeded config.toml (mcp table intact)", r.code == 0 and ("\n" .. o):find("\ndemo ") ~= nil, o:sub(-300))
    fs.write(h.rel .. "/.codex-worker/config.toml", read(h.codex .. "/config.toml") .. '\n[projects."' .. h.abs .. '/src/other"]\ntrust_level = 42\n')
    _, o = list()
    T:arm("codex control: a wrong-typed projects.<path>.trust_level is rejected by name", text.contains(o, "trust_level"), "accepted; the key may be ignored")
else
    out.line("note:forge-project-trust-seeds:optional-arm-skipped:real-codex-absent")
end
T:finish()
