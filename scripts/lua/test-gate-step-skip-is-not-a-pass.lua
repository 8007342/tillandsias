-- @env PATH HOME TMPDIR XDG_RUNTIME_DIR TOOLBOX_PATH container CARGO_TARGET_DIR TILLANDSIAS_HOST_KIND TILLANDSIAS_SKIP_TOOLBOX
-- @trace order:2343-3ch4, order:1384-bqhy, order:1087-h2z9
--
-- test-gate-step-skip-is-not-a-pass.lua — a gate step that skips at exit 0 is not reported
-- with its STEP_OK. Real `build.sh --gate-steps` over scratch roots. The kit's T:skip exits 0
-- and about fifty steps had such a path when this was written, so a check that never ran read
-- as a pass. The verdict is the last line at column 0: a skipped ARM before an ok line is not it.
--
--   1 a Lua kit skip: named, no STEP_OK, rc 0     2 a shell skip, with why and remedy under it
--   3 CONTROL a real pass prints STEP_OK          4 CONTROL so does a pass that skipped one arm
--   5 a red step that also prints skip: is still refused
--
-- Usage: tillandsias-plan script run scripts/lua/test-gate-step-skip-is-not-a-pass.lua
-- Verdict: ok:gate-step-skip-is-not-a-pass:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("gate-step-skip-is-not-a-pass")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local PASSED = "the planted step passed"
-- build.sh asks these where it runs (forge, toolbox); proc.run scrubs them.
local ENV = { TILLANDSIAS_GATE_STEP_JOBS = "1" }
for _, k in ipairs{ "PATH", "HOME", "TMPDIR", "XDG_RUNTIME_DIR", "TOOLBOX_PATH", "container", "CARGO_TARGET_DIR", "TILLANDSIAS_HOST_KIND", "TILLANDSIAS_SKIP_TOOLBOX" } do
    local v = env.get(k)
    if v and v ~= "" then ENV[k] = v end
end
-- On Windows build.sh re-execs into the builder distro, whose own gate runs this.
if SH ~= "bash" then T:skip("build-sh-re-execs-into-wsl") end
local function gate(runner, body)
    local d = T:scratch()
    fs.mkdir(d.rel .. "/scripts/gate-steps.d"); fs.mkdir(d.rel .. "/scripts/lua")
    local p = runner == "LUA" and "scripts/lua/planted.lua" or "scripts/planted.sh"
    fs.write(d.rel .. "/" .. p, body)
    fs.write(d.rel .. "/scripts/gate-steps.d/100-planted.step", 'STEP_DESC="planted"\nSTEP_' .. runner .. '="' .. p .. '"\nSTEP_ERROR="the planted step failed"\nSTEP_OK="' .. PASSED .. '"\n')
    local r = proc.run{ argv = { SH, ROOT .. "/build.sh", "--gate-steps", d.abs }, cwd = ROOT, env = ENV, stdin = "", timeout_ms = 300000 }
    local o = (r.stdout or "") .. (r.stderr or "")
    return { rc = r.code, has = function(s) return text.contains(o, s) end, why = "rc=" .. tostring(r.code) .. "\n" .. o }
end
local KIT = 'local fixture = require "common.fixture"\nlocal T = fixture.new("planted")\n'
local x = gate("LUA", KIT .. 'T:skip("no-tool")\n')
T:arm("1 a kit skip is a named skip and never STEP_OK", x.rc == 0 and x.has("skip:planted.lua:declared (skip:planted:no-tool;") and not x.has(PASSED), x.why)
x = gate("SCRIPT", 'echo "ok: 1 an arm"\necho "skip:planted:no-tool"\necho "  why: no tool"\necho "  remedy: install it"\nexit 0\n')
T:arm("2 a shell skip with its affordance is one too", x.rc == 0 and x.has("skip:planted.sh:declared (skip:planted:no-tool;") and not x.has(PASSED), x.why)
x = gate("LUA", KIT .. 'T:arm("1 an arm", true)\nT:finish()\n')
T:arm("3 CONTROL a real pass prints STEP_OK", x.rc == 0 and x.has("ok:planted:1 arms") and x.has(PASSED) and not x.has(":declared ("), x.why)
x = gate("LUA", KIT .. 'T:arm("1 an arm", true)\nout.line("skip: 2 no tool here")\nT:finish()\n')
T:arm("4 CONTROL a pass that skipped one arm prints STEP_OK", x.rc == 0 and x.has("skip: 2 no tool here") and x.has(PASSED) and not x.has(":declared ("), x.why)
x = gate("SCRIPT", 'echo "skip:planted:no-tool"\nexit 1\n')
T:arm("5 a red step that prints skip: is still refused", x.rc ~= 0 and x.has("the planted step failed") and not x.has(PASSED), x.why)
T:finish()
