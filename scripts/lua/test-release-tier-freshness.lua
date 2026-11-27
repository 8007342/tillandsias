-- @env PATH HOME TMPDIR
-- @trace order:890-27mv, order:1174-6r4k, order:2409-qbgu, spec:ci-release
--
-- test-release-tier-freshness.lua — scripts/lua/check-release-tier-freshness.lua says when the release tier last
-- ran on a host, and never claims it passed when it never ran. Ported from test-release-tier-freshness.sh (2409-qbgu).
--
-- REGIME: pure-source, hermetic, offline. Every arm writes its own check-logs.jsonl in a scratch dir and points the
-- guard at it through TILLANDSIAS_CHECK_LOG_INDEX. It runs no release tier and asserts nothing about THIS host.
--
-- NO ABSOLUTE MOMENT IS ENCODED (1130-i6xj). The fresh arms stamp themselves with the current UTC moment, and the
-- STALE arm moves the THRESHOLD below zero rather than fabricating an old timestamp.
--
--   1-2 absent / empty index: never          3 fresh all-pass: ok          4 fresh but red: red
--   5 too old: stale                          6 a red before a green: red   7 undatable run id: could-not-run
--   8 NEGATIVE CONTROL: no non-green outcome exits 0
--   9-12 (1174-6r4k) a phase-only run never becomes the tier's answer; separate phases that cover it do
--   13 local-ci.sh resolves its index through the resolver, which answers the override verbatim
--   M  mutants of the guard, each of which an arm above must catch
--
-- Usage: tillandsias-plan script run scripts/lua/test-release-tier-freshness.lua
-- Verdict: ok:release-tier-freshness:<n> arms | violation:release-tier-freshness:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("release-tier-freshness")
local SH, PLAN = fixture.posix_shell(), fixture.plan_binary()
local GUARD, RES = "scripts/lua/check-release-tier-freshness.lua", "scripts/convergence-log-path.sh"
if not fs.exists(GUARD) then T:refuse("subject-missing") end
if PLAN == "" then T:refuse("no-plan-binary") end
local src = fs.read(GUARD):gsub("\r\n", "\n")

-- The guard runs in a scratch repo holding only itself and the resolver, so nothing reads this checkout's index.
local R = T:git_repo()
fs.mkdir(R.rel .. "/scripts"); fs.mkdir(R.rel .. "/scripts/lua")
fs.write(R.rel .. "/" .. RES, (fs.read(RES):gsub("\r\n", "\n")))
T:must{ "chmod", "+x", R.abs .. "/" .. RES }
local mpath = R.rel .. "/" .. GUARD

local RUN_ID = "local-ci-" .. text.trim(T:must{ "date", "-u", "+%Y%m%dT%H%M%SZ" }.stdout)
local function rec_phase(id, phase, check, status)
    return '{"ci_run_id":"' .. id .. '","ci_phase":"' .. phase .. '","check_id":"' .. check .. '","status":"' .. status
        .. '","source_log":"","archived_log":"a","sha256":"x","duration_ms":1}\n'
end
local function rec(id, check, status) return rec_phase(id, "all", check, status) end
local function index(name, body)
    if body then fs.write(R.rel .. "/" .. name, body) end
    return R.abs .. "/" .. name
end

