-- @env PATH HOME
-- @trace order:751-i9mb, order:787-f7dh, spec:methodology-accountability, order:2313-gbza
--
-- test-base-ledger-status-loss.lua — scripts/check-base-ledger-status-loss.sh. Ported from the
-- .sh of the same name (2313-gbza); same seven cases. A completion recorded INLINE in the
-- base was invisible to the fragment-only detector, so packet 532 sat claimable with its exit
-- criterion green. The base nests packets at plan_index.steps[], not at `packets:`: that is
-- the defect, since a walk of `packets` parsed the whole base and printed nothing, rc 0.
--
-- Usage: tillandsias-plan script run scripts/lua/test-base-ledger-status-loss.lua
-- Verdict: ok:base-ledger-status-loss:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("base-ledger-status-loss")
local SH, PLAN = fixture.posix_shell(), fixture.plan_binary()
if PLAN == "" then T:skip("no-runnable-plan-binary") end
local d = T:scratch()
fs.mkdir(d.rel .. "/scripts"); fs.mkdir(d.rel .. "/plan/index.d")
for _, f in ipairs{ "check-base-ledger-status-loss.sh", "plan-binary-probe.sh" } do fs.write(d.rel .. "/scripts/" .. f, fs.read("scripts/" .. f)) end
local ID = "inference-state-warm-grammar-multimodel"

local function base(status, events)
    local y = "plan_index:\n  version: v1\n  root: plan/\n  steps:\n    - packet_id: " .. ID .. "\n      order: 532\n"
        .. '      title: "inference state warm grammar multimodel"\n      status: ' .. status .. "\n      kind: fix\n      depends_on: []\n      events:\n"
    for i, t in ipairs(events) do
        y = y .. "        - type: " .. t .. '\n          ts: "2026-08-15T0' .. i .. ':00:00Z"\n          host: fixture\n          summary: |\n            a ' .. t .. " event\n"
    end
    fs.write(d.rel .. "/plan/index.yaml", y)
end
local function run()
    local r = T:run{ SH, d.abs .. "/scripts/check-base-ledger-status-loss.sh", cwd = d.abs, timeout_ms = 60000,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_PLAN_BIN = PLAN, BASE_STATUS_LOSS_ROOT = "", BASE_STATUS_LOSS_INDEX = "" },
        env_unset = { "TILLANDSIAS_*", "CARGO_TARGET_DIR" } }
    local o, e = text.trim(r.stdout or ""), r.stderr or ""
    return o, r.code, e, "rc=" .. tostring(r.code) .. " [" .. o .. "] " .. e:sub(1, 300)
end

-- The 532 shape: a closure, then a claim that postdates it and leaves the status behind.
base("in_progress", { "completed", "claim" })
local o, rc, e, why = run()
T:arm("1 a base closure beside a non-terminal status is reported, named with its folded status", o == "advisory:base-status-loss:1"
    and text.contains(e, ID) and text.contains(e, "folds as 'in_progress'"), why)
T:arm("2 reporting is advisory: exit 0", rc == 0, why)
base("completed", { "completed", "claim" })
o, rc, e, why = run()
T:arm("3 correcting the status silences it", o == "ok:no-base-status-loss:1 checked", why)
base("in_progress", { "progress", "claim" })
o, rc, e, why = run()
T:arm("4 CONTROL progress and claim are not closures", o == "ok:no-base-status-loss:0 checked", why)
base("in_progress", { "completed", "falsified" })
o, rc, e, why = run()
T:arm("5 CONTROL a falsified closure does not keep reporting", o == "ok:no-base-status-loss:0 checked", why)
fs.write(d.rel .. "/plan/index.yaml", 'plan_index:\n  steps:\n    - packet_id: broken\n      summary: ": "\n     bad_indent: true\n')
o, rc, e, why = run()
T:arm("6 an unparseable base is never reported as clean", o == "skip:base-ledger-unparseable" and rc == 0, why)
T:must{ "rm", "-f", d.abs .. "/plan/index.yaml" }
o, rc, e, why = run()
T:arm("7 a missing base is said out loud", o == "skip:no-base-ledger", why)
T:finish()
