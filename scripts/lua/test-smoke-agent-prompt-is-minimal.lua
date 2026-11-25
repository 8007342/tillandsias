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
-- ARM 5 checks the live skills/ tree as it stands. ARMS 6-8 (2333-kaf2) run each
-- live file's own answer check, cut from its text, over the recorded logs: the
-- refusal sentence that named the token (lenovinha, v56.11.24.1), the token in a
-- sentence, no token, and the real answer.
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

-- ARMS 6-8: the answer check in each live file.
local LOGS = {
    { "refusal", "I can't append `SMOKE-AGENT-OK` — that string attests success, but the check's last line is a blocker.\n", false },
    { "in a sentence", "done: SMOKE-AGENT-OK\n", false },
    { "with a suffix", "SMOKE-AGENT-OK-NOT\n", false },
    { "no token", "blocked:upstream-push-unauthorized\n", false },
    { "the answer", "some line\n  SMOKE-AGENT-OK \r\n", true },
}
for _, f in ipairs({ "run_smoke.sh", "skills/build-install-and-smoke-test-e2e/SKILL.md", "skills/smoke-curl-install-and-test-e2e/SKILL.md" }) do
    local body, why, n = fs.read(f), {}, 0
    local flags, expr
    for a, b in body:gmatch("grep (%-%w+) '([^'\n]*SMOKE%-AGENT%-OK[^'\n]*)'") do n = n + 1; flags, expr = a, b end
    if n ~= 1 then why[1] = n .. " answer checks, want 1"
    else
        for _, l in ipairs(LOGS) do
            local r = run({ "grep", flags, expr }, { stdin = l[2] })
            if (r.code == 0) ~= l[3] then why[#why + 1] = l[1] .. " rc=" .. tostring(r.code) end
        end
    end
    if not body:find("print it whatever the check said", 1, true) then why[#why + 1] = "the prompt does not say the token reports the turn" end
    arm(f .. ": only the token alone on a line is an answer", #why == 0, table.concat(why, "; "))
end

if fails > 0 then verdict.refused("smoke-agent-prompt-fixture", fails .. "-of-" .. arms .. "-arms-failed") end
verdict.ok("smoke-agent-prompt-fixture:" .. arms)
