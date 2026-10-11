-- @trace order:941-trcf, order:1577-568c, spec:methodology-accountability
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-fragment-backlog.lua — scripts/lua/check-fragment-backlog.lua on a
-- CONSTRUCTED plan/index.d in a scratch root (TILLANDSIAS_REPO_ROOT). The
-- shell original had no fixture; the port carries one.
--   1 NONE   no plan/index.d at all is an empty backlog: ok:fragment-backlog:0<=50.
--   2 UNDER  three top-level *.yaml at threshold 3 is ok:fragment-backlog:3<=3;
--            a nested .yaml and a README.md are NOT counted (the shell glob was
--            top-level *.yaml, and fs.walk is recursive).
--   3 OVER   the same tree at threshold 2 is the advisory line, exit 0, ending
--            ` (advisory)` — an `advisory:` decider ports through
--            verdict.advisory with its line otherwise unchanged.
--
-- PRE-PORT CODE FAILS IT: with no check-fragment-backlog.lua the fixture
-- refuses, never a skip.
--
-- Usage: tillandsias-plan script run scripts/lua/test-fragment-backlog.lua [-- --plan <bin>]

local SUBJECT_REL = "scripts/lua/check-fragment-backlog.lua"
if not fs.exists(SUBJECT_REL) then
    verdict.emit("violation:fragment-backlog-fixture:no-subject", 1,
        "scripts/lua/check-fragment-backlog.lua does not exist (941-trcf port, 1577-568c)")
end

local PLAN
for i = 1, #arg do if arg[i] == "--plan" then PLAN = arg[i + 1] end end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("fragment-backlog-fixture", "no plan binary named (--plan, TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
local SUBJECT = ROOT .. "/" .. SUBJECT_REL

-- Scratch roots under target/plan-scratch, never /tmp or the checkout proper.
local REL = "target/plan-scratch/fragment-backlog-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL .. "/none")
fs.mkdir(REL .. "/some/plan/index.d/nested")
for _, f in ipairs({ "a.yaml", "b.yaml", "c.yaml", "README.md", "nested/d.yaml" }) do
    fs.write(REL .. "/some/plan/index.d/" .. f, "packets: []\n")
end

local function subject(root, threshold)
    local env_t = { TILLANDSIAS_REPO_ROOT = ROOT .. "/" .. REL .. "/" .. root }
    if threshold then env_t.TILLANDSIAS_FRAGMENT_BACKLOG_THRESHOLD = threshold end
    local r = proc.run({ argv = { PLAN, "script", "run", SUBJECT }, cwd = ROOT, env = env_t, timeout_ms = 60000 })
    return (r.status == "exited" and r.code or -1), text.trim(r.stdout or "")
end

local failed = {}
local function arm(name, cond, got)
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. got)
        failed[#failed + 1] = name
    end
end

local rc, o = subject("none", nil)
arm("1 NONE: no plan/index.d is ok:fragment-backlog:0<=50", rc == 0 and o == "ok:fragment-backlog:0<=50", rc .. " " .. o)
rc, o = subject("some", "3")
arm("2 UNDER: three top-level yaml at threshold 3; nested and README not counted", rc == 0 and o == "ok:fragment-backlog:3<=3", rc .. " " .. o)
rc, o = subject("some", "2")
arm("3 OVER: advisory line, exit 0, ends ' (advisory)'",
    rc == 0 and o:find("advisory:fragment-backlog:3>2 — ", 1, true) == 1 and o:sub(-11) == " (advisory)", rc .. " " .. o)

if #failed > 0 then
    verdict.emit("violation:fragment-backlog-fixture:" .. #failed .. "-of-3", 1, table.concat(failed, "; "))
end
verdict.ok("fragment-backlog-fixture", "3/3")
