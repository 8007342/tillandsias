-- @trace order:1650-fb7z
-- @env PATH TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-door-index-lock-sweep.lua — the preflight door removes a stale
-- .git/index.lock that a guard's git left, and only such a lock. Three
-- preflights on yolanda (2026-10-12) each left a 0-byte index.lock with no git
-- alive, and the next git add / git switch refused on it.
--
-- A git that gets SIGTERM removes its own lock; a SIGKILLed one cannot. The
-- real SIGKILL is proc.run's timeout_ms (tillandsias-exec KILLs the group), and
-- the Lua guard around it then ends on its own. So the planted git is
-- `git update-index --refresh` under a core.fsmonitor hook that ignores TERM
-- and sleeps 30 s: git takes index.lock BEFORE it asks the hook (measured, git
-- 2.55.0), so the lock is held when the KILL lands.
--
-- build.sh's _pf_run_guard, _pf_sweep_late and their helpers are EXTRACTED at
-- run time, not copied, and run with SCRIPT_DIR pointed at a scratch git
-- repository. tasklist.exe is taken off PATH, so a Windows host's own git.exe
-- cannot decide an arm; arm 5 plants a fake one.
--   1 PRE-FIX    the trunk door (both sweep calls removed, constructed): a Lua
--                guard whose proc.run timeout KILLs git ends rc 0, and the
--                lock is left after the run's late sweep
--   2 POST-FIX   the fixed door: the late sweep removes it and records
--                swept:index-lock-late:<path>
--   3 KILLED     a guard the door KILLs, whose git was SIGKILLed: removed
--                after that guard, swept:index-lock:<path>
--   4 HELD       a lock held open by a live process outside the guard's group,
--                created after the guard started: KEPT and named, its holder
--                alive, by both sweeps (the negative control)
--   5 WINDOWS    a tasklist.exe that reports a live git.exe: KEPT
--   6 OLDER      an unheld lock that predates the run: untouched, no line
--   7 NORMAL     a guard that ends on its own gets no per-guard sweep
--   8 ENV        the door runs its guards with GIT_OPTIONAL_LOCKS=0
--
-- Usage: tillandsias-plan script run scripts/lua/test-door-index-lock-sweep.lua

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("door-index-lock-sweep", "git rev-parse --show-toplevel did not answer")
end
local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or ""
if PLAN == "" then
    verdict.could_not_run("door-index-lock-sweep", "TILLANDSIAS_SCRIPT_RUNNER_BIN is unset, so the Lua guard cannot be run")
