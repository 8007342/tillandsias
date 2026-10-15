-- @trace order:1743-h9rz, order:1446-qkx4, order:1517-p83m
--
-- test-forge-agents-discover-generic-skills.lua — every agent a forge can run
-- FINDS the generic skills (start-a-new-project, project-discipline) where that
-- agent documents it looks, not merely where we put them.
--
-- THE DEFECT (1743-h9rz). The v56.10.15.1 Windows smoke: /opt/skills/
-- start-a-new-project shipped, and the OpenCode agent said it was not among
-- its skills. Two causes, both on every platform:
--   (a) entrypoint-forge-opencode.sh still sourced the profile from
--       /opt/config-overlay, a path the image never installs. 1517-p83m moved
--       the other four entrypoints to load_agent_profile; its fixture named
--       those four in a list, so the fifth was invisible to it;
--   (b) the profile linked OpenCode's copy into ~/.config/opencode/skill, and
--       OpenCode searches ~/.config/opencode/skills (plural).
--
-- So this fixture enumerates entrypoints by LISTING the directory, and checks
-- skills against each agent's DOCUMENTED search path, so neither a new lane
-- nor a wrong directory name can pass by omission.
--
--   1 every images/default/entrypoint-forge-*.sh calls load_agent_profile and
--     none names /opt/config-overlay
--   2 the image's profile, run against an image-shaped HOME, makes every
--     generic skill resolvable at every agent's documented global skill dir
--   3 every generic skill's frontmatter meets OpenCode's discovery rules:
--     name matches its directory and ^[a-z0-9]+(-[a-z0-9]+)*$, description
--     1-1024 characters
--   4 NEGATIVE CONTROL: the pre-fix profile (singular skill/) fails arm 2 for
--     OpenCode, so arm 2 can tell the two apart
--
-- Documented global skill directories (the agent's own docs):
--   OpenCode — https://opencode.ai/docs/skills: ~/.config/opencode/skills/<name>/SKILL.md
--     (also ~/.claude/skills and ~/.agents/skills; checked at its OWN dir so a
--     regression there is not hidden by the Claude-compatible fallback)
--   Claude Code — ~/.claude/skills/<name>/SKILL.md
--   Codex — ~/.codex/skills/<name>/SKILL.md
--   Antigravity — ~/.gemini/skills/<name>/SKILL.md
--
-- Usage: tillandsias-plan script run scripts/lua/test-forge-agents-discover-generic-skills.lua

local IMG = "images/default"
local PROFILE = IMG .. "/config-overlay/mcp/agent-profile.sh"
local AGENT_DIRS = {
    { "opencode", ".config/opencode/skills" },
    { "claude", ".claude/skills" },
    { "codex", ".codex/skills" },
    { "antigravity", ".gemini/skills" },
}

local passed, failed = 0, 0
local function check(name, cond, why)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else failed = failed + 1; out.line("FAIL: " .. name .. " — " .. why) end
end

local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 }).stdout or "")
if ROOT == "" or not fs.exists(PROFILE) then
    verdict.emit("could-not-run:forge-agents-discover-generic-skills:no-checkout", 1)
end

