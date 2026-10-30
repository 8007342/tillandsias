-- @trace order:1924-dcoy, order:1384-bqhy
-- @env TILLANDSIAS_HOST_KIND TILLANDSIAS_SKIP_TOOLBOX container HOME PATH TMPDIR CARGO_TARGET_DIR
--
-- test-gate-step-pipe-holder.lua — the gate step runner refuses a step that
-- leaves a background job holding its stdout pipe, instead of waiting for it.
-- Four fixtures did (a `sleep 60 &` decoy, the sleep under a killed flock) and
-- cost ~248 s of waiting per gate for ~11 s of work.
--
-- Every arm EXECUTES the real loop through `./build.sh --gate-steps <root>`
-- over a scratch root with one stub step:
--   1 LEAK     the stub backgrounds `sleep 8` on its own stdout and prints ok:
--              the gate is red, says refused:gate-step:background-job-holds-pipe,
--              names the sleep, and returns well before the sleep would end
--   2 CLEAN    the same stub with </dev/null >/dev/null 2>&1 on the job: green
--              (NEGATIVE CONTROL — a background job is fine off the pipe)
--   3 PLAIN    no background job: green
--
-- Usage: tillandsias-plan script run scripts/lua/test-gate-step-pipe-holder.lua

-- build.sh asks these where it runs (forge, toolbox); proc.run scrubs them.
local BENV = {}
for _, k in ipairs({ "TILLANDSIAS_HOST_KIND", "TILLANDSIAS_SKIP_TOOLBOX", "container", "HOME", "PATH", "TMPDIR", "CARGO_TARGET_DIR" }) do
    local v = env.get(k)
    if v and v ~= "" then BENV[k] = v end
end
local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 120000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
if ROOT == "" then verdict.could_not_run("gate-step-pipe-holder", "not inside a git checkout") end
local u = text.trim(run({ "uname", "-s" }).stdout or "")
if u ~= "Linux" and u ~= "Darwin" then
    verdict.emit("skip:gate-step-pipe-holder:" .. u .. "-re-execs-build-sh-into-wsl", 0,
        "runs inside the builder distro's gate")
end

local REL = "target/plan-scratch/gate-pipe-holder-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL

local function root(name, body)
    local r = REL .. "/" .. name
    fs.mkdir(r .. "/scripts/gate-steps.d")
    fs.write(r .. "/scripts/stub.sh", "#!/usr/bin/env bash\n" .. body .. "echo ok:stub-pipe:" .. name .. "\n")
    fs.write(r .. "/scripts/gate-steps.d/500-stub.step",
        'STEP_DESC="Stub pipe-holder step (1924-dcoy fixture)"\n' ..
        'STEP_SCRIPT="scripts/stub.sh"\n' ..
        'STEP_ERROR="stub pipe-holder step failed"\n' ..
        'STEP_OK="Stub pipe-holder step passed"\n')
    local t0 = time.now_ms()
    local res = run({ "bash", ROOT .. "/build.sh", "--gate-steps", W .. "/" .. name }, { env = BENV, stdin = "", timeout_ms = 60000 })
    return res, time.now_ms() - t0, (res.stdout or "") .. (res.stderr or "")
end

local passed, failed = 0, 0
local function check(name, cond, why)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else failed = failed + 1; out.line("FAIL: " .. name .. " — " .. why) end
end
local function green(res) return res.status == "exited" and res.code == 0 end

local res, ms, o = root("leak", "sleep 8 &\n")
check("1 LEAK a job left on the step's stdout is refused, named, and not waited for",
    not green(res) and o:find("refused:gate-step:background-job-holds-pipe", 1, true)
        and o:find("sleep 8", 1, true) and ms < 7000,
    "code=" .. tostring(res.code) .. " ms=" .. ms .. "\n" .. o)

res, ms, o = root("clean", "sleep 8 </dev/null >/dev/null 2>&1 &\n")
check("2 CLEAN a job off the pipe does not refuse (negative control)",
    green(res) and not o:find("background-job-holds-pipe", 1, true) and ms < 7000,
    "code=" .. tostring(res.code) .. " ms=" .. ms .. "\n" .. o)

res, ms, o = root("plain", "")
check("3 PLAIN a step with no background job is green",
    green(res) and not o:find("background-job-holds-pipe", 1, true),
    "code=" .. tostring(res.code) .. "\n" .. o)

run({ "rm", "-rf", W })
if failed == 0 then
    verdict.emit("ok:gate-step-pipe-holder:" .. passed .. "/" .. passed, 0)
end
verdict.emit("refused:gate-step-pipe-holder:" .. failed .. "-failed", 1)
