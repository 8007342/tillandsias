-- @env PATH HOME
-- @trace order:751-i9mb, order:787-f7dh, spec:methodology-accountability, order:2313-gbza, order:2390-byz6
--
-- test-base-ledger-status-loss.lua — scripts/lua/check-base-ledger-status-loss.lua on a scratch checkout. A
-- completion recorded INLINE in the base was invisible to the fragment-only detector, so packet 532 sat
-- claimable with its exit criterion green. The base nests packets at plan_index.steps[], not at `packets:`:
-- a walk of `packets` parsed the whole base and printed nothing, rc 0. Each main assertion has a mutant.
--
-- Usage: tillandsias-plan script run scripts/lua/test-base-ledger-status-loss.lua
-- Verdict: ok:base-ledger-status-loss:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("base-ledger-status-loss")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:skip("no-runnable-plan-binary") end
local SUBJECT = "scripts/lua/check-base-ledger-status-loss.lua"
local src = fs.read(SUBJECT):gsub("\r\n", "\n")
local d = T:scratch()
fs.mkdir(d.rel .. "/scripts"); fs.mkdir(d.rel .. "/plan"); fs.mkdir(d.rel .. "/plan/index.d")
fs.write(d.rel .. "/scripts/plan-binary-probe.sh", (fs.read("scripts/plan-binary-probe.sh"):gsub("\r\n", "\n")))
local ID = "inference-state-warm-grammar-multimodel"

local function base(status, events)
    local y = "plan_index:\n  version: v1\n  root: plan/\n  steps:\n    - packet_id: " .. ID .. "\n      order: 532\n"
        .. '      title: "inference state warm grammar multimodel"\n      status: ' .. status .. "\n      kind: fix\n      depends_on: []\n      events:\n"
    for i, t in ipairs(events) do
        y = y .. "        - type: " .. t .. '\n          ts: "2026-08-15T0' .. i .. ':00:00Z"\n          host: fixture\n          summary: |\n            a ' .. t .. " event\n"
    end
    fs.write(d.rel .. "/plan/index.yaml", y)
end
local seq = 0
local function run(body)
    local script = SUBJECT
    if body then seq = seq + 1; local m = d.rel .. "/mutant" .. seq .. ".lua"; fs.write(m, body); script = m end
    local r = T:run{ PLAN, "script", "run", script, cwd = ROOT, timeout_ms = 60000, env_unset = { "TILLANDSIAS_*", "CARGO_TARGET_DIR" },
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_PLAN_BIN = PLAN, BASE_STATUS_LOSS_ROOT = d.abs } }
    local o, e = text.trim((r.stdout or ""):gsub("\r", "")), r.stderr or ""
    return o, r.code, e, "rc=" .. tostring(r.code) .. " [" .. o .. "] " .. e:sub(1, 300)
end
local function mutant(from, to)
    local a, b = src:find(from, 1, true)
    if not a then T:refuse("mutation-anchor-missing", from) end
    return src:sub(1, a - 1) .. to .. src:sub(b + 1)
end

-- The 532 shape: a closure, then a claim that postdates it and leaves the status behind.
base("in_progress", { "completed", "claim" })
local o, rc, e, why = run()
T:arm("1 a base closure beside a non-terminal status is reported, named with its folded status", o == "advisory:base-status-loss:1"
    and text.contains(e, ID) and text.contains(e, "folds as 'in_progress'"), why)
T:arm("2 reporting is advisory: exit 0", rc == 0, why)
o = run(mutant("if s ~= nil and not TERMINAL[s] then", "if false then"))
T:arm("2 MUTATION a pass that never reports fails arm 1", o == "ok:no-base-status-loss:1 checked", o)
o, rc = run(mutant('verdict.emit("advisory:base-status-loss:" .. #adrift, 0)', 'verdict.emit("advisory:base-status-loss:" .. #adrift, 1)'))
T:arm("2 MUTATION an advisory that fails the build fails arm 2", rc ~= 0, o .. " rc=" .. tostring(rc))
base("completed", { "completed", "claim" })
o, rc, e, why = run()
T:arm("3 correcting the status silences it", o == "ok:no-base-status-loss:1 checked", why)
base("in_progress", { "progress", "claim" })
o, rc, e, why = run()
T:arm("4 CONTROL progress and claim are not closures", o == "ok:no-base-status-loss:0 checked", why)
base("in_progress", { "completed", "falsified" })
o, rc, e, why = run()
T:arm("5 CONTROL a falsified closure does not keep reporting", o == "ok:no-base-status-loss:0 checked", why)
o = run(mutant('"fragment-terminal-events", BASE_ABS, "--live"', '"fragment-terminal-events", BASE_ABS'))
T:arm("5 MUTATION without --live a withdrawn closure reports forever", o == "advisory:base-status-loss:1", o)
fs.write(d.rel .. "/plan/index.yaml", 'plan_index:\n  steps:\n    - packet_id: broken\n      summary: ": "\n     bad_indent: true\n')
o, rc, e, why = run()
T:arm("6 an unparseable base is never reported as clean", o == "skip:base-ledger-unparseable" and rc == 0, why)
o = run(mutant("if d.code == 3 then", "if false then"))
T:arm("6 MUTATION a pass that ignores the parser's refusal reads an unparseable base as clean", o == "ok:no-base-status-loss:0 checked", o)
T:must{ "rm", "-f", d.abs .. "/plan/index.yaml" }
o, rc, e, why = run()
T:arm("7 a missing base is said out loud", o == "skip:no-base-ledger", why)
local live = T:run{ PLAN, "script", "run", SUBJECT, cwd = ROOT, timeout_ms = 120000 }
local lo = text.trim((live.stdout or ""):gsub("\r", ""))
T:arm("8 on this tree it keeps its grammar and exits 0", live.code == 0 and (lo:find("^ok:no%-base%-status%-loss:%d+ checked$") or lo:find("^advisory:base%-status%-loss:%d+$")
    or lo:find("^skip:")) ~= nil, lo)
T:finish()
