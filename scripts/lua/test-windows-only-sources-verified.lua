-- @env PATH HOME
-- @trace order:716-f5kc, order:738-3pft, order:801-ajcd, spec:windows-native-tray, order:2347-fqm2
--
-- test-windows-only-sources-verified.lua — scripts/lua/check-windows-only-sources-verified.lua says
-- whether a tray's Windows-only sources were compiled as they stand. A Linux build compiles STUBS
-- and goes green without reading the edited file. Ported from the .sh of the same name; every
-- verdict is reached on a throwaway tree.
--
--   1 never verified is a verdict              2 a stubless module is counted
--   3 stamping verifies                        4 an edit goes stale, by name
--   5 CONTROL a portable edit does not         6 no sources is said out loud
--   7 a stamp needs evidence                   8 the refusal's own argv is accepted
--   9 --from - reads stdin                     10 a tracked attestation crosses hosts
--   11 it dies on drift, not on other edits    12 MUTATION
--
-- Usage: tillandsias-plan script run scripts/lua/test-windows-only-sources-verified.lua
-- Verdict: ok:windows-only-sources-fixture:<n> arms | violation:windows-only-sources-fixture:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("windows-only-sources-fixture")
local PLAN, TOP = fixture.plan_binary(), fixture.repo_root()
local CHECK = "scripts/lua/check-windows-only-sources-verified.lua"
if not fs.exists(CHECK) then T:refuse("checker-missing", CHECK) end
if PLAN == "" then T:refuse("no-plan-binary") end

local MAIN = '#[cfg(target_os = "windows")]\nmod hvsocket;\n#[cfg(target_os = "windows")]\nmod wsl_lifecycle;\nmod portable_thing;\n\n'
    .. '#[cfg(not(target_os = "windows"))]\n#[path = "stubs/wsl_lifecycle.rs"]\nmod wsl_lifecycle;\n'
local W = T:git_repo("tree")
local SRC = W.rel .. "/crates/tillandsias-windows-tray/src"
fs.mkdir(SRC)
fs.write(SRC .. "/main.rs", MAIN)
local function reset() for _, m in ipairs{ "hvsocket", "wsl_lifecycle" } do fs.write(SRC .. "/" .. m .. ".rs", "// windows only\n") end end
reset()
fs.write(SRC .. "/portable_thing.rs", "// portable\n")
local function append(m, s) fs.write(SRC .. "/" .. m .. ".rs", fs.read(SRC .. "/" .. m .. ".rs") .. s) end

