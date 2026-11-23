-- @trace order:1446-qkx4, spec:branch-discipline, order:2245-pf7x
--
-- Fixture for skills/project-discipline (order 1446-qkx4), the skill every
-- discipline refusal names ("use /project-discipline for instructions").
-- Ported whole from scripts/test-project-discipline-skill.sh (2245-pf7x); the
-- arms and their assertions are unchanged.
--
--   1. the skill exists, is registered in methodology.yaml shared_skills, and
--      scripts/check-skills-single-source.sh stays green;
--   2. its FIRST command block runs `tillandsias-plan discipline show` and
--      `discipline derive`, and its ladder names the operator's three rungs;
--   3. every hook-template refusal family of 1446-xqi6 has a section whose
--      heading is that family (`hook:<event>`), seven in all;
--   4. the forge wiring: sourcing images/default/config-overlay/mcp/
--      agent-profile.sh (as every forge entrypoint does, under set -euo
--      pipefail) links the skill into each harness's USER skill directory for
--      a project with no scripts/ at all, is idempotent, and never overwrites
--      an entry that is already there.
--
-- Verdict: ok:project-discipline-skill:<pass>/<total> | fail:project-discipline-skill:<pass>/<total>

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local SKILL = "skills/project-discipline/SKILL.md"
local PROFILE = root .. "/images/default/config-overlay/mcp/agent-profile.sh"
local pass, total = 0, 4
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) out.line("FAIL: " .. m) end

local rel = "target/plan-scratch/project-discipline-skill-" .. tostring(time.now_ms())
local W = root .. "/" .. rel
proc.run{ argv = { "mkdir", "-p", W } }
local function cleanup() proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 } end

local skill = fs.exists(SKILL) and fs.read(SKILL) or ""
local skill_lines = text.lines(skill)

-- 1 — exists, registered, single-sourced.
local reg, s, f = false, false, false
for _, l in ipairs(text.lines(fs.read("methodology.yaml"))) do
    if l == "  shared_skills:" then s = true end
    if s and l == "      project-discipline:" then f = true end
    if f and l:find("path: skills/project-discipline/SKILL.md", 1, true) then reg = true; break end
end
local sr = proc.run{ argv = { "bash", root .. "/scripts/check-skills-single-source.sh" }, cwd = root, timeout_ms = 120000 }
local single = text.trim(sr.stdout or "")
local single_rc = sr.status == "exited" and sr.code or -1
if fs.exists(SKILL) and reg and single_rc == 0 and text.starts_with(single, "ok:skills-single-source") then
    ok("arm 1: skill exists, registered in methodology.yaml shared_skills, " .. single)
else
    bad("arm 1: file=" .. (fs.exists(SKILL) and "yes" or "no") .. " registered=" .. (reg and "yes" or "no")
        .. " single-source rc=" .. single_rc .. " [" .. single .. "]")
end

-- 2 — the first command block asks the project; the ladder names three rungs.
local n, block = 0, {}
for _, l in ipairs(skill_lines) do
    if text.starts_with(l, "```") then
        n = n + 1
        if n >= 2 then break end
    elseif n == 1 then block[#block + 1] = l end
end
local first_block = table.concat(block, "\n")
local function line_matches(re) for _, l in ipairs(skill_lines) do if text.is_match(l, re) then return true end end return false end
local arm2 = first_block:find("tillandsias-plan discipline show", 1, true) ~= nil
    and first_block:find("tillandsias-plan discipline derive", 1, true) ~= nil
    and line_matches([[^\| \*\*0\*\* \|.*Push to main freely]])
    and line_matches([[^\| \*\*1\*\* \|.*integration branch and pull requests]])
    and line_matches([[^\| \*\*2\*\* \|.*Work refs into the integration branch]])
if arm2 then ok("arm 2: first command block runs discipline show + derive; ladder names levels 0, 1, 2")
else bad("arm 2: first block=[" .. first_block .. "]") end

-- 3 — one section per hook-template refusal family (1446-xqi6's seven events).
local have = {}
for _, l in ipairs(skill_lines) do have[l] = true end
local missing = {}
for _, ev in ipairs({ "pre-commit", "post-commit", "pre-push", "post-merge", "post-checkout", "pre-receive", "post-receive" }) do
    if not have["### `hook:" .. ev .. "`"] then missing[#missing + 1] = ev end
end
if #missing == 0 then ok("arm 3: all seven hook refusal families have a section (hook:<event>)")
else bad("arm 3: no section for: " .. table.concat(missing, " ")) end

-- 4 — the forge links it for any project, idempotently, without clobbering.
local H, P = W .. "/home", W .. "/some-project"
proc.run{ argv = { "mkdir", "-p", H .. "/.codex/skills/project-discipline", P } } -- a user-owned entry
fs.write(rel .. "/home/.codex/skills/project-discipline/SKILL.md", "")
local src = proc.run{ argv = { "bash", "-s" }, cwd = P, timeout_ms = 120000,
    stdin = 'set -euo pipefail; source "$PROFILE"; source "$PROFILE"; echo sourced\n',
    env = { HOME = H, PROFILE = PROFILE, TILLANDSIAS_SHARED_SKILLS_ROOT = root .. "/skills", TILLANDSIAS_AGENT = "claude" } }
local src_out = (src.stdout or "") .. (src.stderr or "")
local src_rc = src.status == "exited" and src.code or -1
local src_lines = text.lines(text.trim(src.stdout or ""))
local detail = {}
if not (src_rc == 0 and src_lines[#src_lines] == "sourced") then detail[#detail + 1] = "source rc=" .. src_rc .. " [" .. src_out .. "]" end
local function is_link(p) return proc.run{ argv = { "test", "-L", p } }.code == 0 end
for _, d in ipairs({ ".claude/skills", ".gemini/skills", ".config/opencode/skills" }) do
    local p = H .. "/" .. d .. "/project-discipline"
    if not (is_link(p) and proc.run{ argv = { "test", "-f", p .. "/SKILL.md" } }.code == 0) then detail[#detail + 1] = "missing:" .. d end
end
if is_link(H .. "/.codex/skills/project-discipline") then detail[#detail + 1] = "clobbered:.codex" end
if proc.run{ argv = { "test", "-e", P .. "/scripts" } }.code == 0 then detail[#detail + 1] = "project-has-scripts" end
if #detail == 0 then
    ok("arm 4: sourcing agent-profile.sh (twice, set -euo pipefail) links the skill for a project with no scripts/, and leaves a user-owned entry alone")
else bad("arm 4: " .. table.concat(detail, " ")) end

cleanup()
if pass == total then verdict.ok("project-discipline-skill:" .. pass .. "/" .. total) end
verdict.emit("fail:project-discipline-skill:" .. pass .. "/" .. total, 1)
