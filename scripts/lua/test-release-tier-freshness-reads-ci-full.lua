-- @env PATH HOME TMPDIR TOOLBOX_PATH container TILLANDSIAS_SKIP_TOOLBOX TILLANDSIAS_SKIP_WSL2
-- @trace order:1185-9qx6, order:2409-qbgu, spec:ci-release
--
-- test-release-tier-freshness-reads-ci-full.lua — pin the WRITER/READER contract that 1185-9qx6 closed. Ported from
-- test-release-tier-freshness-reads-ci-full.sh (2409-qbgu).
--
-- THE DEFECT. scripts/lua/check-release-tier-freshness.lua demands a FULL-tier run (1174-6r4k): ci_phase `all`, or
-- pre-build AND post-build AND runtime between one run's records. Nothing could produce that: local-ci.sh is the
-- index's only writer and ci-full drives only its pre-build phase through it. Measured on macuahuitl 2026-09-14: a
-- green ci-full, and all 245 records the index had ever held were pre-build.
--
-- Hermetic: every arm writes a throwaway index in a scratch dir and points the recorder and the guard at it with
-- TILLANDSIAS_CHECK_LOG_INDEX. This checkout's own index is never read or written.
--
-- THE ARM THAT MATTERS IS THE NEGATIVE CONTROL (arm 2): a phase-only run must STILL read as not-a-release-tier-answer.
--
-- Usage: tillandsias-plan script run scripts/lua/test-release-tier-freshness-reads-ci-full.lua
-- Verdict: ok:release-tier-ci-full:<n> | violation:release-tier-ci-full:<n> | skip:release-tier-ci-full:<why> (exit 3)

