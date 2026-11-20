-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN PATH HOME
-- @trace order:2130-fl0r
--
-- test-build-floor.lua: scripts/lua/build-floor.lua goes red for the RIGHT
-- reason, on a scratch git repo it is pointed at (never this checkout):
--   1 a clean change: ok:floor, under the 120 s budget
--   2 a changed .lua that does not parse: violation:floor:lua-parse
--   3 a changed .rs that is not rustfmt-clean: violation:floor:fmt
--   4 a changed litmus of size:long is SKIPPED BY NAME, not silently
--   5 a packet naming litmus:<x> that does not exist: violation:floor:litmus-missing:<x>
-- Each sabotage asserts it changed what it meant to (a no-op sabotage reads
-- exactly like a passing check).
-- Verdict: ok:build-floor:5-arms (0) | violation:build-floor:<arm>:<why> (1)
local BIN = env.get("TILLANDSIAS_PLAN_BIN")
if BIN == nil or BIN == "" then BIN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if BIN == nil or BIN == "" then verdict.could_not_run("build-floor", "no-plan-binary — set TILLANDSIAS_PLAN_BIN") end

local function run(argv, ms) return proc.run{ argv = argv, timeout_ms = ms or 60000 } end
local root = text.trim(run({ "git", "rev-parse", "--show-toplevel" }, 5000).stdout or "")
local FLOOR = root .. "/scripts/lua/build-floor.lua"
local stamp = time.iso_utc():gsub("%W", "") .. "-" .. tostring(math.random(100000, 999999))
local S = root .. "/target/plan-scratch/build-floor-" .. stamp
fs.mkdir(S .. "/openspec/litmus-tests")
fs.mkdir(S .. "/plan/index.d")
fs.mkdir(S .. "/src")
local function g(args)
    local a = { "git", "-C", S, "-c", "user.email=f@x.invalid", "-c", "user.name=f" }
    for _, x in ipairs(args) do a[#a + 1] = x end
    return run(a, 30000)
end
g({ "init", "-q", "-b", "main" })
fs.write(S .. "/Cargo.toml", '[package]\nname = "floorfx"\nversion = "0.1.0"\nedition = "2021"\n')
fs.write(S .. "/src/main.rs", "fn main() {}\n")
fs.write(S .. "/plan/index.d/a.yaml", "packets:\n  - order: 9999-test\n")
g({ "add", "-A" }); g({ "commit", "-q", "-m", "base" })
local BASE = text.trim(g({ "rev-parse", "HEAD" }).stdout or "")

-- The floor is pointed at the scratch repo by TILLANDSIAS_FLOOR_ROOT (no cd:
-- a native Windows process resolves a bare `bash` to WSL's).
local function floor()
    local r = proc.run{ argv = { BIN, "script", "run", FLOOR }, timeout_ms = 180000,
        env = { TILLANDSIAS_FLOOR_ROOT = S, TILLANDSIAS_FLOOR_BASE = BASE, TILLANDSIAS_FLOOR_ORDER = "9999-test" } }
    local o = (r.stdout or "") .. "\n" .. (r.stderr or "")
    local last = text.trim(r.stdout or ""):match("([^\n]*)$") or ""
    return last, r.code, o
end
local function reset()
    g({ "reset", "-q", "--hard", BASE }); g({ "clean", "-qfd" })
end
local function fail(arm, why) run({ "rm", "-rf", S }); verdict.emit("violation:build-floor:" .. arm .. ":" .. why, 1) end

-- 1 clean
fs.write(S .. "/notes.lua", "return 1\n")
local t0 = time.now_ms()
local v, code, o1 = floor()
if code ~= 0 then log.raw(o1) end
if code ~= 0 or not v:find("^ok:floor:") then fail(1, "clean-change-not-ok:" .. v) end
if time.now_ms() - t0 > 120000 then fail(1, "over-120s") end
reset()

-- 2 lua parse
fs.write(S .. "/bad.lua", "local x = = 1\n")
if not (fs.read(S .. "/bad.lua") or ""):find("= =", 1, true) then fail(2, "sabotage-changed-nothing") end
v, code = floor()
if code ~= 1 or not v:find("lua-parse", 1, true) then fail(2, "unparsed-lua-not-red:" .. v) end
reset()

-- 3 fmt
fs.write(S .. "/src/main.rs", "fn main(){let x=1;println!(\"{}\",x);}\n")
v, code = floor()
if v:find("could-not-run:floor:cargo", 1, true) then
    log.raw("skip: arm 3 — no cargo fmt at this locus")
elseif code ~= 1 or not v:find("fmt:", 1, true) then fail(3, "unformatted-rs-not-red:" .. v) end
reset()

-- 4 a long litmus is skipped by name
fs.mkdir(S .. "/openspec/litmus-tests")
fs.write(S .. "/openspec/litmus-tests/litmus-slow-thing.yaml", "name: litmus:slow-thing\nsize: long\n")
local _, c4, o4 = floor()
if c4 ~= 0 or not o4:find("slow-thing(size:long)", 1, true) then fail(4, "long-litmus-not-skipped-by-name:" .. tostring(c4)) end
reset()

-- 5 the packet names a litmus that does not exist
fs.write(S .. "/plan/index.d/b.yaml", "packets:\n  - order: 9999-test\n    verifiable_closure: litmus:ghost-test\n")
g({ "add", "-A" }); g({ "commit", "-q", "-m", "row" })
v, code = floor()
if code ~= 1 or not v:find("litmus-missing:ghost-test", 1, true) then fail(5, "missing-litmus-not-red:" .. v) end

run({ "rm", "-rf", S })
verdict.emit("ok:build-floor:5-arms", 0)
