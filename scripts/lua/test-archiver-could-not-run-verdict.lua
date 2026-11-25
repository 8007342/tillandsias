-- @env PATH HOME
-- @trace order:965-sxec, order:2285-jvg6
--
-- test-archiver-could-not-run-verdict.lua — order 965-sxec, ported from the .sh
-- of the same name (2285-jvg6); same four arms.
--
-- A gate that cannot RUN a check must never assert what the check would have
-- FOUND. Measured on lenovinha-tillandsias-forge 2026-09-02: the forge ships no
-- ruby by design, archive-plan-packets.sh exited 127, and build.sh printed "the
-- plan archiver would CHANGE THE READY SET ..." about a command that never ran.
-- This pins the verdict TEXT: the exit code was never the defect.
--
--   1 CODE    no usable ruby -> exit 3 (could-not-run), not a bare 127
--   2 TOKEN   the skip-eligible cause is tokenised; a stale plan binary also
--             exits 3 and must not be skip-eligible
--   3 SILENT  nothing is claimed about the ready set on a run that measured nothing
--   4 ROUTE   the gate step skips only in a forge AND only on the token
--   5 TEETH   each of arms 2 and 4 reds when its needle is cut from its subject
--
-- The forge's condition is reproduced: a `ruby` ON PATH that cannot execute
-- (a brew shim), and `toolbox` shadowed the same way so the fallback arm does
-- not resolve either. An emptied PATH would exercise a different bug.
--
-- Usage: tillandsias-plan script run scripts/lua/test-archiver-could-not-run-verdict.lua
-- Verdict: ok:archiver-could-not-run-verdict:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("archiver-could-not-run-verdict")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local S = T:scratch()
fs.mkdir(S.rel .. "/bin")
for _, c in ipairs{ "ruby", "toolbox" } do
    fs.write(S.rel .. "/bin/" .. c, '#!/bin/sh\necho "' .. c .. ': not installed (965-sxec fixture)" >&2\nexit 127\n')
    T:must{ "chmod", "+x", S.abs .. "/bin/" .. c }
end
local TOKEN, ROUTE = "could-not-run:no-usable-ruby", 'env.get("TILLANDSIAS_HOST_KIND") == "forge"'
local has = text.contains

-- ORDER 560: the Lua worker is the default; the no-ruby path is the ruby opt-in.
local r = proc.run{ argv = { SH, ROOT .. "/scripts/archive-plan-packets.sh", "--check" }, cwd = ROOT, timeout_ms = 300000,
    env = { PATH = S.abs .. "/bin:" .. env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_ARCHIVER_BACKEND = "ruby" } }
local o = (r.stdout or "") .. (r.stderr or "")
T:arm("1 CODE no usable ruby exits 3, not a bare 127", r.status == "exited" and r.code == 3, "rc=" .. tostring(r.code) .. " " .. o:sub(1, 300))
T:arm("2 TOKEN the skip-eligible cause is tokenised", has(o, TOKEN), o:sub(1, 300))
T:arm("3 SILENT no ready-set claim on a check that could not run", not has(o:upper(), "CHANGE THE READY SET"), o:sub(1, 300))
local step = fs.read("scripts/lua/check-archiver-ready-set.lua")
local function routed(s) return has(s, TOKEN) and has(s, ROUTE) end
T:arm("4 ROUTE the step skips only in a forge and only on the token", routed(step), "needles missing")
local cut_route = (step:gsub(ROUTE:gsub("%p", "%%%0"), "true"))
local cut_token = (step:gsub(TOKEN:gsub("%p", "%%%0"), "could-not-run"))
-- the token is in the real script, so arm 2 reads its output and not a constant
local src = fs.read("scripts/archive-plan-packets.sh")
local mut, n = src:gsub(TOKEN:gsub("%p", "%%%0"), "could-not-run:unnamed")
T:arm("5 TEETH cutting a needle reds its arm", not routed(cut_route) and not routed(cut_token) and n >= 1 and not has(mut, TOKEN),
    "n=" .. n .. " route=" .. tostring(routed(cut_route)) .. " token=" .. tostring(routed(cut_token)))
T:finish()
