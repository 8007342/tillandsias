-- @trace order:1630-dwab
-- @env PATH TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-door-serial-lua-declaration.lua — a .lua guard can declare itself
-- serial (`-- preflight: serial — <reason>`), and the door's own launcher then
-- runs it with nothing beside it.
--
-- WHY. Gate steps 450 (scripts/test-awk-float-lc-numeric.sh) and 455 (the
-- signal .lua, which runs the same .sh) both write .mutant-lcnum-* copies
-- beside three producers in scripts/. The door ran them concurrently with
-- each other and with tree-scanning guards, so step 455 found step 450's live
-- copies (could-not-run) and check-bare-mktemp refused the tree on them,
-- depending on order. _pf_predecide matched the 1499-m9fj declaration only as
-- `# preflight: serial`, so the .lua could not ask to run alone.
--
-- build.sh's _pf_predecide, _pf_launcher, _pf_run_guard and its helpers are
-- EXTRACTED at run time, not copied. The trunk door is the same text with the
-- `-- preflight: serial` matches removed (constructed).
--   1 LUA-FIXED  a planted .lua with `-- preflight: serial — r` predecides 12
--   2 LUA-TRUNK  the same file predecides 0 on the trunk door (the defect)
--   3 SH         a .sh with `# preflight: serial — r` still predecides 12
--   4 BARE       `-- preflight: serial` with no reason runs concurrently (0),
--                with the door's note: the reason rule holds for .lua too
--   5 WRITERS    both real writers of the .mutant-lcnum-* paths predecide 12
--   6 ALONE      the door's launcher at jobs=2 runs scan, WRITER.lua, scan:
--                the writer's window holds no scan, and no scan is open when
--                it starts (scheduling, not a sleep race: the 1 s holds only
--                widen windows the launcher must keep apart)
--   7 OVERLAP    the same roster with the declaration absent overlaps, in
--                the same run, so arm 6 is not passing because of timing
--   8 RUNNER     (1635-ma2f) the door's stale-plan-binary block, run against
--                a scratch root whose resolver answers the RELATIVE
--                ./target/release/tillandsias-plan, hands guards an ABSOLUTE
--                runner; the trunk block (normalisation removed) hands down
--                the relative one, which a guard that cds cannot start
--
-- ORDER 1635-ma2f: the door handed this fixture the relative runner path, the
-- launcher below cds into its scratch root, and the writer never started
-- (marks=0 on every Linux preflight; darwin deadline-skipped it at the door,
-- so it never ran there). PLAN is made absolute here too, and arms 6 and 7
-- print the writer's own rc and output when it did not record both marks.
--
-- Usage: tillandsias-plan script run scripts/lua/test-door-serial-lua-declaration.lua

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("door-serial-lua-declaration", "git rev-parse --show-toplevel did not answer")
end
local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or ""
if PLAN == "" then
    verdict.could_not_run("door-serial-lua-declaration", "TILLANDSIAS_SCRIPT_RUNNER_BIN is unset, so a .lua guard cannot be launched")
