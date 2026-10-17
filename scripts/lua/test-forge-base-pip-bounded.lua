-- @trace order:1771-4iw3
-- @env PATH
--
-- test-forge-base-pip-bounded.lua — the forge-base pip step cannot hold a
-- build hostage.
--
-- LIVE (operator on macuahuitl, 2026-10-17): `tillandsias --init` sat at
-- "Pulling image forge-base 40%" for 10-30 minutes inside
-- `pip3 install --timeout 120 ... pyright bandit`, pip idle in poll. MEASURED
-- on tlatoanis-macbook-air against an index that accepts and never answers:
-- `--timeout 5` with pip's default 5 retries took 43 s (6 attempts), so the
-- per-read timeout MULTIPLIES by the attempts per URL. Retries keep a stall
-- alive; only a wall-clock budget bounds it.
--
-- Every arm reads the step's text FROM Containerfile.base, so the fixture
-- cannot drift from what the image runs:
--   static: the step runs under `timeout "${PIP_STALL_BUDGET_S}"`, ARG gives a
--           default, and (retries+1) x per-read timeout fits inside it;
--   stall:  the extracted step, with a fake pip3 that never returns and a 3 s
--           budget, fails inside the budget plus slack with
--           refused:forge-base:pip-install-stalled and never reaches npm;
--   control (NEGATIVE): a fake pip3 that succeeds reaches npm, rc 0, no
--           refusal, so the wrapper does not fail a healthy install.
local NAME = "forge-base-pip-bounded"
local CF = "images/default/Containerfile.base"

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer")
end

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name .. (got and (" — " .. got) or "")) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

local src = fs.read(CF)
if not src then verdict.could_not_run(NAME, CF .. " is unreadable") end

-- The RUN instruction that installs with pip3, joined across `\` lines. Each
-- RUN block is collected whole, then the one that runs pip3 install is kept.
local step, current = {}, nil
for _, line in ipairs(text.lines(src)) do
    if not current and line:match("^RUN ") then current = {} end
    if current then
        local body = line:gsub("^RUN ", "", 1)
        local cont = body:match("\\%s*$") ~= nil
        current[#current + 1] = (body:gsub("\\%s*$", ""))
        if not cont then
            if table.concat(current, " "):find("pip3 install", 1, true) then
                step = current
                break
            end
            current = nil
        end
    end
end
if #step == 0 then verdict.could_not_run(NAME, CF .. " has no RUN step that runs pip3 install") end
-- The builder removes each `\`-newline, so the lines join on a space.
local STEP = table.concat(step, " ")

-- ── static: a budget exists and the retries fit inside it ───────────────────
local default_budget = tonumber(src:match("\nARG PIP_STALL_BUDGET_S=(%d+)"))
local pip_cmd = STEP:match("pip3 install[^;|&]*") or ""
local per_read = tonumber(pip_cmd:match("%-%-timeout (%d+)"))
local retries = tonumber(pip_cmd:match("%-%-retries (%d+)"))
local wrapped = STEP:find('timeout "${PIP_STALL_BUDGET_S}" pip3 install', 1, true) ~= nil
local wrap_note = nil
if not wrapped then wrap_note = "no wall-clock budget on the step" end
arm("static: the pip step runs under timeout \"${PIP_STALL_BUDGET_S}\"", wrapped, wrap_note)
arm("static: ARG PIP_STALL_BUDGET_S has a default", default_budget ~= nil, default_budget)
arm("static: --timeout and --retries are explicit", per_read ~= nil and retries ~= nil,
    "timeout=" .. tostring(per_read) .. " retries=" .. tostring(retries))
if default_budget and per_read and retries then
    local worst = (retries + 1) * per_read
    arm("static: (retries+1) x per-read timeout fits the budget", worst <= default_budget,
        worst .. " s per stalled URL vs a " .. default_budget .. " s budget")
end

-- ── the step itself, under fakes ─────────────────────────────────────────────
-- The runtime refuses `sh -c` (policy); the step runs as `sh <file>`.
local probe = proc.run({ argv = { "timeout", "--version" },
    env = { PATH = env.get("PATH") or "/usr/bin:/bin" }, timeout_ms = 5000 })
if probe.status ~= "exited" or probe.code ~= 0 then
    verdict.could_not_run(NAME, "no `timeout` on PATH (coreutils); the image has it, this host does not")
end

local REL = "target/plan-scratch/pip-bounded-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
local ABS = ROOT .. "/" .. REL
local function fakes(dir, pip_body)
    fs.mkdir(REL .. "/" .. dir)
    fs.write(REL .. "/" .. dir .. "/pip3", "#!/bin/sh\n" .. pip_body .. "\n")
    fs.write(REL .. "/" .. dir .. "/npm", "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"" .. ABS .. "/" .. dir .. "/npm.log\"\n")
    proc.run({ argv = { "chmod", "755", ABS .. "/" .. dir .. "/pip3", ABS .. "/" .. dir .. "/npm" }, timeout_ms = 5000 })
    return ABS .. "/" .. dir
end
local function run_step(bin, budget)
    fs.write(REL .. "/step.sh", STEP .. "\n")
    local t0 = time.now_ms()
    local r = proc.run({ argv = { "sh", ABS .. "/step.sh" },
        env = { PATH = bin .. ":" .. (env.get("PATH") or "/usr/bin:/bin"), PIP_STALL_BUDGET_S = budget },
        timeout_ms = 60000 })
    return r, (time.now_ms() - t0) / 1000
end

if wrapped then
    -- stall: pip that never returns (a held-open index read).
    local bin = fakes("stall", "exec sleep 600")
    local r, secs = run_step(bin, "3")
    local o = (r.stdout or "") .. (r.stderr or "")
    arm("stall: the step fails", r.status == "exited" and r.code ~= 0, r.status .. ":" .. tostring(r.code))
    arm("stall: inside the 3 s budget plus 15 s slack", secs <= 18, string.format("%.1f s", secs))
    arm("stall: names the verdict refused:forge-base:pip-install-stalled",
        o:find("refused:forge-base:pip-install-stalled", 1, true) ~= nil, o:sub(1, 200))
    arm("stall: says why and remedy", o:find("why:", 1, true) ~= nil and o:find("remedy:", 1, true) ~= nil)
    arm("stall: never reaches npm", not fs.exists(REL .. "/stall/npm.log"))

    -- control: a healthy pip.
    bin = fakes("ok", "exit 0")
    r, secs = run_step(bin, "3")
    o = (r.stdout or "") .. (r.stderr or "")
    arm("control: a healthy pip passes", r.status == "exited" and r.code == 0, r.status .. ":" .. tostring(r.code))
    arm("control: npm runs after it", fs.exists(REL .. "/ok/npm.log"))
    arm("control: no refusal printed", o:find("refused:", 1, true) == nil, o:sub(1, 200))
end

if #failed > 0 then
    verdict.emit("violation:" .. NAME .. ":" .. #failed .. "-failed", 1)
end
verdict.ok(NAME, "static + stall + control arms")