-- run_guard(index, {max_age=, body=}) -> {code=, out= (stdout and stderr), line= (last stdout line)}
local function run_guard(idx, o)
    o = o or {}
    fs.write(mpath, o.body or src)
    local e = { PATH = env.get("PATH"), HOME = env.get("HOME"), TMPDIR = env.get("TMPDIR"), TILLANDSIAS_CHECK_LOG_INDEX = idx }
    if o.max_age then e.TILLANDSIAS_RELEASE_TIER_MAX_AGE_DAYS = o.max_age end
    local r = T:run{ PLAN, "script", "run", R.abs .. "/" .. GUARD, cwd = R.abs, env = e, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    local so, se = (r.stdout or ""):gsub("\r", ""), (r.stderr or ""):gsub("\r", "")
    local last = ""
    for l in so:gmatch("[^\n]+") do last = l end
    return { code = r.code, out = so .. se, line = last, got = "rc=" .. tostring(r.code) .. " [" .. last .. "] " .. se:sub(1, 300) }
end
local function check(label, erc, tok, x) T:arm(label, x.code == erc and text.contains(x.out, tok), x.got) end

local ABSENT = index("absent.jsonl")
local EMPTY = index("empty.jsonl", "")
local GREEN = index("green.jsonl", rec(RUN_ID, "spec-cheatsheet-binding", "pass") .. rec(RUN_ID, "expert-groundtruth-harness", "pass"))
local RED = index("red.jsonl", fs.read(R.rel .. "/green.jsonl") .. rec(RUN_ID, "expert-groundtruth-harness", "fail"))
local ORDER = index("order.jsonl", rec(RUN_ID, "a", "fail") .. rec(RUN_ID, "b", "pass"))
local BAD = index("bad.jsonl", rec("local-ci-not-a-timestamp", "a", "pass"))

check("1 absent index reports never", 1, "never:release-tier:", run_guard(ABSENT))
check("2 empty index reports never", 1, "never:release-tier:", run_guard(EMPTY))
local x = run_guard(GREEN)
check("3 fresh all-pass is green", 0, "ok:release-tier-fresh:" .. RUN_ID .. ":0d:2/2", x)
T:arm("3 the verdict is the last stdout line", x.line == "ok:release-tier-fresh:" .. RUN_ID .. ":0d:2/2", x.got)
check("4 a failing check reads red", 1, "red:release-tier:1 failing", run_guard(RED))
check("5 too old reads stale", 1, "stale:release-tier:", run_guard(GREEN, { max_age = "-1" }))
check("6 a red before a green still reads red", 1, "red:release-tier:", run_guard(ORDER))
check("7 an unparseable run id could-not-run", 3, "could-not-run:release-tier:", run_guard(BAD))

-- 8. NEGATIVE CONTROL: the SET of non-green outcomes is closed under "never exits 0".
local neg = {}
for _, p in ipairs{ ABSENT, EMPTY, BAD, RED } do
    if run_guard(p).code == 0 then neg[#neg + 1] = p end
end
if run_guard(GREEN, { max_age = "-1" }).code == 0 then neg[#neg + 1] = "stale" end
T:arm("8 NEGATIVE CONTROL: no non-green outcome exits 0", #neg == 0, table.concat(neg, " "))

-- ORDER 1174-6r4k: the FULL run is written OLDER than the phase-only one on purpose.
local FULL_OLD, PARTIAL_NEW = "local-ci-20260913T120000Z", "local-ci-20260913T233926Z"
x = run_guard(index("phase-only.jsonl", rec(FULL_OLD, "alpha", "fail") .. rec(FULL_OLD, "beta", "pass")
    .. rec_phase(PARTIAL_NEW, "pre-build", "gamma", "pass")))
check("9 a green phase-only run does not mask the last full run's red", 1, "red:release-tier:", x)
check("9 and the ignored run is named", 1, "skip:phase-only-run:" .. PARTIAL_NEW, x)
check("10 NC: a full red run still reads red with its count", 1, "red:release-tier:1 failing",
    run_guard(index("full-red.jsonl", rec(FULL_OLD, "alpha", "pass") .. rec("local-ci-20260913T235000Z", "beta", "fail"))))
check("11 phases covered separately count as a full tier", 0, "ok:release-tier-fresh:",
    run_guard(index("covered.jsonl", rec_phase(RUN_ID, "pre-build", "a", "pass") .. rec_phase(RUN_ID, "post-build", "b", "pass")
        .. rec_phase(RUN_ID, "runtime", "c", "pass"))))
local ONLY_PARTIAL = index("only-partial.jsonl", rec_phase(PARTIAL_NEW, "pre-build", "gamma", "pass"))
check("12 an index of only phase-only runs reports never, not fresh", 1, "never:release-tier:no FULL-tier run", run_guard(ONLY_PARTIAL))

-- 13. THE WRITER HONOURS THE SAME OVERRIDE THE READER DOES: local-ci.sh takes its index from the resolver (source
-- text: running it would run the tier), and the resolver answers the override verbatim (executed).
local own = R.abs .. "/own-index.jsonl"
local res = T:run{ SH, R.abs .. "/" .. RES, cwd = R.abs, env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_CHECK_LOG_INDEX = own },
    env_unset = { "TILLANDSIAS_*" } }
T:arm("13 local-ci.sh resolves its index through the resolver, which answers the override verbatim",
    text.contains(fs.read("scripts/local-ci.sh"), 'CHECK_LOG_INDEX="$("$REPO_ROOT/scripts/convergence-log-path.sh")"')
        and text.trim((res.stdout or ""):gsub("\r", "")) == own, tostring(res.stdout) .. tostring(res.stderr))

-- MUTANTS. Each edit must land exactly once (a no-op mutant reads exactly like a passing test).
local function mutant(label, from, to, idx, o, want_rc, want_tok)
    local a = src:find(from, 1, true)
    local n = 0
    for _ in src:gmatch(from:gsub("%p", "%%%0")) do n = n + 1 end
    if n ~= 1 then T:arm("M " .. label .. " (the edit landed exactly once)", false, n .. " occurrences"); return end
    local body = src:sub(1, a - 1) .. to .. src:sub(a + #from)
    o = o or {}; o.body = body
    local m = run_guard(idx, o)
    -- Caught means the arm's expectation no longer holds against the mutant, and the mutant still ran to a verdict
    -- (a mutant that crashes proves nothing about the arm).
    T:arm("M " .. label, m.line:find("^[%a-]+:release%-tier") ~= nil and not (m.code == want_rc and text.contains(m.out, want_tok)), m.got)
end
mutant("a guard that ignores failures is caught by arm 4", "if fail > 0 then", "if false then", RED, nil, 1, "red:release-tier:")
mutant("a guard that ignores age is caught by arm 5", "if age > MAX_AGE then", "if false then", GREEN, { max_age = "-1" }, 1, "stale:release-tier:")
mutant("a guard that takes any run as full-tier is caught by arm 12",
    'if h["all"] or (h["pre-build"] and h["post-build"] and h["runtime"]) then', "if true then", ONLY_PARTIAL, nil, 1, "never:release-tier:no FULL-tier run")
mutant("a guard that counts only the run's last record is caught by arm 6",
    "if rec:find(needle, 1, true) then", "if rec:find(needle, 1, true) and rec == recs[#recs] then", ORDER, nil, 1, "red:release-tier:")
mutant("a guard that stops naming skipped runs is caught by arm 9", 'print("skip:phase-only-run:"', 'print("note:phase-only-run:"',
    index("phase-only.jsonl"), nil, 1, "skip:phase-only-run:" .. PARTIAL_NEW)

T:finish()
