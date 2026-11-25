-- @env PATH HOME
-- @trace order:1243-yiyq, order:2150-vf2v, order:2329-9etw
--
-- test-loop-status-audit-reads-current-emitter.lua — loop-status-metrics-audit.sh can read
-- what cycle-metrics.sh emits. Ported from the .sh of the same name (2329-9etw). The audit
-- anchored on `skippable: candidates=`; one interposed field broke every match for twelve
-- days while it printed a healthy rows=N, and a coordinator recorded the resulting
-- all-NOT-PASTING as a fleet behaviour.
--
--   1 the CURRENT form reads as a paste      2 the pre-drift form still does
--   3 CONTROL a host with no block is caught 4 THE TIE: the audit's own SHAPE matches the
--     REAL emitter's output                  5 prose about a skippable line is not a paste
--   6 a corpus where nothing parses refuses with a format-drift verdict
--
-- Usage: tillandsias-plan script run scripts/lua/test-loop-status-audit-reads-current-emitter.lua
-- Verdict: ok:loop-status-audit-reads-current-emitter:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("loop-status-audit-reads-current-emitter")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local TAIL = "candidates=98 floor_ms=2000 min_runs=5 top3=step:a:runs=1:avg_ms=2:fail_pct=0:saved_ms_upper=3 source=/x/y.jsonl"
local CUR, OLD = "skippable: window=7d " .. TAIL, "skippable: " .. TAIL
local function block(s) return "## Cycle\n\n```\n" .. s .. "\n```\n" end
-- files: host -> body; returns rc, stdout, stderr of the audit over them.
local function audit(files)
    local d = T:scratch()
    for host, body in pairs(files) do fs.write(d.rel .. "/20260917t120000z-deadbeef-" .. host .. ".md", body) end
    local r = T:run{ SH, ROOT .. "/scripts/loop-status-metrics-audit.sh", cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_LOOP_STATUS_DIR = d.abs } }
    local o, e = r.stdout or "", r.stderr or ""
    return r.code, o, e, "rc=" .. tostring(r.code) .. " " .. o:sub(1, 400) .. e:sub(1, 300)
end
local _, o, e, why = audit{ hostx = block(CUR) }
T:arm("1 an entry in the CURRENT emitter form reads as pasting", text.contains(o, "hostx skippable:") and not text.contains(o, "hostx NOT-PASTING"), why)
_, o, e, why = audit{ hosty = block(OLD) }
T:arm("2 the pre-drift form still reads as pasting", text.contains(o, "hosty skippable:"), why)
_, o, e, why = audit{ hostz = "## Cycle\n\nprose only, no machine block at all.\n", hostq = block(CUR) }
T:arm("3 CONTROL a host with no block is still NOT-PASTING beside one that pastes", text.contains(o, "hostz NOT-PASTING") and text.contains(o, "hostq skippable:"), why)

-- Every metrics log cycle-metrics reads is pinned to an empty scratch file (2150-vf2v): the
-- defaults are this host's real logs. The accuracy grade is skipped; no arm reads it.
local pins, d = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_CYCLE_METRICS_SKIP_GRADE = "1" }, T:scratch("pins")
for _, v in ipairs{ "TILLANDSIAS_EXPERT_USAGE_LOG", "TILLANDSIAS_CYCLE_FLOW_LOG", "TILLANDSIAS_EXPERT_HEALTH_LOG" } do
    fs.write(d.rel .. "/" .. v .. ".jsonl", ""); pins[v] = d.abs .. "/" .. v .. ".jsonl"
end
local m = T:run{ SH, ROOT .. "/scripts/cycle-metrics.sh", cwd = ROOT, env = pins, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 300000 }
local emitted = ("\n" .. (m.stdout or "")):match("\n(skippable: [^\n]*)")
if emitted then
    -- The shell evaluates the audit's own SHAPE= line and matches with its own grep -E.
    local r = T:run{ SH, "-s", "--", ROOT .. "/scripts/loop-status-metrics-audit.sh", emitted, cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 30000,
        stdin = 'l="$(grep -m1 -E "^SHAPE=" "$1")" || exit 90\neval "$l"\ngrep -qE -- "$SHAPE" <<<"$2"\n' }
    T:arm("4 THE TIE: the audit's own SHAPE matches what cycle-metrics.sh emits now", r.code == 0, "rc=" .. tostring(r.code) .. " " .. emitted:sub(1, 120))
else
    out.line("skip: 4 cycle-metrics.sh emitted no skippable line on this host; the tie is UNTESTED here, not satisfied")
end
_, o, e, why = audit{ hostp = "## Cycle\n\nI looked at the skippable: candidates in the report and thought about them.\n", hostq = block(CUR) }
T:arm("5 prose about a skippable line is not a paste", text.contains(o, "hostp NOT-PASTING"), why)
local rc
rc, o, e, why = audit{ hostr = "## Cycle\n\nno machine block.\n", hosts = "## Cycle\n\nnone here either.\n" }
T:arm("6 a corpus with nothing readable refuses with a format-drift verdict", text.contains(e, "violation:anchor-matches-nothing"), why)
T:finish()
