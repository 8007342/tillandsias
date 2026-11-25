-- @env PATH
-- @trace order:1705-bgen, order:2300-6m9m, spec:project-bootstrap-readme
--
-- test-start-a-new-project-skill.lua — the end-user onboarding skill exists, reaches a forge
-- on ANY project, sets a new project up without overwriting anything, and speaks to end
-- users without internal vocabulary. Ported from the .sh of the same name (2300-6m9m).
--
--   1 the skill and its scaffold exist in canonical skills/
--   2 agent-profile.sh links it into a forge's Claude Code, Codex and OpenCode skill dirs
--   3 in an empty repo the scaffold creates openspec/, plan/, research/ and README.md, with
--     no openspec CLI on PATH
--   4 a second run creates nothing, and an existing README.md is kept
--   5 --no-specs creates no openspec/; a usage error exits 2
--   6 SKILL.md and every created file carry no internal vocabulary (and the scan sees a
--     planted word)
--
-- Usage: tillandsias-plan script run scripts/lua/test-start-a-new-project-skill.lua
-- Verdict: ok:start-a-new-project-skill:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("start-a-new-project-skill")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local SK = "skills/start-a-new-project"
local SCAFFOLD = ROOT .. "/" .. SK .. "/scaffold.sh"
local S = T:scratch()
local function read(p) return fs.exists(p) and fs.read(p) or "" end
local skill = read(SK .. "/SKILL.md")
T:arm("1 the skill and its scaffold exist", ("\n" .. skill):find("\nname: start-a-new-project\n", 1, true) ~= nil and fs.exists(SK .. "/scaffold.sh"), SK)

fs.mkdir(S.rel .. "/home"); fs.mkdir(S.rel .. "/opt-skills")
T:must{ "cp", "-R", ROOT .. "/" .. SK, S.abs .. "/opt-skills/" }
local prof = proc.run{ argv = { SH, "-s", "--", ROOT .. "/images/default/config-overlay/mcp/agent-profile.sh" }, timeout_ms = 60000,
    env = { PATH = env.get("PATH"), HOME = S.abs .. "/home", TILLANDSIAS_SHARED_SKILLS_ROOT = S.abs .. "/opt-skills" },
    stdin = 'set -e\n. "$1" >/dev/null 2>&1 </dev/null\n' }
local links = prof.code == 0
for _, d in ipairs{ ".claude", ".codex", ".config/opencode" } do
    links = links and proc.run{ argv = { "test", "-L", S.abs .. "/home/" .. d .. "/skills/start-a-new-project" }, timeout_ms = 10000 }.code == 0
end
T:arm("2 a forge on any project links it for Claude Code, Codex and OpenCode", links, "rc=" .. tostring(prof.code))

-- a PATH with no openspec CLI: only the tools the scaffold needs
fs.mkdir(S.rel .. "/bin")
-- native-argv: tool NAMES to look up and link into the scratch PATH, never an argv[1]
for _, t in ipairs{ "bash", "cat", "mkdir", "dirname", "tr", "sed", "git", "env" } do
    local w = proc.run{ argv = { SH, "-s", "--", t }, stdin = 'command -v "$1"\n', env = { PATH = env.get("PATH") }, timeout_ms = 10000 }
    local p = text.trim(w.stdout or "")
    if p ~= "" then T:must{ "ln", "-s", p, S.abs .. "/bin/" .. t } end
end
local function scaffold(...)
    local a = { SH, SCAFFOLD }
    for _, x in ipairs{ ... } do a[#a + 1] = x end
    local x = proc.run{ argv = a, env = { PATH = S.abs .. "/bin", HOME = S.abs .. "/home" }, timeout_ms = 60000 }
    return x.code, text.trim((x.stdout or "") .. (x.stderr or ""))
end
local function last(o) local l = text.lines(o); return l[#l] or "" end
local P = "/proj"
fs.mkdir(S.rel .. P); T:must{ "git", "-C", S.abs .. P, "init", "-q" }
local c, o = scaffold("--dir", S.abs .. P, "--name", "Pong Party", "--summary", "A two-player pong game for phones.", "--stack", "flutter-flame")
local MADE = { "README.md", "openspec/project.md", "openspec/specs/pong-party/spec.md", "plan/README.md", "plan/roadmap.md", "research/README.md" }
local all = true
for _, f in ipairs(MADE) do all = all and fs.exists(S.rel .. P .. "/" .. f) end
T:arm("3 an empty repo gains openspec/, plan/, research/ and README.md", c == 0 and all and text.contains(read(S.rel .. P .. "/README.md"), "Flame")
    and ("\n" .. o .. "\n"):find("\nok:scaffold:6\n", 1, true) ~= nil, tostring(c) .. " " .. o)

fs.mkdir(S.rel .. "/proj2"); fs.write(S.rel .. "/proj2/README.md", "mine\n")
scaffold("--dir", S.abs .. "/proj2", "--name", "A", "--summary", "B")
c, o = scaffold("--dir", S.abs .. "/proj2", "--name", "A", "--summary", "B")
T:arm("4 a second run creates nothing and an existing README.md is kept", read(S.rel .. "/proj2/README.md") == "mine\n" and ("\n" .. o .. "\n"):find("\nok:scaffold:0\n", 1, true) ~= nil, last(o))

fs.mkdir(S.rel .. "/proj3")
scaffold("--dir", S.abs .. "/proj3", "--name", "A", "--summary", "B", "--no-specs")
c, o = scaffold("--name", "A")
T:arm("5 --no-specs creates no openspec/, and a usage error exits 2", not fs.exists(S.rel .. "/proj3/openspec") and fs.exists(S.rel .. "/proj3/plan/roadmap.md") and c == 2, tostring(c) .. " " .. o)

-- Internal words an end user must never be shown.
local WORDS = { "plan_answer", "methodology", "cheatsheet", "@trace", "litmus", "centicolon", "tillandsias-plan", "git mirror" }
local function internal(s)
    s = s:lower()
    for _, w in ipairs(WORDS) do if s:find(w, 1, true) then return w end end
    if s:find("%f[%w_]mcp%f[^%w_]") then return "mcp" end
    return nil
end
local shown, n = {}, 0
local w = internal(skill); if w then shown[#shown + 1] = "SKILL.md:" .. w end
for _, f in ipairs(fs.walk(S.rel .. P)) do
    if not f:find("/.git/", 1, true) then
        n = n + 1
        local x = internal(fs.read(f)); if x then shown[#shown + 1] = f .. ":" .. x end
    end
end
T:arm("6 SKILL.md and the created files carry no internal vocabulary", skill ~= "" and n >= #MADE and #shown == 0
    and internal("ask the MCP server") == "mcp" and internal("the Litmus ran") == "litmus", "files=" .. n .. " " .. table.concat(shown, " "))
T:finish()
