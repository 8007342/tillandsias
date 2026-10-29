-- @trace order:1916-dvlp, order:1804-sccl
--
-- test-build-sccache-regimes.lua — build.sh's sccache block (between the
-- BEGIN-SCCACHE / END-SCCACHE markers) splits the two regimes:
--   DEV   CARGO_INCREMENTAL=1: no RUSTC_WRAPPER (sccache refuses an
--         incremental unit: "incremental compilation is prohibited"), and the
--         dev loop builds headless with assets-from-source (1916-embd);
--   GATE  CARGO_INCREMENTAL=0 or unset: the sccache wrapper is set, as before.
-- The block runs extracted, under a fake sccache on PATH, so no build runs and
-- no VERSION is bumped.
--
-- Usage: tillandsias-plan script run scripts/lua/test-build-sccache-regimes.lua

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 30000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
if ROOT == "" then verdict.could_not_run("build-sccache-regimes", "not inside a git checkout") end
local ok_read, src = pcall(fs.read, ROOT .. "/build.sh")
if not ok_read then verdict.could_not_run("build-sccache-regimes", "build.sh unreadable") end
local block = src:match("# BEGIN%-SCCACHE\n(.-)# END%-SCCACHE")
if not block then
    verdict.emit("violation:build-sccache-regimes:no-markers", 1, "build.sh has no BEGIN-SCCACHE/END-SCCACHE block")
end

local REL = "target/plan-scratch/sccache-regimes-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL
fs.mkdir(REL .. "/bin")
fs.write(REL .. "/bin/sccache", "#!/bin/sh\nexit 0\n")
run({ "chmod", "+x", W .. "/bin/sccache" })
fs.write(REL .. "/block.sh", "SCRIPT_DIR=" .. ROOT .. "\n" .. block ..
    '\necho "wrapper=${RUSTC_WRAPPER:-}"\necho "features=${TILLANDSIAS_DEV_BUILD_FEATURES:-}"\n')

local passed, failed = 0, 0
local function check(name, cond, why)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else failed = failed + 1; out.line("FAIL: " .. name .. " — " .. why) end
end
local function regime(incr)
    local e = { PATH = W .. "/bin:/usr/bin:/bin", HOME = W }
    if incr then e.CARGO_INCREMENTAL = incr end
    local r = run({ "bash", W .. "/block.sh" }, { env = e })
    return (r.stdout or "") .. (r.stderr or "")
end

local dev = regime("1")
check("DEV CARGO_INCREMENTAL=1 sets no RUSTC_WRAPPER", dev:find("wrapper=\n", 1, true) ~= nil, dev)
check("DEV says why sccache is off", dev:find("sccache: off (CARGO_INCREMENTAL=1", 1, true) ~= nil, dev)
check("DEV builds headless with assets-from-source",
    dev:find("features=--features tillandsias-headless/assets-from-source", 1, true) ~= nil, dev)
local gate = regime("0")
check("GATE CARGO_INCREMENTAL=0 keeps the sccache wrapper",
    gate:find("wrapper=" .. ROOT .. "/scripts/sccache-wrapper.sh", 1, true) ~= nil, gate)
check("GATE embeds its assets", gate:find("features=\n", 1, true) ~= nil, gate)
local unset = regime(nil)
check("UNSET keeps the sccache wrapper (the gate default)",
    unset:find("wrapper=" .. ROOT .. "/scripts/sccache-wrapper.sh", 1, true) ~= nil, unset)

run({ "rm", "-rf", W })
if failed > 0 then verdict.emit("refused:build-sccache-regimes:" .. passed .. "/" .. (passed + failed), 1) end
verdict.emit("ok:build-sccache-regimes:" .. passed .. " arms", 0)
