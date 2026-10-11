-- @trace order:1614-5x7m
-- @env PATH
--
-- test-preflight-wall-clock-deadline.lua — the preflight door's deadline and
-- grace are judged by the WALL CLOCK, not by counting polls (1614-5x7m).
--
-- MEASURED on darwin under taskpolicy -b (2026-10-11): 50 polls of `sleep 0.1`
-- took 12.8 s (5.5 s plain), because background QoS coalesces timers. The door
-- counted 50 polls as its 5 s deadline, so every guard reaching it ran ~13 s and
-- `./build.sh --preflight` walled 466-567 s against the front door's 150 s.
--
-- build.sh's _pf_now and _pf_run_guard are EXTRACTED at run time, not copied,
-- and run against a planted guard that ignores TERM (`trap '' TERM; exec sleep
-- 60`, one process, so the KILL ends it) under a 2 s deadline. The bound is
-- deadline + grace + 1 s = 4 s by wall clock. The PRE-FIX door is the same
-- function with _pf_now replaced by a counter that advances 0.1 s per read,
-- which is exactly the old semantics: every poll counted as a tenth.
--   1 POST       plain: rc 124, killed within 1-4 s
--   2 PRE-FIX    slow polls (a `sleep` shim that sleeps 0.2 s for any tick, the
--                coalescing constructed, so every host shows it): overruns 4 s
--   3 POST       the same slow polls: still within 4 s
--   4 PRE-FIX    under taskpolicy -b (the regime itself, darwin): overruns 4 s
--   5 POST       under taskpolicy -b: within 4 s
--   6 CLOCK      _pf_now names the clock bash can give without a fork: wall-us
--                on bash >= 5 (EPOCHREALTIME), wall-s otherwise ($SECONDS);
--                and the door's summary carries deadline-clock=
-- Arms 4 and 5 need taskpolicy; without it they are NAMED as not run, and the
-- verdict says so rather than counting them.
--
-- Usage: tillandsias-plan script run scripts/lua/test-preflight-wall-clock-deadline.lua

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("preflight-wall-clock-deadline", "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/wall-clock-deadline-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL .. "/shim")

local failed = {}
local function arm(name, cond, got)
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
local now_fn, guard_fn = extract(build, "_pf_now"), extract(build, "_pf_run_guard")
if now_fn == "" or guard_fn == "" then
    verdict.emit("violation:preflight-wall-clock-deadline:no-subject", 1,
        "build.sh has no _pf_now or no _pf_run_guard to extract (1614-5x7m)")
end
-- The sweep is 1600-nn5b's and has its own fixture; a no-op keeps it out of
-- this one's timing.
local stubs = "_pf_sweep_guard_tmp() { :; }\n"
fs.write(REL .. "/door-post.sh", stubs .. now_fn .. "\n" .. guard_fn .. "\n")
fs.write(REL .. "/door-pre.sh", stubs .. guard_fn .. "\n" ..
    "_pf_now() { _PF_N=$(( ${_PF_N:-0} + 100000 )); _PF_NOW=$_PF_N; _PF_CLOCK=ticks; }\n")

-- The harness resolves the real sleep BEFORE any shim, so the planted guard
-- really sleeps 60 s whatever PATH the door sees.
fs.write(REL .. "/harness.sh", table.concat({
    "set -u",
    "FN=\"$1\"; REAL_SLEEP=\"$(command -v sleep)\"; export REAL_SLEEP",
    "[ -z \"${SHIM:-}\" ] || PATH=\"$SHIM:$PATH\"",
    "SCRIPT_DIR=\"$(mktemp -d \"${TMPDIR:-/tmp}/wall-clock.XXXXXX\")\"",
    ". \"$FN\"",
    "G=\"$SCRIPT_DIR/plant.sh\"",
    "printf '%s\\n' \"trap '' TERM\" \"exec '$REAL_SLEEP' 60\" > \"$G\"",
    -- The kill is timed around the call alone, not the harness's startup;
    -- two perl reads, not one per poll. No perl: the caller's wall stands.
    "ms() { perl -MTime::HiRes=time -e 'printf \"%d\", time*1000' 2>/dev/null; }",
    "a=$(ms); rc=0; _pf_run_guard \"$G\" 2 \"$SCRIPT_DIR/out\" \"\" || rc=$?; b=$(ms)",
    "[ -z \"$a\" ] || [ -z \"$b\" ] || echo \"door_ms=$((b - a))\"",
    "echo \"rc=$rc\"",
    "rm -rf \"$SCRIPT_DIR\"",
    "",
}, "\n"))
-- The runner refuses inline shell strings (no-shell-strings), so lookups are
-- script files, and the shim finds the real sleep through the harness's export.
fs.write(REL .. "/shim/sleep", "#!/bin/sh\nexec \"$REAL_SLEEP\" 0.2\n")
proc.run({ argv = { "chmod", "+x", ROOT .. "/" .. REL .. "/shim/sleep" }, timeout_ms = 10000 })

local BOUND_MS = 4000
local function door(which, opts)
    local argv = { "bash", ROOT .. "/" .. REL .. "/harness.sh", ROOT .. "/" .. REL .. "/door-" .. which .. ".sh" }
    if opts.bg then table.insert(argv, 1, "-b"); table.insert(argv, 1, "taskpolicy") end
    local t0 = time.now_ms()
    local r = proc.run({ argv = argv, env = opts.slow and { SHIM = ROOT .. "/" .. REL .. "/shim" } or {},
        cwd = ROOT, timeout_ms = 60000 })
    local ms = time.now_ms() - t0
    local said = text.trim(r.stdout or "")
    local door_ms = tonumber(said:match("door_ms=(%d+)") or "")
    local how = door_ms and ("door=" .. door_ms .. "ms (run " .. ms .. "ms)") or ("wall=" .. ms .. "ms (no perl: whole run)")
    return said:find("rc=124", 1, true) ~= nil, door_ms or ms, said:match("rc=%d+") .. " " .. how
end

local k, ms, got = door("post", {})
arm("1 POST plain: killed within 1-" .. BOUND_MS .. " ms", k and ms >= 1000 and ms <= BOUND_MS, got)
k, ms, got = door("pre", { slow = true })
arm("2 PRE-FIX slow polls: the poll-counting door overruns " .. BOUND_MS .. " ms (the defect)", k and ms > BOUND_MS, got)
k, ms, got = door("post", { slow = true })
arm("3 POST slow polls: still killed within " .. BOUND_MS .. " ms", k and ms <= BOUND_MS, got)

local NOTE = ""
fs.write(REL .. "/has-taskpolicy.sh", "command -v taskpolicy\n")
local tp = proc.run({ argv = { "bash", ROOT .. "/" .. REL .. "/has-taskpolicy.sh" }, timeout_ms = 10000 })
if tp.status == "exited" and tp.code == 0 then
    k, ms, got = door("pre", { bg = true })
    arm("4 PRE-FIX under taskpolicy -b: the poll-counting door overruns " .. BOUND_MS .. " ms (the defect)", k and ms > BOUND_MS, got)
    k, ms, got = door("post", { bg = true })
    arm("5 POST under taskpolicy -b: killed within " .. BOUND_MS .. " ms", k and ms <= BOUND_MS, got)
else
    NOTE = "; arms 4-5 not run: no taskpolicy on this host"
    out.line("not run: 4-5 the taskpolicy -b regime arms (no taskpolicy on this host)")
end

fs.write(REL .. "/clock.sh", now_fn .. "\n_pf_now; echo \"$_PF_CLOCK ${BASH_VERSINFO[0]}\"\n")
local c = text.trim(proc.run({ argv = { "bash", ROOT .. "/" .. REL .. "/clock.sh" }, timeout_ms = 10000 }).stdout or "")
local clock, major = c:match("^(%S+) (%d+)$")
local want = (tonumber(major or "0") >= 5) and "wall-us" or "wall-s"
arm("6 CLOCK _pf_now names the fork-free clock for this bash, and the summary carries deadline-clock=",
    clock == want and build:find('_pf_iso="$_pf_iso deadline-clock=$_PF_CLOCK"', 1, true) ~= nil,
    "bash " .. tostring(major) .. " clock=" .. tostring(clock) .. " want=" .. want)

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:preflight-wall-clock-deadline:" .. #failed .. "-failed", 1)
end
verdict.ok("preflight-wall-clock-deadline", (NOTE == "" and "6 arms" or "4 arms" .. NOTE))
