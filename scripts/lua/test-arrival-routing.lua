-- @env PATH HOME
-- @trace order:831-ezea, order:702-68zj, order:785-sqe6, order:787-f7dh, order:2400-ejm8
--
-- test-arrival-routing.lua — pins every verdict of scripts/lua/check-arrival-routing.lua. The .sh it
-- replaces had no fixture of its own (only its missing-base line in
-- test-added-deciders-refuse-a-missing-base.lua). A scratch checkout with the decider and the probe;
-- the plan binary is a stub whose `arrival-routing-check` answer each arm chooses through TILLANDSIAS_STUB_MODE
-- (a TILLANDSIAS_* name, because the decider's own spawns pass only that namespace through).
--
--   1 no added fragment: ok 0 of 0          2 no base ref: skipped no-diff-base, never ok
--   3 no binary: skipped no-plan-binary     4 a binary without the subcommand: skipped stale
--   5 overlaps: advisory, counted by distinct row, exit 0, the rule and remedy on stderr
--   6 no overlap: ok over the declared population
--   7 the checker's exit 3: skipped unreadable-fragment, never ok
--   8 any other exit: fail, exit 1          9 exit 0 with no population: fail checker-exit-0, exit 1
--   10 MUTATION a checker that counts overlap LINES, not rows, would say 2: the distinct count is pinned
--
-- Usage: tillandsias-plan script run scripts/lua/test-arrival-routing.lua
-- Verdict: ok:arrival-routing-fixture:<n> arms | violation:arrival-routing-fixture:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("arrival-routing-fixture")
local SH = fixture.posix_shell()
local RUNNER = fixture.plan_binary()
if RUNNER == "" then T:refuse("no-plan-binary", "the decider is Lua; build tillandsias-plan to run it") end
local CHECK = "scripts/lua/check-arrival-routing.lua"

local g = T:git_repo()
fs.mkdir(g.rel .. "/scripts/lua"); fs.mkdir(g.rel .. "/plan/index.d")
fs.write(g.rel .. "/" .. CHECK, fs.read(CHECK))
fs.write(g.rel .. "/scripts/plan-binary-probe.sh", fs.read("scripts/plan-binary-probe.sh"))
fs.write(g.rel .. "/plan/index.d/README.md", "# fragments\n")
T:must{ "git", "-C", g.abs, "add", "-A" }
T:must{ "git", "-C", g.abs, "commit", "-q", "-m", "base" }
T:must{ "git", "-C", g.abs, "update-ref", "refs/remotes/origin/linux-next", "HEAD" }

-- The stub: `capabilities` lists the subcommand unless STALE; `arrival-routing-check` does MODE.
local stub = g.abs .. "/stub-plan"
fs.write(g.rel .. "/stub-plan", [==[#!/bin/sh
case "$1" in
  capabilities) echo status; [ -n "${TILLANDSIAS_STUB_STALE:-}" ] || echo arrival-routing-check; exit 0 ;;
  arrival-routing-check)
    case "${TILLANDSIAS_STUB_MODE:-none}" in
      none)    echo "population|3" ;;
      overlap) echo "population|3"
               echo "overlap|row-a|owned_files|row-a owns scripts/x.sh, which open row old-1 (role linux) owns"
               echo "overlap|row-a|deliverable|row-a's deliverable equals old-2's"
               echo "overlap|row-b|title|row-b's title equals old-3's" ;;
      unreadable) exit 3 ;;
      broken)  exit 5 ;;
      nopop)   echo "overlap|row-a|title|x" ;;
    esac ;;
esac
]==])
T:must{ "chmod", "+x", stub }

local function run(e)
    local env_ = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_PLAN_BIN = stub }
    for k, v in pairs(e or {}) do env_[k] = v end
    local r = proc.run{ argv = { RUNNER, "script", "run", CHECK }, cwd = g.abs, env = env_,
        env_unset = { "TILLANDSIAS_*", "CARGO_TARGET_DIR" }, timeout_ms = 300000 }
    local o = text.trim(((r.stdout or ""):gsub("\r", "")))
    return { rc = r.code, out = o, err = (r.stderr or ""):gsub("\r", ""), why = "rc=" .. tostring(r.code) .. " [" .. o .. "] " .. (r.stderr or ""):sub(1, 300) }
