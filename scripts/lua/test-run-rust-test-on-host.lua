-- @trace order:2215-beb5, order:1242-4x53, spec:methodology-accountability
-- @env TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-run-rust-test-on-host.lua — pins scripts/lua/run-rust-test-on-host.lua,
-- local-ci.sh's rust-test runner and its same-regime re-run (2215-beb5). It
-- replaces test-rerun-failed-rust-tests.sh, whose arms are kept (5, 6, 7, 9,
-- 10 below), and adds the REGIME arms the port exists for. Hermetic: the
-- "cargo" is a stub that records the argv and environment it was given; no arm
-- compiles anything. The runner is the real plan binary, run as a subprocess
-- so each arm sets its own environment.
--
--   1 run: a failing stub → violation, rc named, the pass-through list in the
--     verdict, and the regime file written
--   2 run: the child really RECEIVED the pass-through values and the 880-tdwn
--     tripwire (TILLANDSIAS_PODMAN_REFUSE_REAL=1) — a list in a verdict that
--     never reached the child would be decoration
--   3 REGIME: CARGO_TARGET_DIR differs on the re-run → refused by name, and the
--     stub was NOT run
--   4 REGIME: RUSTFLAGS differs on the re-run → refused by name
--   5 NEGATIVE CONTROL: same regime, the test fails again → reproduced=yes
--     (a re-run mechanism is one bug away from absorbing every red as noise)
--   6 same regime, the test passes → reproduced=no
--   7 the re-run names exactly the FAILED tests, sorted, after `-- --exact`,
--     behind the caller's own argv
--   8 a passing run → ok, pass-through list in the verdict
--   9 no FAILED names → skip, nothing re-run
--  10 an unreadable log → skip, nothing re-run
--  11 no recorded regime → could-not-run, nothing re-run
--
-- Verdict: ok:run-rust-test-on-host:11 arms | violation:run-rust-test-on-host:<n> failed

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local failn = 0
local function ok(m) out.line("ok:   " .. m) end
local function bad(m) out.line("FAIL: " .. m); failn = failn + 1 end
local function has(s, p) return (s or ""):find(p, 1, true) ~= nil end

local stamp = tostring(time.now_ms())
local rel = "target/plan-scratch/run-rust-test-" .. stamp
local W = root .. "/" .. rel
proc.run{ argv = { "mkdir", "-p", W } }
local REGIME_NAME = "fixture-" .. stamp
local REGIME = "target/plan-scratch/rust-test-regime-" .. REGIME_NAME .. ".env"
local function cleanup()
    proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 }
    proc.run{ argv = { "find", root .. "/target/plan-scratch", "-maxdepth", "1",
        "-name", "rust-test-regime-" .. REGIME_NAME .. ".env", "-delete" } }
end

local RUNNER = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or ""
if RUNNER == "" then
    fs.write(rel .. "/resolve.sh", ". scripts/plan-binary-probe.sh && resolve_plan_binary\n")
    RUNNER = text.trim(proc.run{ argv = { "bash", W .. "/resolve.sh" } }.stdout or "")
    if RUNNER:sub(1, 2) == "./" then RUNNER = root .. "/" .. RUNNER:sub(3) end
end
if RUNNER == "" then cleanup(); verdict.could_not_run("run-rust-test-on-host:no-runner") end

-- The stub "cargo": records argv and the regime it was handed, then exits by mode.
local REC = W .. "/rec"
fs.write(rel .. "/stub", '#!/usr/bin/env bash\n'
    .. '{ printf "argv=%s\\n" "$*"; printf "ctd=%s\\n" "${CARGO_TARGET_DIR-<unset>}"; '
    .. 'printf "rustflags=%s\\n" "${RUSTFLAGS-<unset>}"; printf "refuse=%s\\n" "${TILLANDSIAS_PODMAN_REFUSE_REAL-<unset>}"; } > "' .. REC .. '"\n'
    .. 'case "${TILLANDSIAS_STUB_MODE:-green}" in red) exit 101 ;; *) exit 0 ;; esac\n')
