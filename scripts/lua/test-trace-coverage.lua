-- @trace gap:OBS-004, spec:spec-trace-coverage-threshold, order:1077-vzwq, order:1069-c9w6, order:2367-d5gx
--
-- test-trace-coverage.lua — scripts/validate-traces.sh --coverage-threshold. Every arm about the
-- VALIDATOR runs on a synthetic root, one spec traced of two (50%), so no arm pins a coverage floor on
-- this checkout. The one live arm uses threshold 0 and a relation: the denominator is the number of
-- spec directories. Ported from the .sh of the same name.
--
-- The trace marker for a synthetic spec is assembled, never written: a literal one is a ghost trace.
--
-- Usage: tillandsias-plan script run scripts/lua/test-trace-coverage.lua
-- Verdict: ok:trace-coverage:<n> arms | violation:trace-coverage:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("trace-coverage")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local SUBJECT = "scripts/validate-traces.sh"
if not fs.exists(SUBJECT) then T:refuse("subject-missing") end
local src = fs.read(SUBJECT):gsub("\r\n", "\n")
local MARK = "@" .. "trace " .. "spec" .. ":"

-- Every search root the validator greps exists: a missing one answers "uncovered" by grep's error path.
local function synth(tag, body)
    local d = T:scratch(tag)
    for _, p in ipairs{ "scripts", "crates", "images", "methodology", "openspec/specs/covered-spec", "openspec/specs/uncovered-spec" } do
        fs.mkdir(d.rel .. "/" .. p)
    end
    fs.write(d.rel .. "/root.sh", "")
    fs.write(d.rel .. "/scripts/validate-traces.sh", body)
    fs.write(d.rel .. "/openspec/specs/covered-spec/spec.md", "# spec\n")
    fs.write(d.rel .. "/openspec/specs/uncovered-spec/spec.md", "# spec\n")
    fs.write(d.rel .. "/scripts/traced.sh", "# " .. MARK .. "covered-spec\n")
    return d.abs
end
local S = synth("synth", src)
local function coverage(threshold, root)
    local argv = { SH, (root or S) .. "/scripts/validate-traces.sh", "--coverage-threshold", threshold }
    argv.cwd, argv.env_unset, argv.timeout_ms = root or S, { "TILLANDSIAS_*" }, 300000
    local r = T:run(argv)
    local ok, j = pcall(json.parse, r.stdout or "")
    return r.code, (r.stdout or "") .. (r.stderr or ""), ok and type(j) == "table" and j or {}
end

local rc, o, j = coverage("0")
T:arm("0 the synthetic tree is one traced of two", j.coverage_percentage == 50 and j.total_active_specs == 2 and j.specs_with_traces == 1, o)
T:arm("1 threshold 0 is accepted", rc == 0, o)
local function invalid(name, t)
    rc, o = coverage(t)
    T:arm(name, rc == 1 and text.contains(o, "Invalid threshold: " .. t), "rc=" .. tostring(rc) .. " " .. o)
end
invalid("2 a negative threshold is refused as invalid", "-1")
invalid("2 a threshold over 100 is refused as invalid", "101")
invalid("2 a non-number is refused as invalid", "abc")
rc, o, j = coverage("50")
T:arm("3 a met threshold is PASS and exits 0", rc == 0 and j.status == "PASS", "rc=" .. tostring(rc) .. " " .. o)
rc, o, j = coverage(nil)
T:arm("4 the default threshold is 90", j.threshold == 90, o)
rc, o, j = coverage("90")
T:arm("5 below the threshold exits exactly 1", rc == 1, "rc=" .. tostring(rc))
local function listing(s)
    local t = "\n" .. s
    return t:find("\n%s*%-%s*uncovered%-spec%s*\n") ~= nil and not t:find("\n%s*%-%s*covered%-spec%s*\n")
        and text.contains(t, "Action: Add " .. MARK .. "uncovered-spec")
end
T:arm("5 and names the uncovered spec, not the covered one, to the end", listing(o), o)

-- 6 the only live arm.
rc, o, j = coverage("0", ROOT)
local on_disk = tonumber(text.trim(T:must{ SH, "-s", cwd = ROOT,
    stdin = "find openspec/specs -mindepth 1 -maxdepth 1 -type d | wc -l\n" }.stdout)) or 0
T:arm("6 on this checkout it completes and its denominator is the spec directories", rc == 0 and on_disk > 0
    and j.total_active_specs == on_disk and j.coverage_percentage ~= nil, "on disk " .. on_disk .. " rc=" .. tostring(rc) .. " " .. o:sub(1, 400))

-- MUTATION
local function mutant(name, from, to)
    local a, b = src:find(from, 1, true)
    if not a then T:refuse("mutation-anchor-missing", name) end
    return synth(name, src:sub(1, a - 1) .. to .. src:sub(b + 1))
end
rc, o = coverage("101", mutant("norange", "|| [[ $COVERAGE_THRESHOLD -lt 0 || $COVERAGE_THRESHOLD -gt 100 ]]", ""))
T:arm("7 MUTATION without the range check 101 fails as low coverage, unnamed", rc == 1 and not text.contains(o, "Invalid threshold"), o)
rc, o = coverage("90", mutant("nolist", 'UNCOVERED_SPECS+=("$spec_name")', 'UNCOVERED_SPECS+=("covered-spec")'))
T:arm("7 MUTATION a listing that names the wrong spec fails arm 5", not listing(o), o)

T:finish()
