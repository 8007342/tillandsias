-- @env TILLANDSIAS_PLAN_BIN
-- @trace order:2120-a44w, order:1268-m2ir, spec:ci-release
--
-- test-script-run-ignores-foreign-project-root.lua — a Lua script run from
-- inside a scratch repo reads THAT repo, even when PROJECT_ROOT names another
-- checkout (the litmus runner exports PROJECT_ROOT for every step, 1268-m2ir).
--
-- PRE-FIX: FAILS. locate_repo_root took any existing PROJECT_ROOT, so the probe
-- read the real checkout: arm 1 sees no marker. Two fixtures carried a per-site
-- `env -u PROJECT_ROOT` for it (2110-ghw2); this pins the root fix instead.
--
--   1 FOREIGN  PROJECT_ROOT = the real checkout, cwd = scratch -> scratch read
--   2 INSIDE   PROJECT_ROOT = the scratch repo,  cwd = scratch -> scratch read
--   3 CONTROL  premise: the real checkout has no such marker file
local NAME = "script-run-foreign-project-root"
local PLAN = env.get("TILLANDSIAS_PLAN_BIN")
if not PLAN or PLAN == "" then verdict.could_not_run(NAME, "set TILLANDSIAS_PLAN_BIN to the plan binary under test") end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 10000 })
local ROOT = text.trim(top.stdout or "")
if ROOT == "" then verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer") end

local failed = {}
local function arm(name, cond, got)
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

local MARK = "scratch-marker-2120.txt"
local REL = "target/plan-scratch/foreign-project-root-" .. tostring(time.now_ms())
local ABS = ROOT .. "/" .. REL
fs.mkdir(REL .. "/scripts/lua")
fs.write(REL .. "/" .. MARK, "scratch\n")
fs.write(REL .. "/scripts/lua/probe.lua",
    'local ok, body = pcall(fs.read, "' .. MARK .. '")\n'
    .. 'if ok and body then verdict.ok("probe:saw-scratch") else verdict.refused("probe:saw-another-repo") end\n')
proc.run({ argv = { "git", "-C", ABS, "init", "-q" }, timeout_ms = 30000 })

local function probe(project_root)
    local r = proc.run({ argv = { PLAN, "script", "run", "scripts/lua/probe.lua" }, cwd = ABS,
        timeout_ms = 60000, env = { PROJECT_ROOT = project_root } })
    return r.code, text.trim((r.stdout or "") .. (r.stderr or ""))
end

-- 3 first: the premise. If the real checkout HAD the marker, arm 1 would pass
-- for the wrong reason.
arm("3 CONTROL the real checkout has no " .. MARK, not fs.exists(MARK), "present")

local c1, o1 = probe(ROOT)
arm("1 FOREIGN PROJECT_ROOT naming the real checkout does not redirect a scratch-repo script",
    c1 == 0 and o1:find("probe:saw-scratch", 1, true) ~= nil, "rc=" .. tostring(c1) .. " " .. o1)
local c2, o2 = probe(ABS)
arm("2 INSIDE PROJECT_ROOT naming the cwd's own repo still resolves it",
    c2 == 0 and o2:find("probe:saw-scratch", 1, true) ~= nil, "rc=" .. tostring(c2) .. " " .. o2)

proc.run({ argv = { "rm", "-rf", ABS } })
if #failed == 0 then verdict.ok(NAME .. ":3 arms") end
verdict.refused(NAME .. ":" .. #failed .. "-failed", table.concat(failed, "; "))
