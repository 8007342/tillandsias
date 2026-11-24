-- @trace order:1523-rxt6, order:2182-flrp, spec:ci-release
-- @env PATH HOME USER XDG_RUNTIME_DIR TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-release-preflight-latest-read-bounded.lua — release-preflight.sh's
-- stable-vs-latest check reads the latest release tag ANONYMOUSLY and BOUNDED,
-- so a host whose login keyring is locked cannot stall it. It used `gh api`,
-- which waits ~120 s on a locked keyring (lenovinha 120,422 ms, macuahuitl
-- 127 s, 2026-10-01) and timed out litmus release-gates-run-locally STEP 1.
-- Ported from the .sh of the same name (order 2182-flrp); same two arms.
--
-- Arms:
--   1 BOUNDED   gh and curl both stubbed to sleep 300 s: the script finishes in
--               under 40 s, names the read as could-not-run, and never calls gh
--   2 READS     curl stubbed to return {"tag_name":"v0.0.0.fixture"}: the tag
--               reaches the comparison (the "no peeled tag" note names it).
--               Needs origin reachable for refs/tags/stable; a named skip if not.
--
-- PRE-FIX: arm 1 FAILS — the script calls the gh stub and is still running at
-- the 40 s bound.
--
-- Usage: tillandsias-plan script run scripts/lua/test-release-preflight-latest-read-bounded.lua
-- Verdicts:
--   ok:release-preflight-latest-read-bounded:<p>-passed             exit 0
--   violation:release-preflight-latest-read-bounded:<f>-failed      exit 1
--   could-not-run:release-preflight-latest-read-bounded:no-plan-binary  exit 3

local NAME = "release-preflight-latest-read-bounded"
local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN")
if PLAN == nil or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
local BASE = { PATH = env.get("PATH"), HOME = env.get("HOME"), USER = env.get("USER"), XDG_RUNTIME_DIR = env.get("XDG_RUNTIME_DIR") }
if PLAN == nil or PLAN == "" then
    -- The runner names itself in neither variable when called by hand. The
    -- .sh asked plan-binary-probe.sh, but proc.run denies `sh -c`; the probe's
    -- answer on a host is the binary on PATH.
    -- release-preflight.sh needs it ABSOLUTE (it tests -x), so walk PATH.
    for dir in (BASE.PATH or ""):gmatch("[^:]+") do
        local cand = dir .. "/tillandsias-plan"
        if dir:sub(1, 1) == "/" and proc.run({ argv = { "test", "-x", cand }, env = BASE }).code == 0 then PLAN = cand; break end
    end
end
if PLAN == nil or PLAN == "" then
    verdict.emit("could-not-run:" .. NAME .. ":no-plan-binary — cargo build --release -p tillandsias-plan", 3)
end
local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, env = BASE }).stdout or "")
local function run(argv, path_prefix, ms)
    local e = {}
    for k, v in pairs(BASE) do e[k] = v end
    if path_prefix then e.PATH = path_prefix .. ":" .. BASE.PATH end
    e.TILLANDSIAS_PLAN_BIN = PLAN
    return proc.run({ argv = argv, env = e, timeout_ms = ms or 120000 })
end

local REL = "target/plan-scratch/relpf-latest." .. tostring(time.now_ms())
local W = ROOT .. "/" .. REL
fs.mkdir(REL .. "/bin1")
fs.mkdir(REL .. "/bin2")
local function cleanup() proc.run({ argv = { "rm", "-rf", W }, env = BASE }) end
local pass, fail = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) out.line("FAIL: " .. m); fail = fail + 1 end

-- ── ARM 1: BOUNDED ─────────────────────────────────────────────────────────
fs.write(REL .. "/bin1/gh", "#!/usr/bin/env bash\ntouch \"" .. W .. "/gh-called\"\nsleep 300\n")
fs.write(REL .. "/bin1/curl", "#!/usr/bin/env bash\nsleep 300\n")
-- 2278-zhqb: release-preflight also calls `tillandsias --cloud-usage` (its own 120 s cap)
-- where that binary is on PATH, which put 12-14 s of another read inside this arm on yoga
-- and none on darwin. It is not this arm's subject, so every host runs a stub that
-- answers at once, and the arm proves the stub is what ran.
fs.write(REL .. "/bin1/tillandsias", "#!/usr/bin/env bash\ntouch \"" .. W .. "/usage-stubbed\"\nexit 1\n")
proc.run({ argv = { "chmod", "+x", W .. "/bin1/tillandsias" }, env = BASE })
proc.run({ argv = { "chmod", "+x", W .. "/bin1/gh", W .. "/bin1/curl" }, env = BASE })
local t0 = time.now_ms()
local r1 = run({ PLAN, "run", "--timeout-ms", "40000", "--", "bash", "scripts/release-preflight.sh", "--verbose" }, W .. "/bin1")
local took = math.floor((time.now_ms() - t0) / 1000)
local out1 = (r1.stdout or "") .. (r1.stderr or "")
local a1 = ""
if r1.code == 124 then a1 = a1 .. " still running at the 40 s bound (rc=124);" end
if fs.exists(REL .. "/gh-called") then a1 = a1 .. " gh was called;" end
if not fs.exists(REL .. "/usage-stubbed") then a1 = a1 .. " the cloud-usage read was not the stub;" end
if not (text.contains(out1, "stable-vs-latest: could not read refs/tags/stable") or text.contains(out1, "bounded read timed out")) then
    a1 = a1 .. " no could-not-run note for the latest read;"
end
if a1 == "" then ok("ARM 1: a hung gh and curl cannot stall it (" .. took .. "s, gh never called)")
else bad("ARM 1:" .. a1 .. " took=" .. took .. "s") end

-- ── ARM 2: READS ───────────────────────────────────────────────────────────
fs.write(REL .. "/bin2/curl", "#!/usr/bin/env bash\nprintf %s '{\"tag_name\":\"v0.0.0.fixture\"}'\n")
proc.run({ argv = { "chmod", "+x", W .. "/bin2/curl" }, env = BASE })
local r2 = run({ PLAN, "run", "--timeout-ms", "60000", "--", "bash", "scripts/release-preflight.sh", "--verbose" }, W .. "/bin2")
local out2 = (r2.stdout or "") .. (r2.stderr or "")
if text.contains(out2, "could not read refs/tags/stable") then
    out.line("skip: ARM 2 — origin unreachable for refs/tags/stable, so the latest read is never asked")
elseif text.contains(out2, "no peeled tag for v0.0.0.fixture") then
    ok("ARM 2: the anonymous read's tag reaches the stable-vs-latest comparison")
else
    local seen = {}
    for _, l in ipairs(text.lines(out2)) do if text.contains(l, "stable-vs-latest") and #seen < 2 then seen[#seen + 1] = l end end
    bad("ARM 2: the stubbed tag never reached the comparison: " .. table.concat(seen, " "))
end

cleanup()
out.line(NAME .. ": " .. pass .. " passed, " .. fail .. " failed")
if fail > 0 then verdict.emit("violation:" .. NAME .. ":" .. fail .. "-failed", 1) end
verdict.ok(NAME, pass .. "-passed")