end
-- relative to the checkout (the door's ./target/... form); the launcher below
-- runs it from a scratch root, where a relative path names nothing
if PLAN:sub(1, 1) ~= "/" and not PLAN:match("^%a:") then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
local REL = "target/plan-scratch/door-serial-lua-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
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
local parts = { "_preflight_preconditions() { :; }" }
for _, n in ipairs({ "_pf_sweep_under", "_pf_sweep_guard_tmp", "_pf_sweep_fixture_scratch", "_pf_sweep_declared_artifacts", "_pf_now",
    "_pf_run_guard", "_pf_predecide", "_pf_launcher" }) do
    local f = extract(build, n)
    if f ~= "" then parts[#parts + 1] = f end
end
local fns = table.concat(parts, "\n") .. "\n"
local LUA_MATCH, LUA_SUB = "/^-- preflight: serial/p;", "s/^-- preflight: serial[[:space:]]*//p;"
if not fns:find("_pf_predecide() {", 1, true) or not fns:find("_pf_launcher() {", 1, true) then
    verdict.emit("violation:door-serial-lua-declaration:no-subject", 1, "build.sh has no _pf_predecide or _pf_launcher")
end
fs.write(REL .. "/door-post.sh", fns)
local function drop(s, lit)
    local esc = lit:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    return s:gsub(esc, "")
end
local pre, n1 = drop(fns, LUA_MATCH)
local n2
pre, n2 = drop(pre, LUA_SUB)
fs.write(REL .. "/door-pre.sh", pre)

-- predecide <door> <relpath>: prints "rc=<n>" and whatever the door said
fs.write(REL .. "/predecide.sh", table.concat({
    'SCRIPT_DIR="$2"; . "$1"',
    'rc=0; _pf_predecide "$3" "x" || rc=$?',
    'echo "rc=$rc"', "" }, "\n"))
local function predecide(door, dir, rel)
    local r = proc.run({ argv = { "bash", ROOT .. "/" .. REL .. "/predecide.sh", ROOT .. "/" .. REL .. "/door-" .. door .. ".sh",
        dir, rel }, timeout_ms = 30000 })
    return text.trim((r.stdout or "") .. (r.stderr or ""))
end

local P = REL .. "/plant"
fs.mkdir(P .. "/scripts")
fs.write(P .. "/scripts/test-w.lua", "-- @trace order:1630-dwab\n-- preflight: serial — writes shared checkout paths\nverdict.ok(\"w\", \"x\")\n")
fs.write(P .. "/scripts/test-w.sh", "#!/usr/bin/env bash\n# preflight: serial — writes shared checkout paths\nexit 0\n")
fs.write(P .. "/scripts/test-bare.lua", "-- preflight: serial\nverdict.ok(\"b\", \"x\")\n")
local PD = ROOT .. "/" .. P

if n1 ~= 1 or n2 ~= 1 then
    arm("2 LUA-TRUNK premise: each `--` match is removed exactly once", false, "match " .. n1 .. " sub " .. n2)
else
    local o = predecide("pre", PD, "scripts/test-w.lua")
    arm("2 LUA-TRUNK the trunk door runs a `-- preflight: serial` .lua concurrently (0)", o:find("rc=0", 1, true) ~= nil, o)
end
local o = predecide("post", PD, "scripts/test-w.lua")
arm("1 LUA-FIXED a .lua `-- preflight: serial — <reason>` predecides serial (12)", o:find("rc=12", 1, true) ~= nil, o)
o = predecide("post", PD, "scripts/test-w.sh")
arm("3 SH a .sh `# preflight: serial — <reason>` still predecides serial (12)", o:find("rc=12", 1, true) ~= nil, o)
o = predecide("post", PD, "scripts/test-bare.lua")
arm("4 BARE a `-- preflight: serial` with no reason runs concurrently, with the door's note",
    o:find("rc=0", 1, true) ~= nil and o:find("serial-without-a-reason", 1, true) ~= nil, o)
local w1 = predecide("post", ROOT, "scripts/test-awk-float-lc-numeric.sh")
local w2 = predecide("post", ROOT, "scripts/lua/test-awk-float-lc-numeric-signal.lua")
arm("5 WRITERS both writers of the .mutant-lcnum-* paths run alone (12)",
    w1:find("rc=12", 1, true) ~= nil and w2:find("rc=12", 1, true) ~= nil, "step 450 [" .. w1 .. "] step 455 [" .. w2 .. "]")

-- ── 6/7 the launcher's own scheduling ──────────────────────────────────────
-- Each guard appends `<who> start` and `<who> end` to one log around a 1 s
-- hold. The scans are .sh; the writer is a .lua run by the real runner.
local LOG = ROOT .. "/" .. REL .. "/sched.log"
fs.write(REL .. "/mark.sh", 'printf "%s %s\\n" "$1" "$2" >> "$3"\n')
local MARK = ROOT .. "/" .. REL .. "/mark.sh"
local function scan(who)
    return "#!/usr/bin/env bash\nbash " .. MARK .. " " .. who .. " start " .. LOG .. "\nsleep 1\nbash " .. MARK .. " " .. who .. " end " .. LOG .. "\n"
end
local function writer(serial)
    return (serial and "-- preflight: serial — writes shared checkout paths\n" or "-- (no declaration)\n") ..
        'proc.run({ argv = { "bash", "' .. MARK .. '", "W", "start", "' .. LOG .. '" }, timeout_ms = 10000 })\n' ..
        'proc.run({ argv = { "sleep", "1" }, timeout_ms = 10000 })\n' ..
        'proc.run({ argv = { "bash", "' .. MARK .. '", "W", "end", "' .. LOG .. '" }, timeout_ms = 10000 })\n' ..
        'verdict.ok("w", "x")\n'
end
fs.write(REL .. "/launch.sh", table.concat({
    'SCRIPT_DIR="$2"; _pf_plan_bin="$3"; . "$1"',
    'mkdir -p "$2/work"',
    "printf 'scripts/test-s1.sh\\nscripts/test-writer.lua\\nscripts/test-s2.sh\\n' | _pf_launcher \"$2/work\" 10 2",
    "" }, "\n"))
-- overlaps: the log lines of one run, judged as intervals
local function judge(log)
    local open, overlap, seq = {}, false, {}
    for l in (log .. "\n"):gmatch("(.-)\n") do
        local who, what = l:match("^(%S+) (%S+)$")
        if who then
            seq[#seq + 1] = who .. ":" .. what
            if what == "start" then
                for o_ in pairs(open) do
                    if (o_ == "W") ~= (who == "W") then overlap = true end
                end
                open[who] = true
            else
                open[who] = nil
            end
        end
    end
    return overlap, table.concat(seq, " ")
end
local function launch(name, serial)
    local D = REL .. "/" .. name
    fs.mkdir(D .. "/scripts")
    fs.write(D .. "/scripts/test-s1.sh", scan("S1"))
    fs.write(D .. "/scripts/test-s2.sh", scan("S2"))
    fs.write(D .. "/scripts/test-writer.lua", writer(serial))
    fs.write(REL .. "/sched.log", "")
    proc.run({ argv = { "bash", ROOT .. "/" .. REL .. "/launch.sh", ROOT .. "/" .. REL .. "/door-post.sh", ROOT .. "/" .. D, PLAN },
        env = { TILLANDSIAS_SCRIPT_RUNNER_BIN = PLAN }, timeout_ms = 120000 })
    local ov, seq = judge(fs.read(REL .. "/sched.log"))
    local writes = select(2, seq:gsub("W:", ""))
    -- 1635-ma2f: a writer that never marked says WHY, from its own rc and
    -- output (roster entry 2), not only marks=0
    local why = ""
    if writes ~= 2 then
        local okr, rc = pcall(fs.read, D .. "/work/2.rc")
        local oko, o_ = pcall(fs.read, D .. "/work/2.out")
        why = " writer-rc=[" .. text.trim(okr and rc or "absent") .. "] writer-output=[" .. text.trim(oko and o_ or "absent") .. "]"
    end
    return ov, seq, writes, why
end
local ov6, seq6, w6, why6 = launch("alone", true)
arm("6 ALONE the launcher (jobs=2) never runs a scan beside the serial .lua writer",
    w6 == 2 and not ov6, "writer marks=" .. w6 .. " order: " .. seq6 .. why6)
local ov7, seq7, w7, why7 = launch("overlap", false)
arm("7 OVERLAP the same roster without the declaration runs them side by side",
    w7 == 2 and ov7, "writer marks=" .. w7 .. " order: " .. seq7 .. why7)

-- ── 8 the runner the door hands down (1635-ma2f) ───────────────────────────
-- The stale-plan-binary block is cut out of build.sh between its exact-once
-- markers (as test-preflight-stale-plan-binary.sh does) and run with
-- SCRIPT_DIR at a scratch root holding the real probe and a stub binary at
-- ./target/release/tillandsias-plan, the resolver's own relative answer.
local lb, le, blines = nil, nil, {}
for i, l in ipairs(text.lines(build)) do
    blines[i] = l
    if l:find("BEGIN-STALE-PLAN-BINARY-CHECK", 1, true) then lb = i end
    if l:find("END-STALE-PLAN-BINARY-CHECK", 1, true) then le = i end
end
if not lb or not le or lb >= le then
    arm("8 RUNNER premise: the stale-plan-binary block is in build.sh", false, "markers " .. tostring(lb) .. ".." .. tostring(le))
else
    local blk = table.concat(blines, "\n", lb, le) .. "\n"
    local NORM = '    case "$_pf_plan_bin" in\n        ""|/*|[A-Za-z]:*) ;;\n        *) _pf_plan_bin="$SCRIPT_DIR/${_pf_plan_bin#./}" ;;\n    esac\n'
    local blk_pre, nn = blk:gsub(NORM:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"), "")
    local S = REL .. "/runner"
    fs.mkdir(S .. "/scripts")
    fs.mkdir(S .. "/target/release")
    fs.write(S .. "/scripts/plan-binary-probe.sh", fs.read("scripts/plan-binary-probe.sh"))
    fs.write(S .. "/target/release/tillandsias-plan",
        '#!/bin/sh\ncase "$1" in validator-surface-hash) echo ok:validator-surface:stub ;; esac\nexit 0\n')
    proc.run({ argv = { "chmod", "+x", ROOT .. "/" .. S .. "/target/release/tillandsias-plan" }, timeout_ms = 10000 })
    local function hand(which, body)
        fs.write(REL .. "/runner-" .. which .. ".sh", 'SCRIPT_DIR="$1"\n' .. body .. 'echo "runner=$_pf_plan_bin"\n')
        local r = proc.run({ argv = { "bash", ROOT .. "/" .. REL .. "/runner-" .. which .. ".sh", ROOT .. "/" .. S },
            cwd = ROOT, timeout_ms = 30000 })
        return text.trim((r.stdout or "") .. (r.stderr or ""))
    end
    local post, pre_ = hand("post", blk), hand("pre", blk_pre)
    local want = "runner=" .. ROOT .. "/" .. S .. "/target/release/tillandsias-plan"
    arm("8 RUNNER the door hands guards an absolute runner; the trunk block hands down the relative one",
        nn == 1 and post:find(want, 1, true) ~= nil
        and pre_:find("runner=./target/release/tillandsias-plan", 1, true) ~= nil,
        "removed=" .. nn .. " post [" .. post .. "] pre [" .. pre_ .. "]")
end

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:door-serial-lua-declaration:" .. #failed .. "-failed", 1)
end
verdict.ok("door-serial-lua-declaration", "8 arms")
