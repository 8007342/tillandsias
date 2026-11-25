-- @env PATH HOME
-- @trace order:861-n7f5, order:2199-luab, order:2301-4bgh
--
-- test-check-engine-cpu-dispatch.lua — pin the 861-n7f5 grammar and the one verdict that
-- matters: a BASELINE build on a VECTOR host is refused, not quietly benchmarked. Ported
-- from the .sh of the same name (2301-4bgh); same nine arms.
--
-- Hermetic: the engine output is a file (ENGINE_DISPATCH_SYSINFO_FILE) and the host feature
-- set is stubbed (ENGINE_DISPATCH_HOST_FLAGS). No engine, model, network or capability row.
--
-- Usage: tillandsias-plan script run scripts/lua/test-check-engine-cpu-dispatch.lua
-- Verdict: ok:check-engine-cpu-dispatch:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("check-engine-cpu-dispatch")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
local d = T:scratch()

-- What llama.cpp prints, verbatim in shape, so a format change breaks this test.
local BASELINE = "system_info: n_threads = 4 (n_threads_batch = 4) / 4 | CPU : LLAMAFILE = 1 | REPACK = 1 |"
local DISPATCHED = "system_info: n_threads = 4 (n_threads_batch = 4) / 4 | CPU : LLAMAFILE = 1 | AVX = 1 | AVX2 = 1 | FMA = 1 | AVX_VNNI = 1 | REPACK = 1 |"
local NO_TABLE = "version: 6153 (b6153-3.fc44) built with gcc 15.2.1"
local ALL = "avx,avx2,fma,avx_vnni"

local function guard(flags, stub, engine)
    local argv = { PLAN, "script", "run", "scripts/lua/check-engine-cpu-dispatch.lua", "--" }
    if engine then argv[#argv + 1] = engine end
    fs.write(d.rel .. "/sysinfo", stub)
    local r = proc.run{ argv = argv, cwd = ROOT, timeout_ms = 60000, env = {
        PATH = env.get("PATH"), HOME = env.get("HOME"),
        ENGINE_DISPATCH_HOST_FLAGS = flags, ENGINE_DISPATCH_SYSINFO_FILE = d.abs .. "/sysinfo" } }
    return tostring(r.code) .. "|" .. (r.stdout or ""):gsub("\r", ""):gsub("\n+$", "")
end
local function expect(label, want, flags, stub)
    local got = guard(flags, stub, "/nonexistent-engine")
    T:arm(label, got == want, "want [" .. want .. "] got [" .. got .. "]")
end

-- THE MEASURED INCIDENT: Fedora's baseline build on the host's real flags.
expect("1 a baseline build on a vector host is refused", "1|refused:engine-cpu-dispatch-baseline:" .. ALL, ALL, BASELINE)
expect("2 a fully dispatched build passes", "0|ok:engine-cpu-dispatch:" .. ALL, ALL, DISPATCHED)
-- "Mostly dispatched" is not a verdict.
expect("3 a partly dispatched build names only the gap", "1|refused:engine-cpu-dispatch-baseline:avx_vnni", ALL,
    "system_info: CPU : AVX = 1 | AVX2 = 1 | FMA = 1 | AVX_VNNI = 0 | REPACK = 1 |")
-- NEGATIVE CONTROL: the only build such a host can run must not be banned.
expect("4 a baseline build on a baseline host passes", "0|ok:engine-cpu-dispatch:none", "sse2", BASELINE)
expect("5 a build ahead of the host's row is not refused", "0|ok:engine-cpu-dispatch:" .. ALL, "avx,avx2", DISPATCHED)
-- UNREADABLE IS NOT PASSING (the order-531 shape), and neither is silence.
expect("6 no dispatch table is unavailable, never ok", "2|unavailable:no-dispatch-table", ALL, NO_TABLE)
expect("7 an engine that emits nothing is unavailable", "2|unavailable:engine-emitted-nothing", ALL, "")

local function grammatical(v)
    return v:find("^ok:engine%-cpu%-dispatch:[a-z0-9_,-]+$") ~= nil
        or v:find("^refused:engine%-cpu%-dispatch%-baseline:[a-z0-9_,-]+$") ~= nil
        or v:find("^unavailable:[a-z0-9-]+$") ~= nil
end
local off = {}
for _, stub in ipairs{ BASELINE, DISPATCHED, NO_TABLE, "" } do
    local v = guard(ALL, stub, "/nonexistent-engine"):gsub("^[^|]*|", "")
    if not grammatical(v) then off[#off + 1] = "[" .. v .. "]" end
end
T:arm("8 every verdict matches the pinned grammar", #off == 0, table.concat(off, " "))

local got = guard(ALL, DISPATCHED, nil)
T:arm("9 a missing engine argument is unavailable", got == "2|unavailable:no-engine-given", got)
T:finish()
