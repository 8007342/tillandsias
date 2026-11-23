-- @trace order:1494-kkbi, order:1247-amcu, order:2245-pf7x
--
-- test-rank-refusal-hits.lua — the bare-refusal ranker orders by what agents
-- RECORD hitting, never alphabetically and never by fixture-provoked log noise.
-- Hermetic: a scratch audit file, scratch ledger dirs and a scratch log.
-- Ported whole from scripts/test-rank-refusal-hits.sh (2245-pf7x); the arms
-- and their assertions are unchanged.
--
-- Arms:
--   1 ORDER     exact rank by recorded hits (descending), ties by token, and a
--               token recorded zero times comes after every token with hits
--   2 PREFIX    an audit token that is a static prefix counts the run-time
--               completions recorded after it
--   3 LOGS      (negative control) a token hit only in a --logs file does NOT
--               outrank a recorded token; its hits appear in the logs= column
--   4 EMPTY     an audit with no bare sites refuses, never prints an empty rank
--   5 LONGEST   a verdict prefixed by two bare tokens counts once, for the
--               longer (more specific) one; the family prefix is not inflated
--   6 REPORTS   a ledger file that pastes a ranking (carries the summary line)
--               is not an encounter and adds no hits
--
-- Verdict: ok:rank-refusal-hits:<n> arms | violation:rank-refusal-hits:<n> failed

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local R = root .. "/scripts/rank-refusal-hits.sh"
local pass, failn = 0, 0
local function ok(m) pass = pass + 1; out.line("ok:   " .. m) end
local function bad(m) failn = failn + 1; out.line("FAIL: " .. m) end

local rel = "target/plan-scratch/rank-hits-" .. tostring(time.now_ms())
local W = root .. "/" .. rel
for _, d in ipairs({ "", "/ledger", "/issues", "/l5", "/l6" }) do proc.run{ argv = { "mkdir", "-p", W .. d } } end
local function cleanup() proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 } end

local function rank(args)
    local argv = { "bash", R }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run{ argv = argv, cwd = root, timeout_ms = 120000 }
    return (r.status == "exited" and r.code or -1), (r.stdout or "")
end
local function has(s, re)
    for _, l in ipairs(text.lines(s)) do if text.is_match(l, re) then return l end end
    return nil
end
local function flat(s) return (s:gsub("\n", "|")) end

local AUDIT = table.concat({
    "covered scripts/a.sh:1 refused:covered-one",
    "bare scripts/a.sh:10 blocked:alpha-rare",
    "bare scripts/b.sh:20 refused:beta-common",
    "bare scripts/b.sh:30 refused:beta-common",
    "bare scripts/c.sh:40 violation:gamma-prefix:",
    "bare scripts/d.sh:50 blocked:zeta-never",
    "bare scripts/e.sh:60 refused:log-only",
    "audit:refusal-affordance:covered=1 bare=6 sites=7", "" }, "\n")
