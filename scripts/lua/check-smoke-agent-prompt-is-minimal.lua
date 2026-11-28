-- @trace order:1941-smkp
-- @env TILLANDSIAS_SKILLS_ROOT
--
-- check-smoke-agent-prompt-is-minimal.lua — refuse a smoke skill whose forge
-- lane hands the agent the /meta-orchestration loop. A smoke proves the agent
-- answers and can call a tool; a full autonomous loop is 100+ model requests
-- on the free hosted tier every fleet host shares, and on 2026-11-01 that is
-- what ended in a 429 with Retry-After 78443 (1941-tlsh). Offline: it reads
-- skills/*/SKILL.md for every skill whose directory name contains "smoke".
--
-- One line per refused prompt on stdout:
--   refused-prompt:<skill>:<line>
--
-- Verdicts:
--   ok:smoke-agent-prompt:skills=<n>                    exit 0
--   refused:smoke-agent-prompt:refused=<k>:skills=<n>   exit 1
--   could-not-run:smoke-agent-prompt:<why>              exit 3

local ROOT = env.get("TILLANDSIAS_SKILLS_ROOT") or ""
if ROOT == "" then ROOT = "skills" end

local function afford(why, remedy)
    io.stderr:write("  why: " .. why .. "\n  remedy: " .. remedy .. "\n")
end

local entries = fs.walk(ROOT)
if not entries then
    afford("the skills directory " .. ROOT .. " could not be walked", "run from the checkout root or set TILLANDSIAS_SKILLS_ROOT")
    verdict.emit("could-not-run:smoke-agent-prompt:no-skills-dir", 3)
end

local smoke = {}
for _, path in ipairs(entries) do
    local name = path:match("([^/]+)/SKILL%.md$")
    if name and name:find("smoke", 1, true) then smoke[#smoke + 1] = path end
end
local SRC = require("common.listed_read").read_all("smoke-agent-prompt", smoke)
local skills, refused = 0, 0
for _, path in ipairs(smoke) do
    local name = path:match("([^/]+)/SKILL%.md$")
    do
        local body = SRC[path]
        if body then
            skills = skills + 1
            local n = 0
            for line in (body .. "\n"):gmatch("(.-)\n") do
                n = n + 1
                -- A prompt argument naming the loop, quoted on the same line.
                if line:match("%-%-prompt%s+[\"'][^\"']*/?meta%-orchestration") then
                    refused = refused + 1
                    print("refused-prompt:" .. name .. ":" .. n)
                end
            end
        end
    end
end

if skills == 0 then
    afford("no smoke skill was found under " .. ROOT .. ", so nothing was checked", "point TILLANDSIAS_SKILLS_ROOT at the skills directory")
    verdict.emit("could-not-run:smoke-agent-prompt:no-smoke-skills", 3)
end
if refused > 0 then
    afford("a smoke spends one short agent turn, not the /meta-orchestration loop on a shared hosted model (1941-smkp)",
        "replace each refused prompt with the fixed smoke prompt: run one tool, then reply with a fixed token")
    verdict.emit("refused:smoke-agent-prompt:refused=" .. refused .. ":skills=" .. skills, 1)
end
verdict.emit("ok:smoke-agent-prompt:skills=" .. skills, 0)
