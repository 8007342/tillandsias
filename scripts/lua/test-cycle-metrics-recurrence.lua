-- @env PATH HOME
-- @trace order:1001-q3zf, order:2372-snfs
--
-- test-cycle-metrics-recurrence.lua — cycle-metrics.sh's repeat:, recur: and skippable: lines, whole
-- lines compared. Ported from the .sh of the same name (2372-snfs). Scratch timing logs; no plan
-- binary and no live log is reachable.
--
--   a counts, totals, order and the parse rule    b invariance is never reached by rounding
--   c the floor and the minimum, and their knobs  d the repeat window and --cycle-start
--   e the recur window    f a missing log         g malformed rows are dropped
--   h --experts-only      i control bytes         j an unparseable --cycle-start is labelled
--   k a directory as log  l integer totals        m skippable echoes its window
--
-- Usage: tillandsias-plan script run scripts/lua/test-cycle-metrics-recurrence.lua
-- Verdict: ok:cycle-metrics-recurrence:<n> arms | violation:... | skip:...:no-jq

local fixture = require "common.fixture"
local T = fixture.new("cycle-metrics-recurrence")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
-- The reporter's own JSON reader.
if not fixture.which("j" .. "q") then T:skip("no-jq") end
local w, seq = T:scratch(), 0
for _, f in ipairs{ "usage", "flow", "health" } do fs.write(w.rel .. "/" .. f .. ".jsonl", "") end
local NOW = math.floor(time.now_ms() / 1000)
local function ago(s) return os.date("!%Y-%m-%dT%H:%M:%SZ", NOW - s) end
local T0 = ago(60)
local function row(n, ts, step, ms, exit) return (('{"ts":"%s","host":"h","step":"%s","phase":"p","duration_ms":%s,"exit":%d}\n'):format(ts, step, tostring(ms), exit)):rep(n) end
local function log(...)
    seq = seq + 1
    local f = "/l" .. seq .. ".jsonl"
    fs.write(w.rel .. f, table.concat{ ... })
    return w.abs .. f
