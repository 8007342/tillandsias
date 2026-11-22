-- @trace order:1337-7jr5, order:2219-27uv
-- @env TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-gate-memory-wsl2-guest.lua — PORTED from test-gate-memory-wsl2-guest.sh
-- (2219-27uv), same arms, same lines. Inside a WSL2 guest, /proc/meminfo is
-- the utility VM's memory, not the Windows host's that reaps the gate, so the
-- gate memory floor must not print ok:gate-memory from it (measured on yolanda
-- 2026-09-21: guest ok at 5578MB while the host was at 28.7%, and at 10.8%
-- earlier that hour).
--
-- REGIME: hermetic. The kernel identity comes through the
-- TILLANDSIAS_GATE_MEMORY_OSRELEASE seam and the host figure through
-- --meminfo-from, so every arm runs the same on Linux, WSL2, MSYS and macOS.
--
--   1  WSL2 guest, default read -> could-not-run:...wsl2-guest-meminfo-is-not-the-host,
--      last line skip:, rc 3, and NO ok:gate-memory line
--   2  WSL2 guest, host figure via --meminfo-from (healthy) -> judged: ok, rc 0
--   3  WSL2 guest, host figure via --meminfo-from (starved) -> still REFUSED, rc 1
--   4  native kernel, default read -> the WSL2 refusal does not appear
--
-- 2167-gmfl: the decider is scripts/lua/check-gate-memory-floor.lua (the .sh is
-- only its bootstrap), so these arms judge the Lua itself, through the runner,
-- and a missing runner REFUSES: a skip here would be a permanent green over the
-- WSL2 rule.
--
-- Verdict: ok:gate-memory-wsl2-guest:<p>/<n> | violation:gate-memory-wsl2-guest:<p>/<n>

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local FLOOR = root .. "/scripts/lua/check-gate-memory-floor.lua"
if not fs.exists("scripts/lua/check-gate-memory-floor.lua") then
    verdict.refused("gate-memory-wsl2-guest:absent:" .. FLOOR)
end

local rel = "target/plan-scratch/gate-memory-wsl2-" .. tostring(time.now_ms())
local W = root .. "/" .. rel
proc.run{ argv = { "mkdir", "-p", W } }
local function cleanup() proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 } end

local PLAN_BIN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or ""
if PLAN_BIN == "" then
    fs.write(rel .. "/resolve.sh", ". scripts/plan-binary-probe.sh 2>/dev/null && resolve_plan_binary 2>/dev/null\n")
    PLAN_BIN = text.trim(proc.run{ argv = { "bash", W .. "/resolve.sh" } }.stdout or "")
    if PLAN_BIN:sub(1, 2) == "./" then PLAN_BIN = root .. "/" .. PLAN_BIN:sub(3) end
end
local caps = PLAN_BIN ~= "" and (proc.run{ argv = { PLAN_BIN, "capabilities" } }.stdout or "") or ""
local has_script = false
for _, l in ipairs(text.lines(caps)) do if l == "script" then has_script = true end end
if not has_script then
    cleanup()
    verdict.refused("gate-memory-wsl2-guest:no-plan-binary (build one: cargo build --release -p tillandsias-plan)")
end

local pass, fail = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) out.line("FAIL: " .. m); fail = fail + 1 end

fs.write(rel .. "/wsl2", "5.15.167.4-microsoft-standard-WSL2\n")
fs.write(rel .. "/native", "6.10.0-100.fc40.x86_64\n")
fs.write(rel .. "/healthy", "MemTotal:       16000000 kB\nMemAvailable:    8000000 kB\n")
fs.write(rel .. "/starved", "MemTotal:       16000000 kB\nMemAvailable:     200000 kB\n")

-- The decider's stdout (the .sh discarded its stderr), trailing newlines
-- stripped as `$(...)` does, and its rc.
local function floor_run(osrelease, args)
    local a = { PLAN_BIN, "script", "run", FLOOR, "--" }
    for _, x in ipairs(args or {}) do a[#a + 1] = x end
    local r = proc.run{ argv = a, env = { TILLANDSIAS_GATE_MEMORY_OSRELEASE = osrelease }, timeout_ms = 120000 }
    return ((r.stdout or ""):gsub("\n+$", "")), r.code
end
local function last_nonblank(s)
    local last = ""
    for _, l in ipairs(text.lines(s)) do if l:match("%S") then last = l end end
    return last
end
local function has(s, p) return s:find(p, 1, true) ~= nil end
local function starts(s, p) return s:sub(1, #p) == p end

-- 1
local o, rc = floor_run(W .. "/wsl2")
local last = last_nonblank(o)
if has(o, "ok:gate-memory") then
    bad("arm 1: a WSL2 guest asserted ok from its own meminfo (rc=" .. tostring(rc) .. "): " .. o)
elseif has(o, "could-not-run:gate-memory:wsl2-guest-meminfo-is-not-the-host") then
    if rc == 3 and last:sub(1, 5) == "skip:" then
        ok("arm 1: a WSL2 guest refuses to assert (rc=3, last line " .. last .. ")")
    else
        bad("arm 1: named the refusal but rc=" .. tostring(rc) .. " / last line [" .. last .. "] (want rc 3 and a skip: last line)")
    end
else
    bad("arm 1: no WSL2 refusal (rc=" .. tostring(rc) .. "): " .. o)
end

-- 2
o, rc = floor_run(W .. "/wsl2", { "--meminfo-from", W .. "/healthy" })
if rc == 0 and starts(o, "ok:gate-memory:") then
    ok("arm 2: a host figure passed in is judged normally (ok, rc=0)")
else bad("arm 2: host figure via --meminfo-from not judged (rc=" .. tostring(rc) .. "): " .. o) end

-- 3
o, rc = floor_run(W .. "/wsl2", { "--meminfo-from", W .. "/starved" })
if rc == 1 and starts(o, "refused:gate:insufficient-memory") then
    ok("arm 3: a starved host figure is still refused (rc=1)")
else bad("arm 3: starved host figure not refused (rc=" .. tostring(rc) .. "): " .. o) end

-- 4
o, rc = floor_run(W .. "/native")
if has(o, "wsl2-guest") then
    bad("arm 4: a native kernel was treated as a WSL2 guest (rc=" .. tostring(rc) .. "): " .. o)
else
    ok("arm 4: a native kernel is not refused as WSL2 (rc=" .. tostring(rc) .. ", " .. (text.lines(o)[1] or ""):sub(1, 60) .. ")")
end

cleanup()
local total = pass + fail
if fail == 0 then verdict.emit("ok:gate-memory-wsl2-guest:" .. pass .. "/" .. total, 0) end
verdict.emit("violation:gate-memory-wsl2-guest:" .. pass .. "/" .. total, 1)