fs.write(rel .. "/audit", AUDIT)
-- Recorded hits: beta-common 3, gamma-prefix 2 (two completions), alpha-rare 1.
fs.write(rel .. "/ledger/one.yaml", "summary: stopped by refused:beta-common twice: refused:beta-common\n")
fs.write(rel .. "/issues/two.md", "saw refused:beta-common and blocked:alpha-rare\n")
fs.write(rel .. "/ledger/three.yaml", "violation:gamma-prefix:one and violation:gamma-prefix:two\n")
-- The log only: many fixture-provoked hits of refused:log-only.
local log = {}
for i = 1, 9 do log[#log + 1] = "arm " .. i .. ": refused:log-only (expected)" end
fs.write(rel .. "/gate.log", table.concat(log, "\n") .. "\n")

-- ── ARMS 1-3 ─────────────────────────────────────────────────────────────
local rc, o = rank({ "--audit-file", W .. "/audit", "--ledger", W .. "/ledger", "--ledger", W .. "/issues", "--logs", W .. "/gate.log" })
local order = {}
for _, l in ipairs(text.lines(o)) do
    if text.is_match(l, [[^[0-9]+ ]]) then
        local f = {}
        for w in l:gmatch("%S+") do f[#f + 1] = w end
        order[#order + 1] = f[5] or ""
    end
end
local got = table.concat(order, " ")
local want = "refused:beta-common violation:gamma-prefix: blocked:alpha-rare blocked:zeta-never refused:log-only"
if rc == 0 and got == want then ok("ARM1 ranked by recorded hits, zero-hit tokens last, ties by token: " .. got)
else bad("ARM1 rc=" .. rc .. " order='" .. got .. "' want='" .. want .. "'") end

if has(o, [[^[0-9]+ hits=3 logs=0 sites=2 refused:beta-common scripts/b\.sh:20$]])
   and has(o, [[^[0-9]+ hits=2 logs=0 sites=1 violation:gamma-prefix: ]]) then
    ok("ARM2 a static-prefix token counts its recorded run-time completions (hits=2), sites and first site reported")
else bad("ARM2 out='" .. flat(o) .. "'") end

if has(o, [[^5 hits=0 logs=9 sites=1 refused:log-only ]]) then
    ok("ARM3 negative control: 9 log-only hits do not enter the rank (last, logs=9)")
else bad("ARM3 log hits leaked into the rank: '" .. tostring(has(o, "log-only")) .. "'") end

-- ── ARM 4 ────────────────────────────────────────────────────────────────
local empty = {}
for _, l in ipairs(text.lines(AUDIT)) do if l ~= "" and not text.starts_with(l, "bare ") then empty[#empty + 1] = l end end
fs.write(rel .. "/audit-empty", table.concat(empty, "\n") .. "\n")
local rc4, o4 = rank({ "--audit-file", W .. "/audit-empty", "--ledger", W .. "/ledger" })
if rc4 ~= 0 and has(o4, [[^blocked:rank-refusal-hits:no-bare-sites]]) then
    ok("ARM4 an audit with no bare sites is refused, not an empty rank")
else bad("ARM4 rc=" .. rc4 .. " out='" .. o4 .. "'") end

-- ── ARM 5 ────────────────────────────────────────────────────────────────
fs.write(rel .. "/audit5", "bare build.sh:1 refused:family:\nbare build.sh:2 refused:family:specific:\n")
fs.write(rel .. "/l5/a.yaml", "hit refused:family:specific:x and refused:family:specific:y and refused:family:other\n")
local _, o5 = rank({ "--audit-file", W .. "/audit5", "--ledger", W .. "/l5" })
if has(o5, [[^1 hits=2 logs=0 sites=1 refused:family:specific: ]])
   and has(o5, [[^2 hits=1 logs=0 sites=1 refused:family: ]]) then
    ok("ARM5 a verdict prefixed by two tokens counts once, for the longest (specific=2, family=1)")
else bad("ARM5 double-counted or misattributed: '" .. flat(o5) .. "'") end

-- ── ARM 6 ────────────────────────────────────────────────────────────────
fs.write(rel .. "/l6/real.yaml", "saw refused:family:specific:x\n")
fs.write(rel .. "/l6/report.yaml", "1 hits=9 refused:family:specific: x\nrefused:family:specific:y refused:family:specific:z\nrank-refusal-hits:tokens=2 with-hits=1 sites=2\n")
local _, o6 = rank({ "--audit-file", W .. "/audit5", "--ledger", W .. "/l6" })
if has(o6, [[^1 hits=1 logs=0 sites=1 refused:family:specific: ]]) then
    ok("ARM6 a pasted ranking adds no hits (only the real encounter counts)")
else bad("ARM6 a report was counted: '" .. flat(o6) .. "'") end

cleanup()
if failn == 0 then verdict.ok("rank-refusal-hits:" .. pass .. " arms") end
verdict.emit("violation:rank-refusal-hits:" .. failn .. " failed", 1)
