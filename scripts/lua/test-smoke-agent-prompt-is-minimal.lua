-- @trace order:1941-smkp
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-smoke-agent-prompt-is-minimal.lua — the smoke-prompt check refuses a
-- smoke skill that hands its forge agent the /meta-orchestration loop, and
-- passes the fixed one-turn prompt. A scratch skills tree holds:
--   ARM 1  a smoke skill launching `--prompt "Use the /meta-orchestration skill"`  -> refused, by line
--   ARM 2  a smoke skill with the fixed one-turn prompt                           -> ok
--   ARM 3  a NON-smoke skill launching the loop (meta-orchestration's own home)   -> not judged
--   ARM 4  no smoke skill at all                                                  -> could-not-run, never ok
-- and ARM 5 checks the live skills/ tree as it stands.
--
-- Usage: tillandsias-plan script run scripts/lua/test-smoke-agent-prompt-is-minimal.lua [-- --plan <bin>]

local CHECK_REL = "scripts/lua/check-smoke-agent-prompt-is-minimal.lua"
local PLAN
for i = 1, #arg do if arg[i] == "--plan" then PLAN = arg[i + 1] end end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then PLAN = "tillandsias-plan" end

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 60000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
if ROOT == "" then verdict.could_not_run("smoke-agent-prompt-fixture", "not inside a git checkout") end
local REL = "target/plan-scratch/smoke-agent-prompt-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))

local LOOP = 'env TILLANDSIAS_NO_TRAY=1 tillandsias --cloud o/r --opencode --prompt "Use the /meta-orchestration skill" 2>&1 \\\n'
local FIXED = "SMOKE_PROMPT='Smoke check, one turn only. Reply with the word SMOKE-AGENT, a hyphen and OK.'\n"
    .. 'env TILLANDSIAS_NO_TRAY=1 tillandsias --cloud o/r --opencode --prompt "$SMOKE_PROMPT" 2>&1\n'

local function tree(name, files)
    local dir = REL .. "/" .. name
    for skill, body in pairs(files) do
        fs.mkdir(dir .. "/" .. skill)
        fs.write(dir .. "/" .. skill .. "/SKILL.md", "---\nname: " .. skill .. "\n---\n# " .. skill .. "\n\n" .. body)
    end
    return dir
end

local function check(dir)
    local r = run({ PLAN, "script", "run", ROOT .. "/" .. CHECK_REL }, { cwd = ROOT, env = { TILLANDSIAS_SKILLS_ROOT = dir } })
    return r.code, (r.stdout or "") .. (r.stderr or "")
end

local fails, arms = 0, 0
local function arm(label, ok, detail)
    arms = arms + 1
    if ok then print("PASS arm " .. arms .. ": " .. label)
    else fails = fails + 1; print("FAIL arm " .. arms .. ": " .. label .. " — " .. (detail or "")) end
end

-- ARM 1: the loop in a smoke skill is refused, and the refusal names the line.
local d1 = tree("a1", { ["smoke-x"] = "```bash\n" .. LOOP .. "```\n" })
local c1, o1 = check(d1)
arm("a smoke skill launching /meta-orchestration is refused by line", c1 == 1
    and o1:find("refused-prompt:smoke-x:7", 1, true) ~= nil
    and o1:find("refused:smoke-agent-prompt:refused=1:skills=1", 1, true) ~= nil, "code=" .. tostring(c1) .. " " .. o1)

-- ARM 2: the fixed one-turn prompt passes.
local d2 = tree("a2", { ["smoke-x"] = "```bash\n" .. FIXED .. "```\n" })
local c2, o2 = check(d2)
arm("the fixed one-turn smoke prompt passes", c2 == 0
    and o2:find("ok:smoke-agent-prompt:skills=1", 1, true) ~= nil, "code=" .. tostring(c2) .. " " .. o2)

-- ARM 3: a non-smoke skill may launch the loop; only smoke skills are judged.
local d3 = tree("a3", { ["smoke-x"] = "```bash\n" .. FIXED .. "```\n", ["meta-orchestration"] = "```bash\n" .. LOOP .. "```\n" })
local c3, o3 = check(d3)
arm("a non-smoke skill is not judged", c3 == 0
    and o3:find("ok:smoke-agent-prompt:skills=1", 1, true) ~= nil, "code=" .. tostring(c3) .. " " .. o3)

-- ARM 4: an empty population is could-not-run, never a pass.
local d4 = tree("a4", { ["plain-skill"] = "nothing here\n" })
local c4, o4 = check(d4)
arm("no smoke skill reads could-not-run, not ok", c4 == 3
    and o4:find("could-not-run:smoke-agent-prompt:no-smoke-skills", 1, true) ~= nil, "code=" .. tostring(c4) .. " " .. o4)

-- ARM 5: the live tree.
local c5, o5 = check(ROOT .. "/skills")
arm("the live skills/ tree passes", c5 == 0 and o5:find("ok:smoke-agent-prompt:skills=", 1, true) ~= nil, "code=" .. tostring(c5) .. " " .. o5)

if fails > 0 then verdict.refused("smoke-agent-prompt-fixture", fails .. "-of-" .. arms .. "-arms-failed") end
verdict.ok("smoke-agent-prompt-fixture:" .. arms)