-- ── ARM 1: every entrypoint, found by listing ──────────────────────────────
local entrypoints, missing = {}, {}
for _, f in ipairs(fs.list(ROOT .. "/" .. IMG) or {}) do
    local base = f:match("([^/]+)$") or f
    if text.is_match(base, [[^entrypoint-forge-.*\.sh$]]) then
        entrypoints[#entrypoints + 1] = base
        local src = fs.read(IMG .. "/" .. base)
        local loads = false
        for _, l in ipairs(text.lines(src)) do
            if text.is_match(l, [=[^load_agent_profile([[:space:]]|$)]=]) then loads = true end
        end
        if not loads or text.contains(src, "/opt/config-overlay") then
            missing[#missing + 1] = base
        end
    end
end
check("1 all " .. #entrypoints .. " forge entrypoints (by listing) call load_agent_profile",
    #entrypoints >= 5 and #missing == 0,
    "found " .. #entrypoints .. "; not loading the profile from where the image installs it: " .. table.concat(missing, " "))

-- The generic skill list, from the profile's own default.
local prof = fs.read(PROFILE)
local list = prof:match('TILLANDSIAS_FORGE_GENERIC_SKILLS:%-([^}"]+)')
local skills = {}
for s in (list or ""):gmatch("%S+") do skills[#skills + 1] = s end
if #skills == 0 then verdict.emit("refused:forge-agents-discover-generic-skills:no-generic-skill-list", 1) end

-- ── image-shaped HOME, the profile run the way load_agent_profile runs it ──
local REL = "target/plan-scratch/agent-skills-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL

-- run_profile(tag, profile_text) -> HOME rel path after sourcing it
local function run_profile(tag, profile_text)
    local home = REL .. "/" .. tag .. "/home"
    fs.mkdir(home .. "/.config-overlay/mcp")
    fs.write(home .. "/.config-overlay/mcp/agent-profile.sh", profile_text)
    for _, s in ipairs(skills) do
        fs.mkdir(REL .. "/" .. tag .. "/opt-skills/" .. s)
        fs.write(REL .. "/" .. tag .. "/opt-skills/" .. s .. "/SKILL.md", fs.read("skills/" .. s .. "/SKILL.md"))
    end
    fs.write(REL .. "/" .. tag .. "/run.sh", table.concat({
        "set -e",
        'source "$HOME/.config-overlay/mcp/agent-profile.sh" >/dev/null 2>&1 || true',
    }, "\n") .. "\n")
    proc.run({ argv = { "bash", W .. "/" .. tag .. "/run.sh" }, timeout_ms = 30000, env = {
        PATH = "/usr/bin:/bin",
        HOME = ROOT .. "/" .. home,
        TILLANDSIAS_SHARED_SKILLS_ROOT = W .. "/" .. tag .. "/opt-skills",
    } })
    return home
end

-- unreachable(home) -> list of "agent:skill" not resolvable at the agent's dir
local function unreachable(home)
    local miss = {}
    for _, a in ipairs(AGENT_DIRS) do
        for _, s in ipairs(skills) do
            if not fs.exists(home .. "/" .. a[2] .. "/" .. s .. "/SKILL.md") then
                miss[#miss + 1] = a[1] .. ":" .. s
            end
        end
    end
    return miss
end

-- ── ARM 2: discovery at every documented dir ───────────────────────────────
local miss = unreachable(run_profile("fixed", prof))
check("2 every generic skill (" .. table.concat(skills, ", ") .. ") resolves at every agent's documented skill dir",
    #miss == 0, "unreachable: " .. table.concat(miss, " "))

-- ── ARM 3: OpenCode's frontmatter rules ────────────────────────────────────
local bad = {}
for _, s in ipairs(skills) do
    local body = fs.read("skills/" .. s .. "/SKILL.md")
    local fm = body:match("^%-%-%-\n(.-)\n%-%-%-")
    local name = fm and fm:match("\nname:%s*([^\n]+)") or (fm and fm:match("^name:%s*([^\n]+)"))
    local desc = fm and fm:match("\ndescription:%s*([^\n]+)")
    name = name and text.trim(name)
    if not fm then bad[#bad + 1] = s .. ":no-frontmatter"
    elseif name ~= s or not text.is_match(name, "^[a-z0-9]+(-[a-z0-9]+)*$") then bad[#bad + 1] = s .. ":name=" .. tostring(name)
    elseif not desc or #desc < 1 or #desc > 1024 then bad[#bad + 1] = s .. ":description-length=" .. tostring(desc and #desc) end
end
check("3 every generic skill's frontmatter meets OpenCode's discovery rules", #bad == 0, table.concat(bad, " "))

-- ── ARM 4: negative control — the pre-fix singular directory ───────────────
local prefix = prof:gsub("%.config/opencode/skills\"", ".config/opencode/skill\"")
local miss4 = unreachable(run_profile("prefix", prefix))
local oc_missing = 0
for _, m in ipairs(miss4) do if m:match("^opencode:") then oc_missing = oc_missing + 1 end end
check("4 negative control: the pre-fix profile (skill/, singular) leaves OpenCode without the skills",
    prefix ~= prof and oc_missing == #skills, "prefix-differs=" .. tostring(prefix ~= prof) .. " opencode-missing=" .. oc_missing)

proc.run({ argv = { "rm", "-rf", W }, timeout_ms = 30000 })
if failed > 0 then
    verdict.emit("refused:forge-agents-discover-generic-skills:" .. failed .. "-of-" .. (passed + failed), 1)
end
verdict.emit("ok:forge-agents-discover-generic-skills:" .. passed, 0)
