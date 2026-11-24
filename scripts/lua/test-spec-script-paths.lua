-- @trace order:815-yace, order:2083-6k44, spec:ci-release
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- test-spec-script-paths.lua: scripts/lua/check-spec-script-paths.lua refuses
-- a spec that names a script the tree does not have, and says so by name.
-- Ported from scripts/test-spec-script-paths.sh with its six arms:
--   1 LIVE: the real specs against the real baseline -> ok
--   2 a seeded spec naming a missing script -> blocked, named; the present one is not
--   3 the same line marked `spec-path-absent: ok (<reason>)` -> ok, 1-exempt
--   4 THE ROW'S OWN CRITERION: the PRE-FIX project-summarizers spec (pinned at
--     b6fe04b4f) with an EMPTY baseline, resolved against the real tree ->
--     blocked, naming all six summarizer paths
--   5 a baseline entry whose path now resolves -> ok, with a burndown note
--   6 no spec names any script -> could-not-run (exit 2), never ok
local SUBJECT = "scripts/lua/check-spec-script-paths.lua"
if not fs.exists(SUBJECT) then
    verdict.emit("violation:spec-script-paths-fixture:no-subject", 1, SUBJECT .. " does not exist")
end
local BIN = env.get("TILLANDSIAS_PLAN_BIN")
if BIN == nil or BIN == "" then BIN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if BIN == nil or BIN == "" then
    verdict.could_not_run("spec-script-paths-fixture", "no-plan-binary — set TILLANDSIAS_PLAN_BIN")
end
-- git, not pwd -P: a native Windows runner calls /c/... relative.
local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 10000 }).stdout or "")
if ROOT == "" then verdict.could_not_run("spec-script-paths-fixture", "git rev-parse gave no root") end

local W = "target/plan-scratch/spec-script-paths-" .. time.iso_utc():gsub("%W", "") .. "-" .. tostring(math.random(100000, 999999))
local failed, passed = {}, 0
local function arm(name, cond, got)
    if cond then out.line("ok:   " .. name); passed = passed + 1 else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

local function world(name)
    local d = W .. "/" .. name
    fs.mkdir(d .. "/specs/demo")
    fs.mkdir(d .. "/root/scripts")
    fs.write(d .. "/baseline.txt", "")
    return d
end
local function run(d, root)
    local r = proc.run({ argv = { BIN, "script", "run", SUBJECT }, cwd = ROOT, timeout_ms = 120000,
        env = { TILLANDSIAS_SPEC_PATHS_SPECS = d .. "/specs", TILLANDSIAS_SPEC_PATHS_ROOT = root or (d .. "/root"),
                TILLANDSIAS_SPEC_PATHS_BASELINE = d .. "/baseline.txt" } })
    local o = (r.stdout or "") .. (r.stderr or "")
    local lines = text.lines(text.trim(r.stdout or ""))
    return r.code, o, lines[#lines] or ""
end
local function count(s, pat)
    local n = 0
    for _ in s:gmatch(pat) do n = n + 1 end
    return n
end

-- W is repo-relative: the runner refuses an absolute path as outside the repo
-- 1 LIVE
local live = proc.run({ argv = { BIN, "script", "run", SUBJECT }, cwd = ROOT, timeout_ms = 120000 })
local last = text.trim(live.stdout or "")
arm("1 LIVE tree is ok (" .. last .. ")", live.code == 0 and last:find("^ok:spec%-script%-paths:") ~= nil, last .. " rc=" .. tostring(live.code))

-- 2 missing script refused by name, present one not
local d = world("a")
fs.write(d .. "/specs/demo/spec.md", "The gate MUST run `scripts/present.sh` and `scripts/missing-thing.sh`.\n")
fs.write(d .. "/root/scripts/present.sh", "")
local rc, o, v = run(d)
arm("2 a missing script is refused by name; the present one is not",
    rc == 1 and v == "blocked:spec-script-paths:1-unresolved" and o:find("scripts/missing-thing.sh", 1, true)
        and not o:find("violation:[^\n]*present%.sh"), v .. " rc=" .. tostring(rc))

-- 3 marked negative requirement is exempt
d = world("b")
fs.write(d .. "/specs/demo/spec.md", "The tray MUST NOT invoke `scripts/missing-thing.sh`. <!-- spec-path-absent: ok (a negative requirement) -->\n")
rc, o, v = run(d)
arm("3 a marked negative requirement is exempt and counted", rc == 0 and v:find("1%-exempt$") ~= nil, v)

-- 4 the pre-fix project-summarizers spec, empty baseline, real tree
local pinned = proc.run({ argv = { "git", "-C", ROOT, "show", "b6fe04b4f:openspec/specs/project-summarizers/spec.md" }, timeout_ms = 30000 })
if pinned.code == 0 and (pinned.stdout or "") ~= "" then
    d = W .. "/c"
    fs.mkdir(d .. "/specs/project-summarizers")
    fs.write(d .. "/specs/project-summarizers/spec.md", pinned.stdout)
    fs.write(d .. "/baseline.txt", "")
    rc, o, v = run(d, ROOT)
    local n = count(o, "violation:spec%-script%-paths:[^\n]*scripts/summarizers/summarize%-")
    arm("4 the pre-fix project-summarizers spec is refused, all six summarizer paths named", rc == 1 and n == 6,
        "rc=" .. tostring(rc) .. " named=" .. n .. " " .. v)
else
    arm("4 cannot read the pinned pre-fix spec at b6fe04b4f (shallow clone?)", false, pinned.stderr)
end

-- 5 a baselined path that now resolves prints the burndown note
d = world("d")
fs.write(d .. "/specs/demo/spec.md", "Run `scripts/now-here.sh`.\n")
fs.write(d .. "/root/scripts/now-here.sh", "")
fs.write(d .. "/baseline.txt", d .. "/specs/demo/spec.md\tscripts/now-here.sh\twas missing\n")
rc, o, v = run(d)
arm("5 a baselined path that now resolves prints the burndown note", rc == 0 and o:find("now RESOLVES", 1, true) ~= nil, o)

-- 6 empty population is could-not-run, never ok
d = world("e")
fs.write(d .. "/specs/demo/spec.md", "No scripts here.\n")
rc, o, v = run(d)
arm("6 a spec set naming no script is could-not-run, never ok", rc == 2 and v:find("^could%-not%-run:spec%-script%-paths:") ~= nil,
    v .. " rc=" .. tostring(rc))

if #failed > 0 then
    verdict.emit("violation:spec-script-paths-fixture:" .. passed .. "/6", 1)
end
verdict.emit("ok:spec-script-paths-fixture:6/6", 0)