local state = T:scratch("state") -- one fresh stamp path per `fresh()`
local GREEN = "test some::thing ... ok\ntest result: ok. 1 passed; 0 failed\n"
local RED = "test a::b ... ok\ntest a::undeclared_red ... FAILED\n"
fs.write(state.rel .. "/green.txt", GREEN)
fs.write(state.rel .. "/red.txt", RED)
local green, red = state.abs .. "/green.txt", state.abs .. "/red.txt"
local stamp_n = 0
local function fresh() stamp_n = stamp_n + 1 end
fresh()
local function run(args, o)
    o = o or {}
    local argv = { PLAN, "script", "run", o.script or CHECK, "--" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run{ argv = argv, cwd = TOP, stdin = o.stdin, timeout_ms = 60000, env_unset = { "TILLANDSIAS_*" }, env = {
        WINDOWS_ONLY_ROOT = o.root or W.abs, WINDOWS_ONLY_STAMP = state.abs .. "/stamp" .. stamp_n,
        WINDOWS_ONLY_ATTEST_DIR = W.abs .. "/plan/attestations" } }
    return text.trim(r.stdout or ""), tostring(r.stderr)
end
local function arm(name, want, args, o)
    local got, err = run(args, o)
    T:arm(name, got == want, got .. (got == want and "" or " " .. err:sub(1, 300)))
end
local OK = "ok:sources-verified:windows-only:2"
local MISSING = "missing:sources-no-attestation:windows-only"
local DRIFT = "stale:sources-drifted:windows-only:1:crates/tillandsias-windows-tray/src/wsl_lifecycle.rs"
local function usage(name, args)
    local got = run(args)
    T:arm(name, got:find("refused:stamp-needs-evidence:usage: ", 1, true) == 1, got)
    return got
end

arm("1 never verified is a verdict", MISSING, { "check" })
arm("2/3 stamping counts both modules, stub or not", OK, { "stamp", "--from", green })
arm("3 a stamped tree verifies", OK, { "check" })
append("wsl_lifecycle", "// edited on a host that cannot compile it\n")
arm("4 an edit goes stale and is named", DRIFT, { "check" })
run{ "stamp", "--from", green }
append("portable_thing", "// portable edit\n")
arm("5 CONTROL a portable edit does not go stale", OK, { "check" })
arm("6 no sources skips by name", "skip:no-sources:windows-only", { "check" }, { root = T:scratch("empty").abs })

fresh()
local refusal = usage("7 a bare stamp refuses", { "stamp" })
arm("7 an undeclared red refuses and is named", "refused:undeclared-failure:undeclared_red", { "stamp", "--from", red })
fs.mkdir(W.rel .. "/scripts")
fs.write(W.rel .. "/scripts/windows-only-known-red.txt", "undeclared_red\n")
arm("7 a DECLARED red is tolerated", OK, { "stamp", "--from", red })
fs.write(W.rel .. "/scripts/windows-only-known-red.txt", "")

-- 801-ajcd: the argv is EXTRACTED from the refusal and executed, the one form that cannot drift.
local claimed, args8 = refusal:match("usage: %S+ ([^;]*)") or "", {}
for a in claimed:gsub(" <.*$", ""):gmatch("%S+") do args8[#args8 + 1] = a end
args8[#args8 + 1] = green
fresh()
arm("8 the refusal's own argv is accepted: " .. claimed, OK, args8)
fresh()
arm("8 the older 'stamp pass --from' is still answered", OK, { "stamp", "pass", "--from", green })
fresh()
usage("8 CONTROL 'stamp pass' alone still refuses", { "stamp", "pass" })
usage("8 CONTROL '--from' with no path still refuses", { "stamp", "--from" })
arm("9 --from - reads stdin", OK, { "stamp", "--from", "-" }, { stdin = GREEN })
fresh()
arm("9 CONTROL an evidence-free stdin refuses", "refused:stamp-needs-evidence:the transcript contains no test results",
    { "stamp", "--from", "-" }, { stdin = "no test results here\n" })

-- 738-3pft: no local stamp here, which stands for a different host; only the tracked file can pass.
arm("10 CONTROL with neither stamp nor attestation it is missing", MISSING, { "check" })
arm("10 attest writes", "ok:sources-attested:windows-only:2", { "attest", "--host", "windows", "--from", green })
local ap = W.rel .. "/plan/attestations/windows-only-sources.windows.json"
local body = fs.exists(ap) and fs.read(ap) or ""
for _, f in ipairs{ '"scope": "windows-only"', '"host": "windows"', '"command":' } do
    T:arm("10 the attestation records " .. f, text.contains(body, f), body)
end
arm("10 it verifies with no local stamp", OK, { "check" })
append("wsl_lifecycle", "// edited after the attestation was written\n")
arm("11 a moved source is stale and named", DRIFT, { "check" })

-- MUTATION, while the source has moved.
local src = fs.read(CHECK):gsub("\r\n", "\n")
local function mutant(name, from, to)
    local a, b = src:find(from, 1, true)
    if not a then T:refuse("mutation-anchor-missing", name) end
    fs.write(state.rel .. "/" .. name .. ".lua", src:sub(1, a - 1) .. to .. src:sub(b + 1))
    return { script = state.abs .. "/" .. name .. ".lua" }
end
arm("12 MUTATION a check that does not compare hashes calls the moved source verified", OK, { "check" },
    mutant("nocompare", "want == blob_hash(f)", "true"))
arm("12 MUTATION a stamp that ignores the known-red list takes the red", OK, { "stamp", "--from", red },
    mutant("nored", "not kr[name]", "false"))

run{ "attest", "--host", "windows", "--from", green }
append("portable_thing", "// another portable edit\n")
arm("11 a portable edit does not drift the attestation", OK, { "check" })

T:finish()
