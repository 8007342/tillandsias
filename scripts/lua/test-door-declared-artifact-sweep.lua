-- @trace order:1630-dwab
-- @env PATH TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-door-declared-artifact-sweep.lua — when the preflight door KILLs a
-- declared checkout writer, or a guard that names one, it removes the
-- writer's declared in-checkout artifacts (`artifacts=<basename-glob>` in
-- scripts/portability/checkout-writers.txt). Without that, a writer killed at
-- the deadline leaves copies in scripts/ (the .mutant-lcnum-* copies of
-- test-awk-float-lc-numeric.sh), and check-bare-mktemp refuses the tree on them.
--
-- build.sh's _pf_run_guard and its sweep helpers are EXTRACTED at run time,
-- not copied, and run with SCRIPT_DIR pointed at a scratch git repository
-- (never this checkout's scripts/). The planted writer makes two
-- .mutant-plant-* copies that each carry a bare mktemp, IGNORES TERM and execs
-- a 30 s sleep, so the door's KILL always lands, on every OS: KILL-direct, with
-- no reliance on how a shell treats TERM (1611-imnj was evicted on Linux for
-- that). The deadline is 2 s.
--   1 PRE-FIX    the same function with the new sweep call removed (the trunk
--                door, constructed): rc 124, both copies left
--   2 POST-FIX   a guard that NAMES the writer is killed: rc 124, both copies
--                gone, swept:declared-artifact:<path> recorded for each
--   3 PRECISE    a TRACKED file matching the glob and an untracked file not
--                matching it are both untouched
--   4 WRITER     killing the declared writer itself sweeps the same way
--   5 MKTEMP     check-bare-mktemp over the post-fix tree says ok, and over
--                the trunk-door tree refuses on the left copies, in one run
--   6 NORMAL     a guard that ends on its own is not swept: a matching
--                untracked file stays, and no sweep line is recorded
--
-- Usage: tillandsias-plan script run scripts/lua/test-door-declared-artifact-sweep.lua

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("door-declared-artifact-sweep", "git rev-parse --show-toplevel did not answer")
end
local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or ""
if PLAN == "" then
    verdict.could_not_run("door-declared-artifact-sweep", "TILLANDSIAS_SCRIPT_RUNNER_BIN is unset, so check-bare-mktemp cannot be run")
end
local REL = "target/plan-scratch/door-declared-artifact-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)

local failed = {}
local function arm(name, cond, got)
    got = tostring(got):gsub("\n", " | ")
    if cond then out.line("ok:   " .. name .. " — " .. got) else
        out.line("FAIL: " .. name .. " — got: " .. got)
        failed[#failed + 1] = name
    end
end

local function extract(text_, name)
    local acc, on = {}, false
    for l in (text_ .. "\n"):gmatch("(.-)\n") do
        if l:match("^" .. name .. "%(%) {") then on = true end
        if on then
            acc[#acc + 1] = l
            if l == "}" then break end
        end
    end
    return table.concat(acc, "\n")
end
local build = fs.read("build.sh")
local CALL = '_pf_sweep_declared_artifacts "$_p" "$_out"'
local parts = {}
for _, n in ipairs({ "_pf_sweep_under", "_pf_sweep_guard_tmp", "_pf_sweep_fixture_scratch",
    "_pf_sweep_declared_artifacts", "_pf_now", "_pf_run_guard" }) do
    local f = extract(build, n)
    if f ~= "" then parts[#parts + 1] = f end
end
local fns = table.concat(parts, "\n") .. "\n"
if not fns:find("_pf_sweep_declared_artifacts() {", 1, true) or not fns:find(CALL, 1, true) then
    verdict.emit("violation:door-declared-artifact-sweep:no-subject", 1,
        "build.sh has no _pf_sweep_declared_artifacts, or _pf_run_guard does not call it (1630-dwab)")
end
fs.write(REL .. "/door-post.sh", fns)
local pre, n = fns:gsub("\n%s*" .. CALL:gsub("[%$%(%)%.%-]", "%%%0") .. "\n", "\n")
fs.write(REL .. "/door-pre.sh", pre)

local WRITER = table.concat({
    "#!/usr/bin/env bash",
    'mkdir -p scripts/sub',
    -- the word is assembled at run time, so only the COPIES carry a bare
    -- mktemp, never the writer itself (check-bare-mktemp scans both)
    'm=mk; m="${m}temp"',
    "printf 'x=\"$(%s)\"\\n' \"$m\" > scripts/.mutant-plant-a.sh",
    "printf 'y=\"$(%s -d)\"\\n' \"$m\" > scripts/sub/.mutant-plant-b.sh",
    "trap '' TERM",
    "exec sleep 30",
    "" }, "\n")
local NAMES = "#!/usr/bin/env bash\n# runs the declared writer\nexec bash scripts/test-plant.sh\n"
local QUICK = "#!/usr/bin/env bash\n# names scripts/test-plant.sh but never runs it\nexit 0\n"

fs.write(REL .. "/harness.sh", table.concat({
    "set -u",
    'FN="$1"; R="$2"; G="$3"; SCRIPT_DIR="$R"',
    '. "$FN"',
    'rc=0; _pf_run_guard "$G" 2 "$R/out" "" || rc=$?',
    'echo "rc=$rc"',
    'n=0; for f in "$R/scripts/.mutant-plant-a.sh" "$R/scripts/sub/.mutant-plant-b.sh"; do [ -f "$f" ] && n=$((n + 1)); done',
    'echo "left=$n"',
    '[ -f "$R/scripts/.mutant-plant-tracked.sh" ] && echo tracked=kept || echo tracked=gone',
    '[ -f "$R/scripts/keep-me.txt" ] && echo other=kept || echo other=gone',
    '[ -f "$R/scripts/.mutant-plant-c.sh" ] && echo idle=kept || echo idle=gone',
    '[ ! -f "$R/out.swept" ] || cat "$R/out.swept"',
    "" }, "\n"))

local function git(R, ...)
    return proc.run({ argv = { "git", "-C", R, "-c", "user.name=fixture", "-c", "user.email=fixture@invalid", ... },
        timeout_ms = 30000 })
end
-- plant <name>: a scratch repository with the declaration, the guards, one
-- TRACKED file matching the glob and one untracked file that does not match
local function plant(name, idle)
    local R = REL .. "/" .. name
    fs.mkdir(R .. "/scripts/portability")
    fs.write(R .. "/scripts/portability/checkout-writers.txt",
        "# fixture declaration\nscripts/test-plant.sh artifacts=.mutant-plant-* its copies sit beside what they copy\n")
    fs.write(R .. "/scripts/test-plant.sh", WRITER)
    fs.write(R .. "/scripts/test-names.sh", NAMES)
    fs.write(R .. "/scripts/test-quick.sh", QUICK)
    fs.write(R .. "/scripts/.mutant-plant-tracked.sh", "# tracked, matching the glob: never swept\n")
    local A = ROOT .. "/" .. R
    git(A, "init", "-q")
    git(A, "add", "-A")
    git(A, "commit", "-q", "-m", "plant")
    fs.write(R .. "/scripts/keep-me.txt", "untracked, not matching\n")
    if idle then fs.write(R .. "/scripts/.mutant-plant-c.sh", "# untracked, matching, present before the guard\n") end
    return A
end
local function door(which, R, guard)
    local r = proc.run({ argv = { "bash", ROOT .. "/" .. REL .. "/harness.sh", ROOT .. "/" .. REL .. "/door-" .. which .. ".sh",
        R, guard }, cwd = ROOT, timeout_ms = 120000 })
    return text.trim(r.stdout or "")
end
local function mktemp_verdict(name)
    fs.write(REL .. "/" .. name .. "-floor.txt", "")
    local r = proc.run({ argv = { PLAN, "script", "run", ROOT .. "/scripts/lua/check-bare-mktemp.lua" }, cwd = ROOT,
        env = { TILLANDSIAS_BARE_MKTEMP_SCAN_DIR = REL .. "/" .. name .. "/scripts",
                TILLANDSIAS_BARE_MKTEMP_FLOOR = REL .. "/" .. name .. "-floor.txt" }, timeout_ms = 60000 })
    local last = ""
    for l in ((r.stdout or "") .. "\n"):gmatch("(.-)\n") do
        if l:match("^ok:") or l:match("^violation:") or l:match("^could%-not%-run:") then last = l end
    end
    return last
end

local Rpre = plant("pre")
if n ~= 1 then
    arm("1 PRE-FIX premise: the sweep call is removed exactly once", false, "removed " .. n)
else
    local o = door("pre", Rpre, "scripts/test-names.sh")
    arm("1 PRE-FIX the trunk door KILLs the guard and leaves both copies (the defect)",
        o:find("rc=124", 1, true) ~= nil and o:find("left=2", 1, true) ~= nil, o)
end
local Rpost = plant("post")
local o = door("post", Rpost, "scripts/test-names.sh")
arm("2 POST-FIX killing a guard that names the writer removes both copies and records each",
    o:find("rc=124", 1, true) ~= nil and o:find("left=0", 1, true) ~= nil
    and o:find("swept:declared-artifact:" .. Rpost .. "/scripts/.mutant-plant-a.sh", 1, true) ~= nil
    and o:find("swept:declared-artifact:" .. Rpost .. "/scripts/sub/.mutant-plant-b.sh", 1, true) ~= nil, o)
arm("3 PRECISE a tracked file matching the glob and an untracked non-matching file are untouched",
    o:find("tracked=kept", 1, true) ~= nil and o:find("other=kept", 1, true) ~= nil, o)
local Rw = plant("writer")
o = door("post", Rw, "scripts/test-plant.sh")
arm("4 WRITER killing the declared writer itself sweeps its copies",
    o:find("rc=124", 1, true) ~= nil and o:find("left=0", 1, true) ~= nil, o)
local mpost, mpre = mktemp_verdict("post"), mktemp_verdict("pre")
arm("5 MKTEMP check-bare-mktemp says ok after the fixed door's kill, and refuses after the trunk door's",
    mpost:match("^ok:bare%-mktemp:") ~= nil and mpre:match("^violation:bare%-mktemp:") ~= nil,
    "post [" .. mpost .. "] pre [" .. mpre .. "]")
local Ri = plant("idle", true)
o = door("post", Ri, "scripts/test-quick.sh")
arm("6 NORMAL a guard that ends on its own is not swept",
    o:find("rc=0", 1, true) ~= nil and o:find("idle=kept", 1, true) ~= nil
    and o:find("swept:declared-artifact", 1, true) == nil, o)

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:door-declared-artifact-sweep:" .. #failed .. "-failed", 1)
end
verdict.ok("door-declared-artifact-sweep", "6 arms")
