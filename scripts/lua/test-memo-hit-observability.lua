-- @env PATH HOME TMPDIR
-- @trace order:1074-96z9, order:2150-vf2v, order:2186-niam, order:2379-p5dq
--
-- test-memo-hit-observability.lua — the audit that nominates gate steps for memoisation can see whether
-- memoisation worked: a hit and a miss emit two differently named records (1, 2), `skippable:` states its
-- window (3), and a miss still runs inside `_run`, so its real cost is measured (4, the arm that matters).
-- Each source arm runs against the shipped file and against a mutant with the fix deleted.
-- Ported from the .sh of the same name.
--
-- Usage: tillandsias-plan script run scripts/lua/test-memo-hit-observability.lua
-- Verdict: ok:memo-hit-observability:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("memo-hit-observability")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
local function source(f) return (fs.read(f):gsub("\r\n", "\n")) end
local function without(s, needle)
    local kept, cut = {}, 0
    for l in (s .. "\n"):gmatch("(.-)\n") do
        if l:find(needle, 1, true) then cut = cut + 1 else kept[#kept + 1] = l end
    end
    if cut == 0 then T:refuse("mutation-anchor-missing", needle) end
    return table.concat(kept, "\n")
end
local BUILD, METRICS = source("build.sh"), source("scripts/cycle-metrics.sh")
local ARCH, STEP = source("scripts/lua/check-archiver-ready-set.lua"), source("scripts/gate-steps.d/955-831-ezea.step")

local function hit(s) return text.contains(s, 'emit_timing("archiver-check-hit"') end
T:arm("1 a memo hit emits a timing record", hit(ARCH))
T:arm("1 MUTATION a hit branch with no emit fails", not hit(without(ARCH, 'emit_timing("archiver-check-hit"')))

local function both(s, step)
    local function emits(n) return text.contains(s, "timing_emit " .. step .. n) or text.contains(s, 'emit_timing("' .. step .. n) end
    return emits("-hit") and emits("-miss")
end
T:arm("2 the archiver's hit and miss have their own names", both(ARCH, "archiver-check"))
T:arm("2 the terminology check's hit and miss have their own names", both(BUILD, "terminology-check"))
T:arm("2 no bare name is left for the two to collide on", not text.contains(ARCH, 'emit_timing("archiver-check"') and not text.contains(BUILD, "timing_emit archiver-check "))
T:arm("2 MUTATION one name of the pair gone fails", not both(without(ARCH, 'emit_timing("archiver-check-miss"'), "archiver-check"))

-- The report, from outside the repository. Every log it reads is pinned to a scratch file: defaulted they are
-- this host's real logs, and the run costs what its history does (2150-vf2v). SKIP_GRADE: no arm reads it.
local W = T:scratch()
local row = '{"ts":"' .. os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(time.now_ms() / 1000) - 3600) .. '","host":"h","step":"expensive","phase":"check","duration_ms":4000,"exit":0}\n'
fs.write(W.rel .. "/t.jsonl", row:rep(5))
fs.write(W.rel .. "/empty.jsonl", "")
local function report(o)
    o = o or {}
    local r = T:run{ SH, o.script or (ROOT .. "/scripts/cycle-metrics.sh"), cwd = W.abs, timeout_ms = 300000, env_unset = { "TILLANDSIAS_*" }, env = {
        PATH = env.get("PATH"), HOME = env.get("HOME"), TMPDIR = env.get("TMPDIR"), TILLANDSIAS_PLAN_BIN = o.plan or PLAN,
        TILLANDSIAS_TIMING_LOG = W.abs .. "/t.jsonl", TILLANDSIAS_EXPERT_USAGE_LOG = W.abs .. "/empty.jsonl", TILLANDSIAS_CYCLE_FLOW_LOG = W.abs .. "/empty.jsonl",
        TILLANDSIAS_EXPERT_HEALTH_LOG = W.abs .. "/empty.jsonl", TILLANDSIAS_CYCLE_METRICS_SKIP_GRADE = "1", TILLANDSIAS_RECUR_WINDOW_DAYS = o.days or "7" } }
    local s = "\n" .. ((r.stdout or "") .. (r.stderr or "")):gsub("\r", "")
    local skippable = s:match("\n(skippable:[^\n]*)") or ""
    return { code = r.code, window = skippable:match("^skippable: window=(%d+)d "), line = skippable,
        colon = s:find("\ncenticolon:", 1, true) ~= nil, verdict = s:find("\nverdict:", 1, true) ~= nil,
        got = "rc=" .. tostring(r.code) .. " " .. skippable .. " " .. s:sub(-200) }
end
local x = report()
T:arm("3 from another directory the report is complete and states window=7d", x.code == 0 and x.window == "7" and x.colon, x.got)
T:arm("3 and it counts the repeated step", text.contains(x.line, "expensive"), x.line)
x = report{ days = "10" }
T:arm("3 the window follows its setting", x.code == 0 and x.window == "10" and x.colon, x.got)
x = report{ plan = W.abs .. "/no-plan" }
T:arm("3 with no runner the report is still complete", x.code == 0 and x.window == "7" and x.verdict, x.got)
fs.write(W.rel .. "/refusing-plan", "#!/bin/sh\nexit 1\n")
T:must{ SH, "-s", "--", W.abs .. "/refusing-plan", stdin = 'chmod +x "$1"\n' }
x = report{ plan = W.abs .. "/refusing-plan" }
T:arm("3 with a runner that refuses the report is still complete", x.code == 0 and x.window == "7" and x.verdict, x.got)
-- The mutant prints the line the old way; scripts/ is copied so it finds its siblings.
local LINE = "printf 'skippable: window=%sd %s source=%s\\n' \"$RECUR_WINDOW_DAYS\" \\\n"
local a, b = METRICS:find(LINE, 1, true)
if not a then T:refuse("mutation-anchor-missing", "the skippable: line") end
local M = T:scratch("mutant")
T:must{ SH, "-s", "--", ROOT, M.abs, stdin = 'cd "$1" && cp -R scripts "$2/scripts"\n', timeout_ms = 120000 }
fs.write(M.rel .. "/scripts/cycle-metrics.sh", METRICS:sub(1, a - 1) .. "printf 'skippable: %s source=%s\\n' \\\n" .. METRICS:sub(b + 1))
x = report{ script = M.abs .. "/scripts/cycle-metrics.sh" }
T:arm("3 MUTATION a line with no window fails", text.contains(x.line, "skippable: candidates=") and x.window == nil, x.got)

-- A miss stays profiled iff the step is wired to the script that does the work and the runner runs it under _run.
local RUN_LUA = '_run env "TILLANDSIAS_SCRIPT_RUNNER_BIN=$_gs_plan" "$_gs_plan" script run "$_gs_root/$STEP_LUA"'
local function profiled(build)
    return text.contains(build, RUN_LUA) and text.contains("\n" .. STEP, '\nSTEP_LUA="scripts/lua/check-archiver-ready-set.lua"')
        and text.contains(ARCH, '"scripts/archive-plan-packets.sh", "--check"')
end
T:arm("4 CONTROL the archiver miss still runs inside _run", profiled(BUILD))
T:arm("4 MUTATION work lifted out of _run fails", not profiled(without(BUILD, RUN_LUA)))
T:arm("5 the saved figure is named an upper bound", text.contains(METRICS, "saved_ms_upper"))

T:finish()
