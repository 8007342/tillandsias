-- @env PATH HOME
-- @trace order:829-dkuc, order:1106-k2df, order:2400-hwnk
--
-- test-deslop-sweep-health.lua — the arms of check-deslop-sweep-health.sh --self-test, ported with the
-- decider to scripts/lua/check-deslop-sweep-health.lua. Each arm writes a scratch ledger and runs the
-- decider against it through TILLANDSIAS_DESLOP_LEDGER_DIR.
--
--   1  an empty ledger is unknown, exit 2, never ok      2 the kill rule fires, exit 1
--   3  CONTROL examined=0 sweeps are skipped, not counted 4 CONTROL a confirming sweep breaks the streak
--   5  a net-positive diff is red                         5b CONTROL a negative diff is not (the sign)
--   6  over the filing cap is red                         6b filing more than it retracts is red
--   7  0% refutation over the band is red
--   7b PRECEDENCE an all-refuted band reds via the kill rule; degenerate-100 is unreachable
--   8  a lone unscoreable record is unknown, exit 2, naming all four rules
--   9  a fully scored healthy ledger is ok, exit 0 (the positive control against "refuse always")
--
-- Usage: tillandsias-plan script run scripts/lua/test-deslop-sweep-health.lua
-- Verdict: ok:deslop-sweep-health:<n> arms | violation:deslop-sweep-health:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("deslop-sweep-health")
local RUNNER = fixture.plan_binary()
if RUNNER == "" then T:refuse("no-plan-binary", "the decider is Lua; build tillandsias-plan to run it") end
local ROOT = fixture.repo_root()
local CHECK = "scripts/lua/check-deslop-sweep-health.lua"

local function ledger(...)
    local d = T:scratch()
    local body = {}
    for i, rec in ipairs{ ... } do
        body[#body + 1] = string.format("## 2026-09-0%dT00:00:00Z fixture\nDESLOP-SWEEP: %s\n", i, rec)
    end
    fs.write(d.rel .. "/a.md", table.concat(body))
    local r = proc.run{ argv = { RUNNER, "script", "run", CHECK }, cwd = ROOT, timeout_ms = 120000,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_DESLOP_LEDGER_DIR = d.abs },
        env_unset = { "TILLANDSIAS_*" } }
    local o = text.trim(((r.stdout or ""):gsub("\r", "")))
    return { rc = r.code, out = o, why = "rc=" .. tostring(r.code) .. " " .. o .. " " .. (r.stderr or ""):sub(1, 200) }
end
local function starts(s, p) return s:sub(1, #p) == p end

local x = ledger()
T:arm("1 an empty ledger is unknown, exit 2, not ok", starts(x.out, "unknown:deslop-health:no-records") and x.rc == 2, x.why)
x = ledger("order=100 examined=10 confirmed=0", "order=200 examined=10 confirmed=0")
T:arm("2 the kill rule fires, exit 1", starts(x.out, "red:two-sweeps-zero-confirmed:") and x.rc == 1, x.why)
x = ledger("order=100 examined=0 confirmed=0", "order=200 examined=0 confirmed=0")
T:arm("3 CONTROL examined=0 sweeps are skipped by the kill rule, not counted", not starts(x.out, "red:two-sweeps-zero-confirmed:"), x.why)
x = ledger("order=100 examined=9 confirmed=0", "order=200 examined=9 confirmed=3", "order=300 examined=9 confirmed=0")
T:arm("4 CONTROL a confirming sweep between two zeros breaks the streak", not starts(x.out, "red:two-sweeps-zero-confirmed:"), x.why)
x = ledger("order=100 examined=9 confirmed=2 net_lines=+40")
T:arm("5 a sweep that added more than it deleted is red", starts(x.out, "red:net-positive-diff:100=40") and x.rc == 1, x.why)
x = ledger("order=100 examined=9 confirmed=2 net_lines=-40")
T:arm("5b CONTROL a net-negative sweep passes that rule (the sign is not inverted)", not starts(x.out, "red:net-positive-diff:"), x.why)
x = ledger("order=100 examined=9 confirmed=2 filed=6 retracted=9")
T:arm("6 filing more than 5 packets is red", starts(x.out, "red:filing-cap-exceeded:100=filed6"), x.why)
x = ledger("order=100 examined=9 confirmed=2 filed=3 retracted=1")
T:arm("6b filing more than it retracts is red", starts(x.out, "red:filed-exceeds-retracted:100=filed3/retracted1"), x.why)
local four = function(cf) local t = {} for i = 1, 4 do t[i] = "order=" .. i .. " examined=9 confirmed=" .. cf .. " findings=4" end return table.unpack(t) end
x = ledger(four(4))
T:arm("7 0% refutation over the band is red", starts(x.out, "red:refutation-rate-degenerate:0"), x.why)
x = ledger(four(0))
T:arm("7b PRECEDENCE an all-refuted band reds via the kill rule, which preempts degenerate-100",
    starts(x.out, "red:two-sweeps-zero-confirmed:") and not text.contains(x.out, "degenerate:100"), x.why)
x = ledger("order=834 examined=410 confirmed=51 retracted=51")
T:arm("8a a lone unscoreable record is unknown, exit 2, never ok", starts(x.out, "unknown:deslop-health:sweeps=1") and x.rc == 2, x.why)
T:arm("8b it names all four unscoreable rules", text.contains(x.out, "kill-rule") and text.contains(x.out, "refutation-band")
    and text.contains(x.out, "net-negative") and text.contains(x.out, "filing-cap"), x.why)
local healthy = {}
for i = 1, 4 do healthy[i] = "order=" .. i .. " examined=9 confirmed=3 findings=4 filed=1 retracted=2 net_lines=-10" end
x = ledger(table.unpack(healthy))
T:arm("9 a fully scored healthy ledger is ok, exit 0", starts(x.out, "ok:deslop-health:sweeps=4 scoring=4 refutation=25%") and x.rc == 0, x.why)

T:finish()
