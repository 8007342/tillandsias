-- @trace order:2031-z4rm, spec:command-runtime
-- @env PATH TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-env-namespace-hygiene.lua — the arms of 2031-z4rm's guard,
-- scripts/lua/check-env-namespace-hygiene.lua:
--   1 REAL      this checkout passes (every credential-shaped TILLANDSIAS_ name
--               is a listed secret or a retired spelling)
--   2 PLANTED   a scratch tree carrying TILLANDSIAS_NEW_API_TOKEN is refused,
--               and the refusal names the variable and its file (the mutation
--               arm: a new name spelled like a credential cannot land quietly)
--   3 LOCATOR   a scratch tree carrying TILLANDSIAS_NEW_TOKEN_FILE passes: a
--               name that says WHERE a credential is, is not one
--   4 EMPTY     a scratch tree with no code is could-not-run, exit 3
-- Only variable NAMES appear here; no value is ever set or printed.
--
-- Usage: tillandsias-plan script run scripts/lua/test-env-namespace-hygiene.lua

local SUBJECT = "scripts/lua/check-env-namespace-hygiene.lua"
if not fs.exists(SUBJECT) then
    verdict.emit("violation:env-namespace-hygiene-fixture:no-subject", 1, SUBJECT .. " does not exist (2031-z4rm)")
end
local PLAN = env.get("TILLANDSIAS_PLAN_BIN")
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("env-namespace-hygiene-fixture", "no plan binary named (TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("env-namespace-hygiene-fixture", "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/env-namespace-hygiene-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end
local function run(scan_root)
    local r = proc.run({ argv = { PLAN, "script", "run", SUBJECT }, cwd = ROOT, timeout_ms = 120000,
        env = scan_root and { TILLANDSIAS_ENV_HYGIENE_SCAN_ROOT = scan_root } or nil })
    return r.code or -1, text.trim(r.stdout or "")
end
local function tree(name, body)
    local d = REL .. "/" .. name
    fs.mkdir(d .. "/scripts")
    if body then fs.write(d .. "/scripts/probe.sh", body) end
    return d
end

local rc, o = run(nil)
arm("1 REAL this checkout's namespace passes", rc == 0 and o:find("ok:env-namespace-hygiene:", 1, true) ~= nil, rc .. " " .. o)

local d = tree("planted", 'export TILLANDSIAS_NEW_API_TOKEN\necho "${TILLANDSIAS_HOST_KIND:-}"\n')
rc, o = run(d)
arm("2 PLANTED a new credential-shaped name is refused, naming the variable and its file",
    rc == 1 and o:find("violation:env-namespace:credential-shape:TILLANDSIAS_NEW_API_TOKEN:scripts/probe.sh", 1, true) ~= nil, rc .. " " .. o)

d = tree("locator", 'export TILLANDSIAS_NEW_TOKEN_FILE\n')
rc, o = run(d)
arm("3 LOCATOR a name that locates a credential passes", rc == 0 and o:find("ok:env-namespace-hygiene:names=1:", 1, true) ~= nil, rc .. " " .. o)

d = tree("empty", nil)
rc, o = run(d)
arm("4 EMPTY no code is could-not-run", rc == 3 and o:find("could-not-run:env-namespace-hygiene:empty-population", 1, true) ~= nil, rc .. " " .. o)

if #failed > 0 then
    verdict.emit("violation:env-namespace-hygiene-fixture:" .. #failed .. "-failed", 1)
end
verdict.ok("env-namespace-hygiene", 4)