end
local REL = "target/plan-scratch/door-index-lock-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
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
local KCALL = '_pf_sweep_index_lock "$_out.start" "$_out"'
local LCALL = '_pf_sweep_index_lock "$1/start" "$1/late" index-lock-late'
local parts = {}
for _, n in ipairs({ "_pf_sweep_under", "_pf_sweep_guard_tmp", "_pf_sweep_fixture_scratch",
    "_pf_sweep_declared_artifacts", "_pf_index_lock_held", "_pf_sweep_index_lock", "_pf_sweep_late",
    "_pf_now", "_pf_run_guard" }) do
    local f = extract(build, n)
    if f ~= "" then parts[#parts + 1] = f end
end
local fns = table.concat(parts, "\n") .. "\n"
if not fns:find("_pf_sweep_index_lock() {", 1, true) or not fns:find(KCALL, 1, true)
    or not fns:find(LCALL, 1, true) then
    verdict.emit("violation:door-index-lock-sweep:no-subject", 1,
        "build.sh has no _pf_sweep_index_lock, or the door does not call it after a kill and from the late sweep (1650-fb7z)")
end
fs.write(REL .. "/door-post.sh", fns)
local function esc(s) return (s:gsub("[%$%(%)%.%-]", "%%%0")) end
local pre, n1 = fns:gsub("\n%s*" .. esc(KCALL) .. "\n", "\n")
local n2
pre, n2 = pre:gsub("\n%s*" .. esc(LCALL) .. "\n", "\n")
fs.write(REL .. "/door-pre.sh", pre)

local SLOWMON = "#!/bin/sh\ntrap '' TERM\nsleep 30\nexit 1\n"
local FAKE_TASKLIST = "#!/bin/sh\necho 'git.exe                      4242 Console                    1     51,200 K'\n"
-- the guards, run by the door with cwd = the scratch repository
local function lua_guard(A)
    return table.concat({
        "-- @env PATH",
        'local r = proc.run({ argv = { "git", "-c", "core.fsmonitor=' .. A .. '/slowmon", "update-index", "-q", "--refresh" }, timeout_ms = 1500 })',
        'out.line("git:" .. tostring(r.status))',
        'verdict.ok("slowgit", "the timeout killed git")',
        "" }, "\n")
end
local KILLED = table.concat({
    "#!/usr/bin/env bash",
    'git -c core.fsmonitor="$PWD/slowmon" update-index -q --refresh &',
    "g=$!",
    "for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e .git/index.lock ] && break; sleep 0.2; done",
    'kill -KILL "$g"; wait "$g" 2>/dev/null',
    "trap '' TERM",
    "exec sleep 30",
    "" }, "\n")
local HOLDER = table.concat({
    "#!/usr/bin/env bash",
    "trap '' TERM",
    -- the holder leaves the guard's process group, so the door's KILL misses it
    "if command -v setsid >/dev/null 2>&1; then",
    "    setsid bash -c 'exec 9>.git/index.lock; exec sleep 20' </dev/null >/dev/null 2>&1 &",
    "else",
    "    bash -c 'exec 9>.git/index.lock; exec sleep 20' </dev/null >/dev/null 2>&1 &",
    "fi",
    'echo "$!" > holder.pid',
    "exec sleep 30",
    "" }, "\n")
local IDLE = "#!/usr/bin/env bash\ntrap '' TERM\nexec sleep 30\n"
local QUICK = "#!/usr/bin/env bash\n: > .git/index.lock\necho \"GIT_OPTIONAL_LOCKS=${GIT_OPTIONAL_LOCKS:-unset}\"\nexit 0\n"

fs.write(REL .. "/harness.sh", table.concat({
    "set -u",
    'FN="$1"; R="$2"; G="$3"; DL="$4"; FAKE="${5:-}"; SCRIPT_DIR="$R"',
    '_pf_plan_bin="$PLAN_BIN"',
    -- no real tasklist.exe: a Windows host's own git.exe must not decide an arm
    'P=""; IFS=: read -r -a _ds <<< "$PATH"',
    'for d in "${_ds[@]}"; do [ -e "$d/tasklist.exe" ] || P="${P:+$P:}$d"; done',
    '[ -z "$FAKE" ] || P="$FAKE:$P"',
    'PATH="$P"; export PATH',
    '. "$FN"',
    'D="$R/run"; mkdir -p "$D"; : > "$D/start"',
    'rc=0; _pf_run_guard "$G" "$DL" "$D/out" "" || rc=$?',
    'echo "rc=$rc"',
    '[ -e "$R/.git/index.lock" ] && echo guard-lock=left || echo guard-lock=gone',
    '[ ! -f "$D/out.swept" ] || cat "$D/out.swept"',
    '[ ! -f "$D/out" ] || grep -h -e "^GIT_OPTIONAL_LOCKS=" -e "^git:" "$D/out" || true',
    '_pf_sweep_late "$D"',
    '[ -e "$R/.git/index.lock" ] && echo late-lock=left || echo late-lock=gone',
    'if [ -s "$R/holder.pid" ]; then h="$(cat "$R/holder.pid")"; if kill -0 "$h" 2>/dev/null; then echo holder=alive; kill "$h" 2>/dev/null; else echo holder=dead; fi; fi',
    "" }, "\n"))

local function git(R, ...)
    return proc.run({ argv = { "git", "-C", R, "-c", "user.name=fixture", "-c", "user.email=fixture@invalid", ... },
        timeout_ms = 30000 })
end
local function plant(name, stale)
    local R = REL .. "/" .. name
    local A = ROOT .. "/" .. R
    fs.mkdir(R .. "/fakebin")
    fs.write(R .. "/f", "a\n")
    git(A, "init", "-q")
    git(A, "add", "f")
    git(A, "commit", "-q", "-m", "plant")
    fs.write(R .. "/slowgit.lua", lua_guard(A))
    fs.write(R .. "/killed.sh", KILLED)
    fs.write(R .. "/holder.sh", HOLDER)
    fs.write(R .. "/idle.sh", IDLE)
    fs.write(R .. "/quick.sh", QUICK)
    fs.write(R .. "/slowmon", SLOWMON)
    fs.write(R .. "/fakebin/tasklist.exe", FAKE_TASKLIST)
    proc.run({ argv = { "chmod", "+x", A .. "/slowmon", A .. "/fakebin/tasklist.exe" }, timeout_ms = 10000 })
    if stale then fs.write(R .. "/.git/index.lock", "") end
    return A
end
local function door(which, R, guard, deadline, fake)
    local r = proc.run({ argv = { "bash", ROOT .. "/" .. REL .. "/harness.sh", ROOT .. "/" .. REL .. "/door-" .. which .. ".sh",
        R, guard, tostring(deadline), fake or "" }, env = { PLAN_BIN = PLAN }, cwd = ROOT, timeout_ms = 120000 })
    return text.trim(r.stdout or "")
end
local function has(o, s) return o:find(s, 1, true) ~= nil end

local Rpre = plant("pre")
if n1 ~= 1 or n2 ~= 1 then
    arm("1 PRE-FIX premise: each sweep call is removed exactly once", false, "removed " .. n1 .. " and " .. n2)
else
    local o = door("pre", Rpre, "slowgit.lua", 20)
    arm("1 PRE-FIX the trunk door: proc.run's timeout KILLs git, the guard ends rc 0, the lock is left (the defect)",
        has(o, "rc=0") and has(o, "git:timed_out") and has(o, "late-lock=left"), o)
end
local Rpost = plant("post")
local o = door("post", Rpost, "slowgit.lua", 20)
arm("2 POST-FIX the late sweep removes the lock a timed-out git left, and names it",
    has(o, "rc=0") and has(o, "late-lock=gone") and has(o, "swept:index-lock-late:"), o)
local Rk = plant("killed")
o = door("post", Rk, "killed.sh", 3)
arm("3 KILLED after the door KILLs a guard whose git was SIGKILLed, the lock is removed and named",
    has(o, "rc=124") and has(o, "guard-lock=gone") and has(o, "swept:index-lock:"), o)
local Rh = plant("held")
o = door("post", Rh, "holder.sh", 2)
arm("4 HELD a lock a live process holds is never removed, by either sweep (negative control)",
    has(o, "rc=124") and has(o, "late-lock=left") and has(o, "holder=alive")
    and has(o, "kept:index-lock:") and has(o, "kept:index-lock-late:") and not has(o, "swept:index-lock"), o)
local Rw = plant("windows")
o = door("post", Rw, "killed.sh", 3, Rw .. "/fakebin")
arm("5 WINDOWS a live git.exe reported by tasklist keeps the lock",
    has(o, "rc=124") and has(o, "late-lock=left") and has(o, "kept:index-lock:")
    and not has(o, "swept:index-lock"), o)
local Ro = plant("older", true)
o = door("post", Ro, "idle.sh", 2)
arm("6 OLDER an unheld lock that predates the run is untouched, and no line is recorded",
    has(o, "rc=124") and has(o, "late-lock=left") and not has(o, "index-lock"), o)
local Rn = plant("normal")
o = door("post", Rn, "quick.sh", 2)
arm("7 NORMAL a guard that ends on its own gets no per-guard sweep",
    has(o, "rc=0") and has(o, "guard-lock=left") and not has(o, "swept:index-lock:"), o)
arm("8 ENV the door runs its guards with GIT_OPTIONAL_LOCKS=0", has(o, "GIT_OPTIONAL_LOCKS=0"), o)

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:door-index-lock-sweep:" .. #failed .. "-failed", 1)
end
verdict.ok("door-index-lock-sweep", "8 arms")
