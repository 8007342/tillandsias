-- @trace spec:init-command, order:1276-2hc6, order:2080-8i25
-- @env TILLANDSIAS_HEADLESS_SRC OS
-- test-windows-host-lane-refusal.lua (ported from the .sh, shell-to-lua batch
-- "windows 1"). Pin 1276-2hc6: the Windows headless launcher REFUSES --init on
-- arrival and names the tray, instead of entering a lane that cannot work and
-- failing eight image builds downstream (operator transcript, esme 2026-09-19).
--
-- EVERY SCAN STRIPS COMMENTS FIRST: the doc comment above the fixed function
-- carries the refusal wording and the function's name, so a scan that reads
-- comments passes on a tree where only the prose remains.
-- TILLANDSIAS_HEADLESS_SRC points the arms at a SABOTAGED copy
-- (test-windows-host-lane-refusal-controls.lua) to show them go red.
--
-- Lines: "ok: …" / "FAIL: …" per arm, then ok:windows-host-lane-refusal:all
-- (exit 0) or violation:windows-host-lane-refusal:<n>-failed (exit 1).
local SRC = env.get("TILLANDSIAS_HEADLESS_SRC")
if SRC == nil or SRC == "" then SRC = "crates/tillandsias-headless/src/main.rs" end
if not fs.exists(SRC) then verdict.emit("blocked:windows-host-lane-refusal:no-source:" .. SRC, 1) end

local lines = {}
for _, l in ipairs(text.lines(fs.read(SRC))) do lines[#lines + 1] = (l:gsub("//.*$", "")) end
local code = table.concat(lines, "\n")

local failures = 0
local function ok(m) log.raw("ok: " .. m) end
local function fail(m) log.raw("FAIL: " .. m); failures = failures + 1 end
local function first_after(start, needle)
    for i = start + 1, #lines do
        if lines[i]:find(needle, 1, true) then return i end
    end
    return nil
end

-- ARM 1: THE ORDER. A refusal after lane selection still enters the lane.
local run_init
for i, l in ipairs(lines) do
    if l:find("^fn run_init") then run_init = i; break end
end
if not run_init then
    fail("no 'fn run_init' in " .. SRC .. " — the function this row is about is gone or renamed")
else
    local refusal = first_after(run_init, "windows_host_lane_refusal()")
    if not refusal then
        fail("run_init does not call windows_host_lane_refusal() at all (pre-fix state)")
    else
        for _, nm in ipairs({ "require_desktop_user_session", "report_runtime_lane" }) do
            local ln = first_after(run_init, nm .. "(")
            if not ln then
                ok(nm .. " is absent from run_init — nothing for the refusal to precede")
            elseif refusal < ln then
                ok("the refusal (line " .. refusal .. ") precedes " .. nm .. " (line " .. ln .. ")")
            else
                fail("the refusal (line " .. refusal .. ") comes AFTER " .. nm .. " (line " .. ln .. ") — the lane is entered before refusing")
            end
        end
    end
end

-- ARM 2: CARDINALITY. Exactly two cfg-gated definitions, both arms present.
local function count_lines(pred)
    local c = 0
    for _, l in ipairs(lines) do if pred(l) then c = c + 1 end end
    return c
end
local defs = count_lines(function(l) return l:find("^fn windows_host_lane_refusal") ~= nil end)
local win = count_lines(function(l) return l:find('#[cfg(target_os = "windows")]', 1, true) ~= nil end)
local notwin = count_lines(function(l) return l:find('#[cfg(not(target_os = "windows"))]', 1, true) ~= nil end)
if defs == 2 then ok("windows_host_lane_refusal has exactly 2 cfg-gated definitions")
else fail("expected 2 definitions of windows_host_lane_refusal, found " .. defs) end
if win >= 1 and notwin >= 1 then ok("both a windows and a not(windows) cfg arm are present")
else fail("missing a cfg arm (windows=" .. win .. " not-windows=" .. notwin .. ")") end

-- ARM 3: THE REFUSAL NAMES THE WORKING COMMAND.
if text.contains(code, "refused:windows-host-lane") then ok("the refusal carries its grammar token refused:windows-host-lane")
else fail("no refused:windows-host-lane token in code (comments stripped)") end
if text.contains(code, "tillandsias-tray.exe --provision-once") then
    ok("the refusal names the working command (tillandsias-tray.exe --provision-once)")
else fail("the refusal does not name tillandsias-tray.exe --provision-once") end

-- ARM 4: NEGATIVE CONTROL. The not(windows) arm returns None, or Linux --init
-- would refuse too and the fleet's own gate would stop.
local none_arm, f, g = false, false, false
for _, l in ipairs(lines) do
    if l:find('#[cfg(not(target_os = "windows"))]', 1, true) then f = true end
    if f and l:find("^fn windows_host_lane_refusal") then g = true end
    if g and l:find("None", 1, true) then none_arm = true; break end
end
if none_arm then ok("the not(windows) arm returns None (Linux keeps its lane)")
else fail("the not(windows) arm does not return None") end

-- ARM 5: BEHAVIOURAL, Windows only, skipped BY NAME elsewhere so a green run
-- off Windows cannot be read as a behavioural pass. The bin is `tillandsias`,
-- not its crate name: that name is the defect's own subject.
if env.get("OS") == "Windows_NT" then
    local bin
    for _, c in ipairs({ "target/release/tillandsias.exe", "target/debug/tillandsias.exe" }) do
        if fs.exists(c) then bin = c; break end
    end
    if not bin then
        log.raw("skip: behavioural arm — no native tillandsias.exe built at this locus")
    else
        local r = proc.run({ argv = { bin, "--init" }, timeout_ms = 60000 })
        local out = (r.stdout or "") .. "\n" .. (r.stderr or "")
        if r.code == 0 then fail("BEHAVIOURAL: --init exited 0 on a Windows host; it must refuse")
        else ok("BEHAVIOURAL: --init exited non-zero (" .. tostring(r.code) .. ")") end
        if text.contains(out, "refused:windows-host-lane") then ok("BEHAVIOURAL: the refusal is printed")
        else fail("BEHAVIOURAL: no refusal in output: " .. out) end
        if text.contains(out, "tillandsias-tray.exe --provision-once") then ok("BEHAVIOURAL: the working command is named")
        else fail("BEHAVIOURAL: the output does not name the tray command") end
        local builds = 0
        for _, l in ipairs(text.lines(out)) do
            local lo = l:lower()
            if lo:find("building image", 1, true) or lo:find("failed to spawn build", 1, true) then builds = builds + 1 end
        end
        if builds == 0 then ok("BEHAVIOURAL: no image-build lines (pre-fix: eight)")
        else fail("BEHAVIOURAL: " .. builds .. " image-build line(s) — the lane was entered") end
    end
else
    log.raw('skip: behavioural arm — not a Windows locus (the refusal is #[cfg(target_os = "windows")])')
end

if failures == 0 then verdict.emit("ok:windows-host-lane-refusal:all", 0) end
verdict.emit("violation:windows-host-lane-refusal:" .. failures .. "-failed", 1)