local fixture = require "common.fixture"
local T = fixture.new("release-tier-ci-full")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
local GUARD, RECORDER = "scripts/lua/check-release-tier-freshness.lua", "scripts/record-ci-phase-result.sh"
-- Exit 3 with a named skip, as the .sh did (step 355's STEP_SKIP_EXIT): nothing was examined, and it says so.
local function skip(why) out.line("skip:release-tier-ci-full:" .. why); T:cleanup(); verdict.emit("skip:release-tier-ci-full:" .. why, 3) end
if not fs.exists(GUARD) then skip(GUARD .. " is absent — nothing to exercise") end
if not fs.exists(RECORDER) then skip(RECORDER .. " is absent — nothing to exercise") end
if fixture.which("jq") == nil then skip("no jq on PATH") end
if PLAN == "" then skip("no plan binary") end

local D = T:scratch()
local RUN_ID = "local-ci-" .. text.trim(T:must{ "date", "-u", "+%Y%m%dT%H%M%SZ" }.stdout)
local function base(idx)
    return { PATH = env.get("PATH"), HOME = env.get("HOME"), TMPDIR = env.get("TMPDIR"), TILLANDSIAS_CHECK_LOG_INDEX = idx }
end
local function idx(name) return D.abs .. "/" .. name end
local function record(index, id, phase, check, status)
    return T:run{ SH, RECORDER, id, phase, check, status, cwd = ROOT, env = base(index), env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }.code
end
local function guard(index)
    local r = T:run{ PLAN, "script", "run", GUARD, cwd = ROOT, env = base(index), env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    local o = ((r.stdout or "") .. (r.stderr or "")):gsub("\r", "")
    return r.code, o, "rc=" .. tostring(r.code) .. ": " .. o:sub(1, 400)
end
local function has_line(o, prefix)
    for l in o:gmatch("[^\n]+") do if l:sub(1, #prefix) == prefix then return true end end
    return false
end

local I = idx("full.jsonl")
for _, p in ipairs{ "pre-build", "post-build", "runtime" } do record(I, RUN_ID, p, "phase-" .. p, "pass") end
local rc, o, got = guard(I)
T:arm("1 a ci-full-shaped run (pre-build + post-build + runtime) reads FRESH and names the run",
    rc == 0 and has_line(o, "ok:release-tier-fresh:" .. RUN_ID .. ":"), got)

I = idx("phase-only.jsonl")
record(I, RUN_ID, "pre-build", "phase-pre-build", "pass")
rc, o, got = guard(I)
T:arm("2 NEGATIVE CONTROL: a phase-only pre-build run still reads never:release-tier", rc ~= 0 and has_line(o, "never:release-tier:"), got)

I = idx("runtime-skipped.jsonl")
record(I, RUN_ID, "pre-build", "phase-pre-build", "pass"); record(I, RUN_ID, "post-build", "phase-post-build", "pass")
record(I, RUN_ID, "runtime", "phase-runtime", "skipped")
rc, o, got = guard(I)
T:arm("3 a skipped runtime phase still covers the tier, and the verdict SAYS skip", rc == 0 and text.contains(o, "1 skip"), got)

I = idx("red.jsonl")
record(I, RUN_ID, "pre-build", "phase-pre-build", "pass"); record(I, RUN_ID, "post-build", "phase-post-build", "fail")
record(I, RUN_ID, "runtime", "phase-runtime", "pass")
rc, o, got = guard(I)
T:arm("4 a failing phase records, and reads RED rather than never", rc ~= 0 and has_line(o, "red:release-tier:"), got)

local function size(path)
    local r = T:run{ SH, "-s", "--", path, stdin = '[ -s "$1" ] && echo nonempty || echo empty\n' }
    return text.trim(r.stdout or "")
end
I = idx("refuse.jsonl")
local r5 = record(I, "ci-full-oops", "runtime", "x", "pass")
T:arm("5 the recorder REFUSES a malformed run id, and writes nothing", r5 ~= 0 and size(I) == "empty", "rc=" .. tostring(r5) .. " " .. size(I))

I = idx("refuse2.jsonl")
local r6a, r6b = record(I, RUN_ID, "smoke", "x", "pass"), record(I, RUN_ID, "runtime", "x", "green")
T:arm("6 the recorder REFUSES an unknown phase and an unknown status at rc=2, with nothing written",
    r6a == 2 and r6b == 2 and size(I) == "empty", tostring(r6a) .. " " .. tostring(r6b) .. " " .. size(I))

-- 7. local-ci.sh refuses a malformed run id at rc=2 BEFORE running anything.
local lci = fs.read("scripts/local-ci.sh")
if text.contains(lci, "TILLANDSIAS_CI_RUN_ID") then
    -- The builder markers pass through: without them local-ci.sh re-enters the
    -- builder from inside the gate and exits 1 before it reads the run id.
    local e = base(idx("lci.jsonl")); e.TILLANDSIAS_CI_RUN_ID = "not-a-run-id"
    for _, k in ipairs{ "TOOLBOX_PATH", "container", "TILLANDSIAS_SKIP_TOOLBOX", "TILLANDSIAS_SKIP_WSL2" } do e[k] = env.get(k) end
    local r = T:run{ SH, "scripts/local-ci.sh", "--phase", "pre-build", cwd = ROOT, env = e, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 120000 }
    T:arm("7 local-ci.sh refuses a malformed TILLANDSIAS_CI_RUN_ID at rc=2 before running anything", r.code == 2,
        "rc=" .. tostring(r.code) .. " " .. (r.stderr or ""):sub(1, 300))
else
    T:arm("7 scripts/local-ci.sh reads TILLANDSIAS_CI_RUN_ID", false, "build.sh cannot correlate its phases")
end

-- 8. build.sh records the phases it runs outside local-ci, under an exported run id.
local b = fs.read("build.sh")
local missing = {}
for _, n in ipairs{ "_record_ci_phase post-build", "_record_ci_phase runtime", "export TILLANDSIAS_CI_RUN_ID" } do
    if not text.contains(b, n) then missing[#missing + 1] = n end
end
T:arm("8 build.sh records post-build and runtime under an exported run id", #missing == 0, table.concat(missing, ", "))

T:finish{ ok = function(n) return "ok:release-tier-ci-full:" .. n end, fail = function(n) return "violation:release-tier-ci-full:" .. n end }
