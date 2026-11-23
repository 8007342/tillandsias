-- @env PATH HOME TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:2243-urcy
--
-- test-nextest-transcript-ratchet.lua — when the gate runs nextest, the
-- failure-set ratchet (scripts/check-test-baseline.sh) still catches a NEW
-- failure. The gate rewrites nextest's log with scripts/lua/nextest-to-libtest.lua
-- into the cargo test transcript the ratchet parses; a converter that dropped or
-- mislabelled a FAIL would turn every new red into a green gate, silently.
--   1 GREEN     an all-PASS nextest log converts and the ratchet says ok
--   2 RED FIRST the same log with ONE test failing -> the ratchet refuses with
--               new-red=1 naming that test's key (lib, bin and integration ids)
--   3 KEYS      nextest ids map to cargo's binary stems: crate -> crate_name,
--               crate::bin/x -> x, crate::target -> target; a FAIL repeated in
--               nextest's closing summary counts once
--   4 MUTANT    a converter that reports FAIL as ok lets arm 2's red through:
--               arm 2 has teeth
--   5 REGIME    build.sh names its runner on every path (nextest, absent, forced)
--
-- Usage: tillandsias-plan script run scripts/lua/test-nextest-transcript-ratchet.lua
-- Verdict: ok:nextest-transcript-ratchet:5 | violation:nextest-transcript-ratchet:<n>-failed

local CONV = "scripts/lua/nextest-to-libtest.lua"
local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN")
if PLAN == nil or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if PLAN == nil or PLAN == "" then
    verdict.emit("could-not-run:nextest-transcript-ratchet:no-plan-binary-named (set TILLANDSIAS_PLAN_BIN)", 3)
end
local pass, fail = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) out.line("FAIL: " .. m); fail = fail + 1 end

local root = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 }).stdout or "")
local REL = "target/plan-scratch/nextest-ratchet-" .. tostring(time.now_ms())
fs.mkdir(REL)
local E = { PATH = env.get("PATH"), HOME = env.get("HOME") }

local function log(lines) return table.concat(lines, "\n") .. "\n" end
local GREEN = {
    "    Starting 3 tests across 3 binaries",
    "        PASS [   0.004s] (1/3) tillandsias-plan fragments::tests::a_lib_test",
    "        PASS [   0.010s] (2/3) tillandsias-headless::bin/tillandsias tray::tests::a_bin_test",
    "        PASS [   1.200s] (3/3) tillandsias-plan::lua_proc an_integration_test",
    "────────────",
    "     Summary [   1.300s] 3 tests run: 3 passed, 0 skipped",
}
local RED = {
    "    Starting 3 tests across 3 binaries",
    "        PASS [   0.004s] (1/3) tillandsias-plan fragments::tests::a_lib_test",
    "        FAIL [   0.010s] (2/3) tillandsias-headless::bin/tillandsias tray::tests::a_bin_test",
    "        PASS [   1.200s] (3/3) tillandsias-plan::lua_proc an_integration_test",
    "────────────",
    "     Summary [   1.300s] 3 tests run: 2 passed, 1 failed, 0 skipped",
    "        FAIL [   0.010s] (2/3) tillandsias-headless::bin/tillandsias tray::tests::a_bin_test",
}
fs.write(REL .. "/green.log", log(GREEN))
fs.write(REL .. "/red.log", log(RED))
fs.write(REL .. "/known-red.txt", "# empty: nothing tolerated\n")

local function convert(conv, src, dst)
    local r = proc.run({ argv = { PLAN, "script", "run", "--helper", conv, "--", src }, env = E, timeout_ms = 60000 })
    fs.write(dst, r.stdout or "")
    return r.code, r.stdout or ""
end
local function ratchet(transcript)
    local r = proc.run({ argv = { "bash", root .. "/scripts/check-test-baseline.sh", "--from", root .. "/" .. transcript,
        "--list", root .. "/" .. REL .. "/known-red.txt" }, env = E, timeout_ms = 60000 })
    return r.code, text.trim((r.stdout or "") .. (r.stderr or ""))
end

-- 1
local c1 = convert(CONV, REL .. "/green.log", REL .. "/green.txt")
local rc, o = ratchet(REL .. "/green.txt")
if c1 == 0 and rc == 0 and o:find("ok:test-baseline:ran=3 new-red=0", 1, true) then ok("1 GREEN an all-PASS nextest log ratchets ok (ran=3)")
else bad("1 GREEN convert rc=" .. c1 .. " ratchet rc=" .. rc .. ": " .. o) end

-- 2
local c2, red = convert(CONV, REL .. "/red.log", REL .. "/red.txt")
rc, o = ratchet(REL .. "/red.txt")
if c2 == 0 and rc ~= 0 and o:find("new-red=1", 1, true) and o:find("tillandsias::tray::tests::a_bin_test", 1, true) then
    ok("2 RED FIRST one failing test under nextest is a new red the ratchet names")
else bad("2 RED FIRST convert rc=" .. c2 .. " ratchet rc=" .. rc .. ": " .. o) end

-- 3
local want = {
    "     Running tillandsias_plan (target/debug/deps/tillandsias_plan-0)",
    "test fragments::tests::a_lib_test ... ok",
    "     Running tillandsias (target/debug/deps/tillandsias-0)",
    "test tray::tests::a_bin_test ... FAILED",
    "     Running lua_proc (target/debug/deps/lua_proc-0)",
    "test an_integration_test ... ok",
}
if (red:gsub("%s+$", "")) == table.concat(want, "\n") then ok("3 KEYS lib/bin/integration ids map to cargo stems; the summary's repeated FAIL counts once")
else bad("3 KEYS got:\n" .. red) end

-- 4
local src = fs.read(CONV) or ""
local mut = REL .. "/conv-fail-as-ok.lua"
local cut = 'local res = (status == "PASS") and "ok" or "FAILED"'
if not src:find(cut, 1, true) then bad("4 MUTANT premise: the result mapping line is not in " .. CONV)
else
    fs.write(mut, (src:gsub(cut:gsub("%p", "%%%0"), 'local res = "ok"', 1)))
    convert(mut, REL .. "/red.log", REL .. "/red-mut.txt")
    rc, o = ratchet(REL .. "/red-mut.txt")
    if rc == 0 then ok("4 MUTANT a converter reporting FAIL as ok passes the red — arm 2 has teeth")
    else bad("4 MUTANT the mutant still refused (rc=" .. rc .. "): arm 2 proves nothing: " .. o) end
end

-- 5
local b = fs.read("build.sh") or ""
local miss = {}
for _, w in ipairs({ "test-runner:nextest:", "test-runner:cargo-test:nextest-absent", "test-runner:cargo-test:forced-by-TILLANDSIAS_GATE_NEXTEST=0" }) do
    if not b:find(w, 1, true) then miss[#miss + 1] = w end
end
if #miss == 0 then ok("5 REGIME build.sh names its runner on every path")
else bad("5 REGIME build.sh lacks: " .. table.concat(miss, ", ")) end

proc.run({ argv = { "rm", "-rf", root .. "/" .. REL }, timeout_ms = 60000 })
if fail == 0 then verdict.emit("ok:nextest-transcript-ratchet:" .. pass, 0) end
verdict.emit("violation:nextest-transcript-ratchet:" .. fail .. "-failed", 1)
