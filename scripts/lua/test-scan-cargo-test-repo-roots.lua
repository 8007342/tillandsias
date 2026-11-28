-- @env PATH HOME TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:2239-5gb5, order:2175-ctin
--
-- test-scan-cargo-test-repo-roots.lua — the feature-gated cargo test step's
-- declared inputs name the scripts its tests read OR EXECUTE, file by file, and
-- the scanner refuses a declaration that leaves one out.
--
-- 2239-5gb5 narrowed _CARGO_FEATURE_TEST_INPUTS from scripts/** to the exact
-- files (scripts/** came from one scratch-dir literal in a main.rs test helper,
-- so the 2175-ctin skip almost never fired). Narrowing turns a missed exec into
-- a silent coverage hole, so the scanner also counts any literal HOLDING a
-- scripts/ path ("bash scripts/x.sh", "$ROOT/scripts/x.sh", an env default),
-- in every scanned file. These arms pin both halves against a scratch copy of
-- build.sh, so the real tree is never written.
--   1 REAL      the real tree's declaration covers every scanned path -> ok
--   2 EXEC GAP  drop scripts/provider-limit-relay.sh (reached only through the
--               exec net: a message literal in provider_limit_relay.rs)
--               -> violation naming it
--   3 READ GAP  drop scripts/test-support/podman-mock.sh (an include path)
--               -> violation naming it
--   5 CLIPPY    the real _CARGO_CLIPPY_INPUTS covers the --compile-only scan (2440-8893)
--   6 INCLUDE   drop an include*! target from it -> violation naming it (the coordinator's mutant)
--   4 MUTANT    a scanner with the exec net removed passes arm 2's gap: arm 2
--               has teeth
--
-- Usage: tillandsias-plan script run scripts/lua/test-scan-cargo-test-repo-roots.lua
-- Verdict: ok:scan-cargo-test-repo-roots:4 | violation:scan-cargo-test-repo-roots:<n>-failed

local SCAN = "scripts/lua/scan-cargo-test-repo-roots.lua"
local VAR = "_CARGO_FEATURE_TEST_INPUTS"
local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN")
if PLAN == nil or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if PLAN == nil or PLAN == "" then
    verdict.emit("could-not-run:scan-cargo-test-repo-roots:no-plan-binary-named (set TILLANDSIAS_PLAN_BIN)", 3)
end

local pass, fail = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) out.line("FAIL: " .. m); fail = fail + 1 end

local REL = "target/plan-scratch/scan-roots-" .. tostring(time.now_ms())
fs.mkdir(REL)
local function run(scanner, buildsh, extra)
    local argv = { PLAN, "script", "run", scanner, "--", "--check" }
    if buildsh then argv[#argv + 1] = "--build-sh"; argv[#argv + 1] = buildsh end
    for _, x in ipairs(extra or {}) do argv[#argv + 1] = x end
    local r = proc.run({ argv = argv, env = { PATH = env.get("PATH"), HOME = env.get("HOME") }, timeout_ms = 300000 })
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
-- a copy of build.sh whose declaration lacks <entry>; asserts the entry was there
local function without(entry, name, var)
    local VAR = var or VAR
    local src = fs.read("build.sh") or ""
    local decl = src:match("\n" .. VAR .. '="([^"]*)"') or ""
    local kept, hit = {}, 0
    for t in decl:gmatch("%S+") do
        if t == entry then hit = hit + 1 else kept[#kept + 1] = t end
    end
    local s, e = src:find("\n" .. VAR .. '="[^"]*"')
    local p = REL .. "/" .. name
    fs.write(p, src:sub(1, s) .. VAR .. '="' .. table.concat(kept, " ") .. '"' .. src:sub(e + 1))
    return p, hit
end

-- 1
local rc, o = run(SCAN, nil)
if rc == 0 and o:find("ok:cargo-test-inputs:", 1, true) then ok("1 REAL the real declaration covers every scanned path")
else bad("1 REAL rc=" .. rc .. ": " .. o) end

-- 2
local EXEC = "path:scripts/provider-limit-relay.sh"
local p2, h2 = without(EXEC, "build-exec-gap.sh")
if h2 ~= 1 then bad("2 EXEC GAP premise: " .. EXEC .. " declared " .. h2 .. " times, want 1")
else
    rc, o = run(SCAN, p2)
    if rc == 1 and o:find("missing from " .. VAR .. ": " .. EXEC, 1, true) then
        ok("2 EXEC GAP a script reached only through a literal holding its path is required")
    else bad("2 EXEC GAP rc=" .. rc .. ": " .. o) end
end

-- 3
local READ = "path:scripts/test-support/podman-mock.sh"
local p3, h3 = without(READ, "build-read-gap.sh")
if h3 ~= 1 then bad("3 READ GAP premise: " .. READ .. " declared " .. h3 .. " times, want 1")
else
    rc, o = run(SCAN, p3)
    if rc == 1 and o:find("missing from " .. VAR .. ": " .. READ, 1, true) then
        ok("3 READ GAP an include path left out of the declaration is refused")
    else bad("3 READ GAP rc=" .. rc .. ": " .. o) end
end

-- 4: cut the exec-net loop out of a copy of the scanner
local body = fs.read(SCAN) or ""
local a = body:find('            for sp in lit:gmatch("scripts/', 1, true)
local mut = REL .. "/scan-no-exec-net.lua"
if not a then bad("4 MUTANT premise: the exec-net loop is not in " .. SCAN)
else
    local b = body:find("\n            end\n", a, true)
    fs.write(mut, body:sub(1, a - 1) .. body:sub(b + #"\n            end\n"))
    rc, o = run(mut, p2)
    if rc == 0 then ok("4 MUTANT without the exec net the exec gap passes — arm 2 has teeth")
    else bad("4 MUTANT the net-less scanner still refused (rc=" .. rc .. "): arm 2 proves nothing") end
end

-- 5-6 (2440-8893): the two clippy passes skip against _CARGO_CLIPPY_INPUTS, what COMPILES IN.
local CVAR, COMPILE = "_CARGO_CLIPPY_INPUTS", { "--workspace", "--compile-only", "--var", "_CARGO_CLIPPY_INPUTS" }
rc, o = run(SCAN, nil, COMPILE)
if rc == 0 and o:find("ok:cargo-test-inputs:", 1, true) then ok("5 REAL the clippy declaration covers every compile-time input")
else bad("5 REAL rc=" .. rc .. ": " .. o) end
-- the coordinator's mutant: an include_str! target the list leaves out must be refused
local INC = "path:scripts/build-image.sh"
local p6, h6 = without(INC, "build-include-gap.sh", CVAR)
if h6 ~= 1 then bad("6 INCLUDE GAP premise: " .. INC .. " declared " .. h6 .. " times in " .. CVAR .. ", want 1")
else
    rc, o = run(SCAN, p6, COMPILE)
    if rc == 1 and o:find("missing from " .. CVAR .. ": " .. INC, 1, true) then
        ok("6 INCLUDE GAP a compiled-in scripts/ file left out of the clippy list is refused")
    else bad("6 INCLUDE GAP rc=" .. rc .. ": " .. o) end
end

proc.run({ argv = { "rm", "-rf", REL }, timeout_ms = 60000 })
if fail == 0 then verdict.emit("ok:scan-cargo-test-repo-roots:" .. pass, 0) end
verdict.emit("violation:scan-cargo-test-repo-roots:" .. fail .. "-failed", 1)
