-- @trace order:1618-baia
-- @env PATH
--
-- test-door-fixture-scratch-sweep.lua — when the preflight door KILLs a guard,
-- it removes the guard's per-run fixture scratch,
-- .tillandsias/fixture-scratch/<guard>.<pid>, as it removes the guard's TMPDIR.
--
-- build.sh's _pf_run_guard and its sweep helpers are EXTRACTED at run time,
-- not copied, and run with SCRIPT_DIR pointed at a scratch root (never this
-- checkout's .tillandsias/). The planted guard makes
-- <root>/.tillandsias/fixture-scratch/test-plant.$$ with an EXIT trap that
-- would remove it, IGNORES TERM, and execs a 30 s sleep. The door's TERM does
-- nothing on any OS, so its KILL always lands and no trap runs. That is the
-- control's whole point (1611-imnj was evicted on Linux for a control that
-- relied on darwin's TERM behaviour). The deadline is 2 s.
--   1 PRE-FIX    the same function with the new sweep call removed (the trunk
--                door, constructed): rc 124, the subdir is left (the defect)
--   2 POST-FIX   rc 124, the subdir is gone, swept:fixture-scratch:<path> recorded
--   3 PRECISE    another run's subdir (same guard, another pid) is untouched
--   4 NORMAL     a guard that ends on its own is not swept: its EXIT trap
--                already removed the subdir, and no sweep line is recorded
--
-- Usage: tillandsias-plan script run scripts/lua/test-door-fixture-scratch-sweep.lua

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("door-fixture-scratch-sweep", "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/door-fixture-scratch-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
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
local CALL = '_pf_sweep_fixture_scratch "$_p" "$_pid" "$_out"'
local parts = {}
for _, n in ipairs({ "_pf_sweep_under", "_pf_sweep_guard_tmp", "_pf_sweep_fixture_scratch", "_pf_now", "_pf_run_guard" }) do
    local f = extract(build, n)
    if f ~= "" then parts[#parts + 1] = f end -- _pf_now exists only once 1614-5x7m is on the tree
end
local fns = table.concat(parts, "\n") .. "\n"
if not fns:find("_pf_sweep_fixture_scratch() {", 1, true) or not fns:find(CALL, 1, true) then
    verdict.emit("violation:door-fixture-scratch-sweep:no-subject", 1,
        "build.sh has no _pf_sweep_fixture_scratch, or _pf_run_guard does not call it (1618-baia)")
end
fs.write(REL .. "/door-post.sh", fns)
local pre, n = fns:gsub("\n%s*" .. CALL:gsub("[%$%(%)%.%-]", "%%%0") .. "\n", "\n")
fs.write(REL .. "/door-pre.sh", pre)

local PLANT_KILLED = table.concat({
    'W="$PWD/.tillandsias/fixture-scratch/$(basename "$0" .sh).$$"',
    'rm -rf "$W"; mkdir -p "$W"; trap \'rm -rf "$W"\' EXIT',
    "trap '' TERM",
    ': > "$W/held"',
    "exec sleep 30",
    "" }, "\n")
local PLANT_NORMAL = table.concat({
    'W="$PWD/.tillandsias/fixture-scratch/$(basename "$0" .sh).$$"',
    'rm -rf "$W"; mkdir -p "$W"; trap \'rm -rf "$W"\' EXIT',
    ': > "$W/held"',
    "exit 0",
    "" }, "\n")
fs.write(REL .. "/harness.sh", table.concat({
    "set -u",
    'FN="$1"; R="$2"; SCRIPT_DIR="$R"',
    '. "$FN"',
    'rc=0; _pf_run_guard "$R/scripts/test-plant.sh" 2 "$R/out" "" || rc=$?',
    'echo "rc=$rc"',
    -- left counts THIS run's subdirs only; test-plant.999999 is arm 3's other run
    'n=0; for d in "$R"/.tillandsias/fixture-scratch/test-plant.*; do case "$d" in *.999999) ;; *) [ -d "$d" ] && n=$((n + 1)) ;; esac; done',
    'echo "left=$n"',
    '[ -d "$R/.tillandsias/fixture-scratch/test-plant.999999" ] && echo other=kept || echo other=gone',
    '[ ! -f "$R/out.swept" ] || cat "$R/out.swept"',
    "" }, "\n"))

local function door(which, plant, name)
    local R = REL .. "/" .. name
    fs.mkdir(R .. "/scripts")
    fs.mkdir(R .. "/.tillandsias/fixture-scratch/test-plant.999999")
    fs.write(R .. "/scripts/test-plant.sh", plant)
    local r = proc.run({ argv = { "bash", ROOT .. "/" .. REL .. "/harness.sh", ROOT .. "/" .. REL .. "/door-" .. which .. ".sh",
        ROOT .. "/" .. R }, cwd = ROOT, timeout_ms = 120000 })
    return text.trim(r.stdout or "")
end

if n ~= 1 then
    arm("1 PRE-FIX premise: the sweep call is removed exactly once", false, "removed " .. n)
else
    local o = door("pre", PLANT_KILLED, "pre")
    arm("1 PRE-FIX the trunk door KILLs the guard and leaves its fixture-scratch subdir (the defect)",
        o:find("rc=124", 1, true) ~= nil and o:find("left=1", 1, true) ~= nil, o)
end
local o = door("post", PLANT_KILLED, "post")
arm("2 POST-FIX the door KILLs the guard, removes the subdir and records it",
    o:find("rc=124", 1, true) ~= nil and o:find("left=0", 1, true) ~= nil
    and o:find("swept:fixture-scratch:" .. ROOT .. "/" .. REL .. "/post/.tillandsias/fixture-scratch/test-plant.", 1, true) ~= nil, o)
arm("3 PRECISE another run's subdir (same guard, another pid) is untouched", o:find("other=kept", 1, true) ~= nil, o)
o = door("post", PLANT_NORMAL, "normal")
arm("4 NORMAL a guard that ends on its own is not swept: its own trap removed the subdir",
    o:find("rc=0", 1, true) ~= nil and o:find("left=0", 1, true) ~= nil
    and o:find("swept:fixture-scratch", 1, true) == nil, o)

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:door-fixture-scratch-sweep:" .. #failed .. "-failed", 1)
end
verdict.ok("door-fixture-scratch-sweep", "4 arms")
