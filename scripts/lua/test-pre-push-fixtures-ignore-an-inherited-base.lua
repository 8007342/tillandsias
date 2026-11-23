-- @trace order:2242-u39b
--
-- test-pre-push-fixtures-ignore-an-inherited-base.lua — the pre-push-hook
-- fixtures build a scratch checkout and run its hook; they must test THAT
-- checkout, not whatever TILLANDSIAS_GATE_DIFF_BASE the caller left behind.
-- They passed in real gates only because the caller also exports
-- TILLANDSIAS_GATE_DIFF_BASE_ROOT and the hook drops a base frozen in another
-- checkout. This runs each one with a base set and NO _ROOT, the case that
-- guard does not cover, and requires it to stay green.
--
-- Measured before the fix on lenovinha (2026-11-23): 3, 9 and 6 failed arms.
--
-- Verdict: ok:pre-push-fixtures-ignore-inherited-base:<n> | violation:pre-push-fixtures-ignore-inherited-base:<failed>/<n>

-- 2246-fkea helpers: git's root (C:/... on Windows, never `pwd -P`'s /c/...),
-- and the plan binary joined and made native in Lua (yolanda, msys: the old
-- `pwd -P` root + bare bash was a script-error there).
local fixture = require "common.fixture"
local root = fixture.repo_root()
local PB = fixture.plan_binary()
if PB == "" then verdict.emit("could-not-run:pre-push-fixtures-ignore-inherited-base:no-plan-binary", 3) end
local head = text.trim(proc.run{ argv = { "git", "rev-parse", "HEAD" }, cwd = root }.stdout or "")

local FIXTURES = {
    { "scripts/lua/test-lane-instrument-vs-ledger.lua", "ok:lane-instrument-vs-ledger:" },
    { "scripts/lua/test-pre-push-issue-capture-lane.lua", "ok:issue-capture-lane:" },
    { "scripts/lua/test-pre-push-plan-lane-after-merge.lua", "ok:plan-lane-after-merge:" },
}
-- A real commit of THIS checkout, frozen as a gate would, with its _ROOT
-- left unset (proc.run passes TILLANDSIAS_* from the parent, so "" here).
local ENV = { TILLANDSIAS_GATE_DIFF_BASE = head, TILLANDSIAS_GATE_DIFF_BASE_ROOT = "",
    TILLANDSIAS_PLAN_BIN = PB, TILLANDSIAS_SCRIPT_RUNNER_BIN = PB }

local pass, failn = 0, 0
for _, f in ipairs(FIXTURES) do
    local r = proc.run{ argv = { PB, "script", "run", f[1] }, cwd = root, env = ENV, timeout_ms = 900000 }
    local lines = text.lines(text.trim(r.stdout or ""))
    local last = lines[#lines] or ""
    if r.code == 0 and last:find(f[2], 1, true) == 1 then
        pass = pass + 1; out.line("ok:   " .. f[1] .. " stays green with an inherited base (" .. last .. ")")
    else
        failn = failn + 1; out.line("FAIL: " .. f[1] .. " tested the caller's base, not its scratch checkout (rc=" .. tostring(r.code) .. "): " .. last)
    end
end

local total = pass + failn
if failn == 0 then verdict.ok("pre-push-fixtures-ignore-inherited-base:" .. total) end
verdict.emit("violation:pre-push-fixtures-ignore-inherited-base:" .. failn .. "/" .. total, 1)