end
local function run(path, knobs, ...)
    local e = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_EXPERT_USAGE_LOG = w.abs .. "/usage.jsonl", TILLANDSIAS_CYCLE_FLOW_LOG = w.abs .. "/flow.jsonl",
        TILLANDSIAS_EXPERT_HEALTH_LOG = w.abs .. "/health.jsonl", TILLANDSIAS_PLAN_BIN = "/nonexistent/tillandsias-plan", TILLANDSIAS_CYCLE_START_TS = "", TILLANDSIAS_RECUR_WINDOW_DAYS = "7",
        TILLANDSIAS_SKIP_MIN_RUNS = "5", TILLANDSIAS_SKIP_FLOOR_MS = "2000", TILLANDSIAS_CYCLE_METRICS_SKIP_TRACES = "1", TILLANDSIAS_TIMING_LOG = path }
    for k, v in pairs(knobs or {}) do e[k] = v end
    local r = proc.run{ argv = { SH, ROOT .. "/scripts/cycle-metrics.sh", ... }, cwd = ROOT, env = e, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    local o = { rc = r.code, all = "\n" .. (r.stdout or ""):gsub("\r", ""), log = path }
    for _, k in ipairs{ "repeat", "recur", "skippable", "repo" } do o[k] = o.all:match("\n(" .. k .. ":[^\n]*)") end
    return o
end
local function eq(name, got, want) T:arm(name, got == want, "[" .. tostring(got) .. "] want [" .. want .. "]") end
local function line(name, x, key, want) eq(name, x[key], (want:gsub("@", x.log, 1))) end

local a = log(row(1, T0, "step:gate:archiver", 3000, 0), row(1, T0, "step:gate:archiver", 5000, 0), row(3, T0, "step:gate:archiver", 4000, 0), row(1, T0, "build-check", 7000, 0), row(1, T0, "build-check", 9000, 1),
    row(1, T0, "quick", 100, 0), row(6, T0, "litmus-suite", 2500, 1))
local x = run(a)
eq("a1 the reporter exits 0", tostring(x.rc), "0")
line("a2 repeat counts inside 3 h, by count then name", x, "repeat", "repeat: window=3h steps=4 top3=litmus-suite=6,step:gate:archiver=5,build-check=2 source=@")
line("a3 recur: two runs or more, by total", x, "recur", "recur: window=7d runs=14 steps=3 top3=step:gate:archiver:runs=5:total_ms=20000:avg_ms=4000:fail_pct=0,build-check:runs=2:total_ms=16000:avg_ms=8000:fail_pct=50,litmus-suite:runs=6:total_ms=15000:avg_ms=2500:fail_pct=100 source=@")
line("a4 skippable: invariant, expensive, repeated", x, "skippable", "skippable: window=7d candidates=2 floor_ms=2000 min_runs=5 top3=step:gate:archiver:runs=5:avg_ms=4000:fail_pct=0:saved_ms_upper=16000,litmus-suite:runs=6:avg_ms=2500:fail_pct=100:saved_ms_upper=12500 source=@")
local entry = (x.skippable or ""):match("top3=([^,]*)") or ""
eq("a5 a colon-bearing step parses: the name, then fields from the right", (entry:match("^(.-):runs=") or "") .. " " .. (entry:match(".*:avg_ms=(%d+)") or "") .. " " .. (entry:match(".*:saved_ms_upper=(%d+)$") or ""), "step:gate:archiver 4000 16000")

x = run(log(row(5, T0, "mixed", 3000, 0), row(1, T0, "mixed", 3000, 1), row(6, T0, "alwaysfail", 3000, 1), row(249, T0, "nearly", 3000, 0), row(1, T0, "nearly", 3000, 1)))
line("b1 mixed is out, always-failing in, 1 in 250 is not invariant", x, "skippable", "skippable: window=7d candidates=1 floor_ms=2000 min_runs=5 top3=alwaysfail:runs=6:avg_ms=3000:fail_pct=100:saved_ms_upper=15000 source=@")
T:arm("b2 recur still reports it, with a rounded fail_pct", text.contains(x.recur or "", "nearly:runs=250:total_ms=750000:avg_ms=3000:fail_pct=0"), tostring(x.recur))

local c = log(row(5, T0, "atfloor", 2000, 0), row(4, T0, "belowmin", 5000, 0), row(5, T0, "belowfloor", 1999, 0))
line("c1 at the floor is in; one run or one ms short is out", run(c), "skippable", "skippable: window=7d candidates=1 floor_ms=2000 min_runs=5 top3=atfloor:runs=5:avg_ms=2000:fail_pct=0:saved_ms_upper=8000 source=@")
line("c2 both knobs move and are echoed", run(c, { TILLANDSIAS_SKIP_MIN_RUNS = "4", TILLANDSIAS_SKIP_FLOOR_MS = "1999" }), "skippable", "skippable: window=7d candidates=3 floor_ms=1999 min_runs=4 top3=belowmin:runs=4:avg_ms=5000:fail_pct=0:saved_ms_upper=15000,atfloor:runs=5:avg_ms=2000:fail_pct=0:saved_ms_upper=8000,belowfloor:runs=5:avg_ms=1999:fail_pct=0:saved_ms_upper=7996 source=@")

local d, CS = log(row(2, ago(30), "a", 10, 0), row(1, ago(7200), "a", 10, 0), row(1, ago(9000), "b", 10, 0), row(1, ago(18000), "c", 10, 0)), ago(3600)
local SINCE, WIDE = "repeat: window=since=" .. CS .. " steps=1 top3=a=2 source=@", "repeat: window=3h steps=2 top3=a=3,b=1 source=@"
line("d1 the default window is 3 h", run(d), "repeat", WIDE)
x = run(d, nil, "--cycle-start", CS)
line("d2 --cycle-start excludes what is older", x, "repeat", SINCE)
line("d3 the environment is its fallback", run(d, { TILLANDSIAS_CYCLE_START_TS = CS }), "repeat", SINCE)
T:arm("d4 it does not leak into the since-ref", text.contains(x.repo or "", "commits_this_cycle=- "), tostring(x.repo))

local e = log(row(2, ago(691200), "old", 4000, 0), row(2, ago(86400), "new", 3000, 0))
line("e1 older than 7 days is outside recur", run(e), "recur", "recur: window=7d runs=2 steps=1 top3=new:runs=2:total_ms=6000:avg_ms=3000:fail_pct=0 source=@")
line("e2 --recur-window-days widens it and is echoed", run(e, nil, "--recur-window-days", "10"), "recur", "recur: window=10d runs=4 steps=2 top3=old:runs=2:total_ms=8000:avg_ms=4000:fail_pct=0,new:runs=2:total_ms=6000:avg_ms=3000:fail_pct=0 source=@")

local NORECUR = "recur: window=7d runs=0 steps=0 top3=- source=absent"
x = run(w.abs .. "/does-not-exist.jsonl")
eq("f1 a missing log exits 0", tostring(x.rc), "0")
eq("f2 and repeat is absent", x["repeat"], "repeat: window=3h steps=0 top3=- source=absent")
eq("f3 and recur", x.recur, NORECUR)
eq("f4 and skippable", x.skippable, "skippable: window=7d candidates=0 floor_ms=2000 min_runs=5 top3=- source=absent")

x = run(log(row(1, T0, "x", 100, 0), "this is not json\n", row(1, "unknown", "x", 100, 0), row(1, T0, "x", 300, 0)))
eq("g1 a malformed row exits 0", tostring(x.rc), "0")
line("g2 malformed and unplaceable rows are dropped, the rest summed", x, "recur", "recur: window=7d runs=2 steps=1 top3=x:runs=2:total_ms=400:avg_ms=200:fail_pct=0 source=@")
x = run(a, nil, "--experts-only")
T:arm("h --experts-only carries none of the three lines", x.rc == 0 and not x["repeat"] and not x.recur and not x.skippable, x.all:sub(1, 300))

x = run(log(row(5, T0, "line\\nbreak", 3000, 0), row(5, T0, "tab\\there", 3000, 0), row(5, T0, "sp ace", 3000, 0), row(5, T0, "com,ma", 3000, 0)))
local n = 0
for l in x.all:gmatch("[^\n]+") do
    if l:match("^repeat: ") or l:match("^recur: ") or l:match("^skippable: ") then n = n + 1 end
end
eq("i1 control bytes: exit 0 and one line per label", x.rc .. " " .. n, "0 3")
line("i2 repeat's names are sanitised", x, "repeat", "repeat: window=3h steps=4 top3=com_ma=5,line_break=5,sp_ace=5 source=@")
line("i3 recur carries its own data", x, "recur", "recur: window=7d runs=20 steps=4 top3=com_ma:runs=5:total_ms=15000:avg_ms=3000:fail_pct=0,line_break:runs=5:total_ms=15000:avg_ms=3000:fail_pct=0,sp_ace:runs=5:total_ms=15000:avg_ms=3000:fail_pct=0 source=@")
line("i4 so does skippable", x, "skippable", "skippable: window=7d candidates=4 floor_ms=2000 min_runs=5 top3=com_ma:runs=5:avg_ms=3000:fail_pct=0:saved_ms_upper=12000,line_break:runs=5:avg_ms=3000:fail_pct=0:saved_ms_upper=12000,sp_ace:runs=5:avg_ms=3000:fail_pct=0:saved_ms_upper=12000 source=@")
local em = log("")
run(em, nil, "--emit-timing", 'step=q"u\\o\\te', 'phase=p"h', "duration_ms=3000", "exit=0", "host=h\\x")
local ok, j = pcall(json.parse, text.trim(fs.read(w.rel .. em:sub(#w.abs + 1))))
eq("i5 --emit-timing strips quotes and backslashes", ok and tostring(j.step) .. "/" .. tostring(j.phase) .. "/" .. tostring(j.host) or "unreadable", "quote/ph/hx")

line("j1 an unparseable --cycle-start is labelled, never widened", run(d, nil, "--cycle-start", "garbage"), "repeat", "repeat: window=since=garbage:unparsed steps=0 top3=- source=@")
local bare = CS:sub(1, -2)
line("j2 so is one without its Z", run(d, nil, "--cycle-start", bare), "repeat", "repeat: window=since=" .. bare .. ":unparsed steps=0 top3=- source=@")
line("j3 fractional seconds parse", run(d, nil, "--cycle-start", bare .. ".000Z"), "repeat", "repeat: window=since=" .. bare .. ".000Z steps=1 top3=a=2 source=@")
line("j4 one with no value is the fallback", run(d, nil, "--cycle-start"), "repeat", WIDE)
fs.mkdir(w.rel .. "/dir.jsonl")
x = run(w.abs .. "/dir.jsonl")
eq("k a directory as log reads absent and exits 0", x.rc .. " " .. tostring(x.recur), "0 " .. NORECUR)
line("l total_ms is floored, avg unaffected", run(log(row(4, T0, "frac", 3000, 0), row(1, T0, "frac", "3000.7", 0))), "recur", "recur: window=7d runs=5 steps=1 top3=frac:runs=5:total_ms=15000:avg_ms=3000:fail_pct=0 source=@")
local m = log(row(5, T0, "widewin", 4000, 0))
local WW = " candidates=1 floor_ms=2000 min_runs=5 top3=widewin:runs=5:avg_ms=4000:fail_pct=0:saved_ms_upper=16000 source=@"
line("m1 skippable echoes its default window", run(m), "skippable", "skippable: window=7d" .. WW)
line("m2 and the widened one", run(m, nil, "--recur-window-days", "10"), "skippable", "skippable: window=10d" .. WW)
T:finish()