proc.run{ argv = { "chmod", "+x", W .. "/stub" } }
local function rec() return fs.exists(rel .. "/rec") and (fs.read(rel .. "/rec") or "") or "" end
local function clear_rec() proc.run{ argv = { "find", W, "-maxdepth", "1", "-name", "rec", "-delete" } } end

-- A cargo test log: two failures (one listed twice), one pass, noise that must not parse.
fs.write(rel .. "/red.log", "running 3 tests\n"
    .. "test groundtruth::tests::the_spec_engine_stamps_the_index_frame_not_the_readers_head ... FAILED\n"
    .. "test fold::tests::keeps_order ... ok\n"
    .. "test fold::tests::drops_tombstones ... FAILED\n"
    .. "failures:\n    fold::tests::drops_tombstones\n"
    .. "test fold::tests::drops_tombstones ... FAILED\n"
    .. "test result: FAILED. 1 passed; 2 failed\n")
fs.write(rel .. "/compile.log", "error[E0433]: cannot find module\n")

-- One subprocess of the runner, with this arm's environment.
local function runner(args, e)
    local a = { RUNNER, "script", "run", root .. "/scripts/lua/run-rust-test-on-host.lua", "--" }
    for _, x in ipairs(args) do a[#a + 1] = x end
    local r = proc.run{ argv = a, env = e, timeout_ms = 120000 }
    return r.stdout or "", r.stderr or "", r.code
end
local BASE = { CARGO_TARGET_DIR = "/tmp/ctd-A", RUSTFLAGS = "-Dwarnings" }
local function with(over)
    local e = {}
    for k, v in pairs(BASE) do e[k] = v end
    for k, v in pairs(over or {}) do e[k] = v end
    return e
end
local STUBARGV = { W .. "/stub", "env", "SEAT=1", "cargo", "test" }
local function run_args(mode, log)
    local a = { mode, "--regime", REGIME_NAME }
    if log then a[#a + 1] = log end
    a[#a + 1] = "--"
    for _, x in ipairs(STUBARGV) do a[#a + 1] = x end
    return a
end

-- ── 1 & 2: a failing run records the regime and hands it to the child ─────
clear_rec()
local o, e, rc = runner(run_args("run"), with({ TILLANDSIAS_STUB_MODE = "red" }))
if rc == 1 and has(o, "violation:rust-test-on-host:rc=101 pass-through=CARGO_TARGET_DIR,RUSTFLAGS,")
    and fs.exists(REGIME) and has(fs.read(REGIME), "CARGO_TARGET_DIR=/tmp/ctd-A") then
    ok("1 a failing run is a violation naming the rc, with the pass-through list in the verdict and the regime recorded")
else bad("1 rc=" .. tostring(rc) .. " out=[" .. o:gsub("\n", "|") .. "]") end
local r = rec()
if has(r, "ctd=/tmp/ctd-A") and has(r, "rustflags=-Dwarnings") and has(r, "refuse=1") then
    ok("2 the child received the pass-through values and TILLANDSIAS_PODMAN_REFUSE_REAL=1")
else bad("2 the child was handed: [" .. r:gsub("\n", "|") .. "]") end

-- ── 3: REGIME — CARGO_TARGET_DIR differs → refused, nothing re-run ────────
clear_rec()
o, e, rc = runner(run_args("rerun", W .. "/red.log"), with({ CARGO_TARGET_DIR = "/tmp/ctd-B", TILLANDSIAS_STUB_MODE = "red" }))
if rc == 1 and has(o, "refused:rust-test-rerun:regime-differs:CARGO_TARGET_DIR") and rec() == "" then
    ok("3 a re-run whose CARGO_TARGET_DIR differs is refused by name, and nothing is re-run")
else bad("3 rc=" .. tostring(rc) .. " out=[" .. o:gsub("\n", "|") .. "] re-ran=" .. (rec() ~= "" and "yes" or "no")) end

-- ── 4: REGIME — RUSTFLAGS differs → refused by name ───────────────────────
clear_rec()
o, e, rc = runner(run_args("rerun", W .. "/red.log"), with({ RUSTFLAGS = "-Copt-level=0", TILLANDSIAS_STUB_MODE = "red" }))
if rc == 1 and has(o, "refused:rust-test-rerun:regime-differs:RUSTFLAGS") and rec() == "" then
    ok("4 a re-run whose RUSTFLAGS differs is refused by name, and nothing is re-run")
else bad("4 rc=" .. tostring(rc) .. " out=[" .. o:gsub("\n", "|") .. "]") end

-- ── 5: NEGATIVE CONTROL — same regime, fails again → reproduced=yes ───────
clear_rec()
o, e, rc = runner(run_args("rerun", W .. "/red.log"), with({ TILLANDSIAS_STUB_MODE = "red" }))
if rc == 0 and has(o, "ok:rust-test-rerun:reproduced=yes") then
    ok("5 a failure that fails again in the same regime is reproduced=yes (not absorbed as noise)")
else bad("5 rc=" .. tostring(rc) .. " out=[" .. o:gsub("\n", "|") .. "]") end

-- ── 7: the re-run's argv ──────────────────────────────────────────────────
local want = "argv=env SEAT=1 cargo test -- --exact fold::tests::drops_tombstones "
    .. "groundtruth::tests::the_spec_engine_stamps_the_index_frame_not_the_readers_head"
if has(rec(), want .. "\n") then ok("7 the re-run names exactly the FAILED tests, sorted and once each, behind the caller's argv")
else bad("7 re-run " .. rec():gsub("\n", "|")) end

-- ── 6: same regime, passes → reproduced=no ────────────────────────────────
o, e, rc = runner(run_args("rerun", W .. "/red.log"), with({ TILLANDSIAS_STUB_MODE = "green" }))
if rc == 0 and has(o, "ok:rust-test-rerun:reproduced=no") then ok("6 a failure that passes on the same-regime re-run is reproduced=no")
else bad("6 rc=" .. tostring(rc) .. " out=[" .. o:gsub("\n", "|") .. "]") end

-- ── 8: a passing run ──────────────────────────────────────────────────────
o, e, rc = runner(run_args("run"), with({ TILLANDSIAS_STUB_MODE = "green" }))
if rc == 0 and has(o, "ok:rust-test-on-host:pass pass-through=CARGO_TARGET_DIR,") then
    ok("8 a passing run is ok, with the pass-through list in the verdict")
else bad("8 rc=" .. tostring(rc) .. " out=[" .. o:gsub("\n", "|") .. "]") end

-- ── 9: no FAILED names → skip, nothing re-run ─────────────────────────────
clear_rec()
o, e, rc = runner(run_args("rerun", W .. "/compile.log"), with({ TILLANDSIAS_STUB_MODE = "red" }))
if rc == 0 and has(o, "skip:rust-test-rerun:no-failed-names") and rec() == "" then
    ok("9 a log with no FAILED names (a compile error) re-runs nothing and gives no answer")
else bad("9 rc=" .. tostring(rc) .. " out=[" .. o:gsub("\n", "|") .. "]") end

-- ── 10: an unreadable log → skip ──────────────────────────────────────────
o, e, rc = runner(run_args("rerun", W .. "/missing.log"), with({ TILLANDSIAS_STUB_MODE = "red" }))
if rc == 0 and has(o, "skip:rust-test-rerun:no-log") and rec() == "" then
    ok("10 an unreadable log is not an error for the caller: skip, nothing re-run")
else bad("10 rc=" .. tostring(rc) .. " out=[" .. o:gsub("\n", "|") .. "]") end

-- ── 11: no recorded regime → could-not-run ────────────────────────────────
proc.run{ argv = { "find", root .. "/target/plan-scratch", "-maxdepth", "1",
    "-name", "rust-test-regime-" .. REGIME_NAME .. ".env", "-delete" } }
o, e, rc = runner(run_args("rerun", W .. "/red.log"), with({ TILLANDSIAS_STUB_MODE = "red" }))
if rc == 3 and has(o, "could-not-run:rust-test-rerun:no-recorded-regime") and rec() == "" then
    ok("11 with no recorded regime the re-run cannot be called same-regime: could-not-run, nothing re-run")
else bad("11 rc=" .. tostring(rc) .. " out=[" .. o:gsub("\n", "|") .. "]") end

cleanup()
if failn == 0 then verdict.ok("run-rust-test-on-host:11 arms") end
verdict.emit("violation:run-rust-test-on-host:" .. failn .. " failed", 1)
