-- @trace order:795-vq6b, spec:host-guest-transport
-- @env TILLANDSIAS_TEST_FILE
--
-- PORTED from scripts/test-exec-transcript-capped-in-every-driver.sh (1804-sccl
-- carry: shell-to-lua). Every place an exec driver in
-- crates/tillandsias-vm-layer/src/vsock_exec.rs ACCUMULATES guest output into a
-- transcript passes it through the one cap policy (retain_tail / trim_transcript)
-- within the next 12 lines. 690-eug2 capped one driver; a sibling kept an
-- unbounded Vec<u8>, so the next divergence is made loud mechanically.
--   1 at least 2 accumulators are found (vacuity floor)
--   2 each accumulator is followed within 12 lines by retain_tail( or trim_transcript(
-- TILLANDSIAS_TEST_FILE points the scan at another file (the mutation arm).

local F = env.get("TILLANDSIAS_TEST_FILE")
if not F or F == "" then F = "crates/tillandsias-vm-layer/src/vsock_exec.rs" end
local ok, src = pcall(fs.read, F)
if not ok or not src then verdict.emit("could-not-run:exec-transcript-capped:unreadable:" .. F, 3) end

local lines = text.lines(src)
local stop = #lines + 1
for i, l in ipairs(lines) do
    if l:find("^#%[cfg%(test%)%]") then stop = i; break end
end

local acc = {}
for i = 1, stop - 1 do
    if lines[i]:find("stdout.extend_from_slice(", 1, true) then acc[#acc + 1] = i end
end

local bad = {}
for _, a in ipairs(acc) do
    local capped = false
    for j = a, math.min(a + 12, stop - 1) do
        if lines[j]:find("retain_tail(", 1, true) or lines[j]:find("trim_transcript(", 1, true) then
            capped = true
            break
        end
    end
    if not capped then bad[#bad + 1] = tostring(a) end
end

if #acc < 2 then
    out.line("FAIL: 1: found " .. #acc .. " accumulators (want >= 2); the scan no longer sees the drivers")
    verdict.emit("refused:exec-transcript-capped:vacuous", 1)
end
out.line("ok:   1: " .. #acc .. " transcript accumulators found")
if #bad > 0 then
    out.line("FAIL: 2: uncapped transcript accumulator(s) at vsock_exec.rs line(s): " .. table.concat(bad, " "))
    verdict.emit("refused:exec-transcript-capped:uncapped", 1)
end
out.line("ok:   2: every accumulator passes through the cap policy")
verdict.emit("ok:exec-transcript-capped-in-every-driver", 0)