end

local x = run()
T:arm("1 no added fragment: ok over 0 of 0", x.out == "ok:arrival-routing:0 of 0 new rows" and x.rc == 0, x.why)
fs.write(g.rel .. "/plan/index.d/20990101t000000z-new-row.yaml", "packets:\n  - packet_id: row-a\n")
x = run{ TILLANDSIAS_ROUTING_BASE = "no-such-ref" }
T:arm("2 no base ref: skipped no-diff-base, exit 0, never ok", x.out == "skipped:arrival-routing:no-diff-base" and x.rc == 0, x.why)
x = run{ TILLANDSIAS_PLAN_BIN = g.abs .. "/no-such-binary" }
T:arm("3 no binary: skipped no-plan-binary", x.out == "skipped:arrival-routing:no-plan-binary" and x.rc == 0, x.why)
x = run{ TILLANDSIAS_STUB_STALE = "1" }
T:arm("4 a binary without arrival-routing-check: skipped stale-plan-binary", x.out == "skipped:arrival-routing:stale-plan-binary" and x.rc == 0, x.why)
x = run{ TILLANDSIAS_STUB_MODE = "overlap" }
T:arm("5a overlaps: advisory over distinct rows (2 of 3), exit 0", x.out == "advisory:arrival-routing:2 of 3 new rows" and x.rc == 0, x.why)
T:arm("5b every overlap sentence is on stderr with its predicate", text.contains(x.err, "advisory[owned_files]: row-a owns") and text.contains(x.err, "advisory[title]: row-b"), x.err)
T:arm("5c the rule and both remedies are on stderr", text.contains(x.err, "new_row_only_if_independently_schedulable") and text.contains(x.err, "REMEDY if it is NOT") and text.contains(x.err, "REMEDY if it IS"), x.err)
x = run{ TILLANDSIAS_STUB_MODE = "none" }
T:arm("6 no overlap: ok over the declared population", x.out == "ok:arrival-routing:0 of 3 new rows" and x.rc == 0, x.why)
x = run{ TILLANDSIAS_STUB_MODE = "unreadable" }
T:arm("7 the checker's exit 3: skipped unreadable-fragment, never ok", x.out == "skipped:arrival-routing:unreadable-fragment" and x.rc == 0, x.why)
x = run{ TILLANDSIAS_STUB_MODE = "broken" }
T:arm("8 any other checker exit is a loud fail, exit 1", x.out == "fail:arrival-routing:checker-exit-5" and x.rc == 1, x.why)
x = run{ TILLANDSIAS_STUB_MODE = "nopop" }
T:arm("9 exit 0 with no population is fail checker-exit-0, never a count over nothing", x.out == "fail:arrival-routing:checker-exit-0" and x.rc == 1, x.why)

-- 10: the distinct-row count is what 5a pins. A mutant counting overlap LINES says 3 of 3.
local src = fs.read(g.rel .. "/" .. CHECK)
local mut, k = src:gsub("flagged%[id%] = true", "flagged[#flagged + 1] = true")
if k ~= 1 then T:refuse("mutation-site-not-found", "flagged[id] = true in " .. CHECK) end
fs.write(g.rel .. "/scripts/lua/check-arrival-routing-mutant.lua", mut)
local r = proc.run{ argv = { RUNNER, "script", "run", "scripts/lua/check-arrival-routing-mutant.lua" }, cwd = g.abs,
    env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_PLAN_BIN = stub, TILLANDSIAS_STUB_MODE = "overlap" },
    env_unset = { "TILLANDSIAS_*", "CARGO_TARGET_DIR" }, timeout_ms = 300000 }
local mo = text.trim(((r.stdout or ""):gsub("\r", "")))
T:arm("10 MUTATION counting overlap lines says 3 of 3, so 5a's distinct-row count has teeth", mo == "advisory:arrival-routing:3 of 3 new rows", mo)

T:finish()
