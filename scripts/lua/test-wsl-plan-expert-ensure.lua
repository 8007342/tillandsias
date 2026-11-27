-- @env PATH HOME
-- @trace order:2421-7wvs
--
-- test-wsl-plan-expert-ensure.lua — the Lua outer lane of wsl-plan-expert-ensure answers what the .sh's
-- outer lane answered, and always exits 0 (advisory).
--
--   1 a non-Windows uname is skip:not-windows, exit 0 (the .sh's first outer check)
--   2 (Windows with wsl.exe) a build distro that does not exist is skip:no-build-distro, exit 0
--   3 the .sh run on the host without `inner` no longer re-execs anything: it names the Lua, exit 0
--
-- The live ok:wsl-plan-expert path builds tillandsias-plan inside the guest (minutes), so it is not an
-- arm; measured on doris 2026-11-27: Lua and .sh both ok:wsl-plan-expert:/root/.local/bin/tillandsias-plan.
-- Usage: tillandsias-plan script run scripts/lua/test-wsl-plan-expert-ensure.lua
-- Verdict: ok:wsl-plan-expert-ensure-fixture:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("wsl-plan-expert-ensure-fixture")
local PLAN, ROOT, SH = fixture.plan_binary(), fixture.repo_root(), fixture.posix_shell()
if PLAN == "" then T:refuse("no-plan-binary") end
if not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end

local function ensure(e)
    local r = T:run{ PLAN, "script", "run", ROOT .. "/scripts/lua/wsl-plan-expert-ensure.lua", cwd = ROOT, env = e,
        timeout_ms = 120000 }
    local o = r.stdout or ""
    return r.code, text.trim(o), "rc=" .. tostring(r.code) .. " " .. o .. (r.stderr or ""):sub(1, 200)
end

local rc, o, why = ensure({ TILLANDSIAS_WSL_FAKE_UNAME = "Linux" })
T:arm("1 a non-Windows uname is skip:not-windows, exit 0", rc == 0 and o == "skip:not-windows", why)

if SH ~= "bash" and fixture.which("wsl.exe") then
    rc, o, why = ensure({ TILLANDSIAS_WSL_FAKE_UNAME = "MINGW64_NT-fixture", TILLANDSIAS_WSL_BUILD_DISTRO = "no-such-distro-2421" })
    T:arm("2 a missing build distro is skip:no-build-distro, exit 0", rc == 0 and o == "skip:no-build-distro", why)
else
    out.line("skip: 2 not Windows with wsl.exe")
end

local r3 = T:run{ SH, ROOT .. "/scripts/wsl-plan-expert-ensure.sh", cwd = ROOT, env_unset = { "WSL_DISTRO_NAME" }, timeout_ms = 60000 }
local o3 = text.trim(r3.stdout or "")
T:arm("3 the .sh's host side names the Lua and exits 0", r3.code == 0 and o3:match("^degraded:outer%-lane%-is%-lua") ~= nil
    and text.contains(o3, "scripts/lua/wsl-plan-expert-ensure.lua"), "rc=" .. tostring(r3.code) .. " " .. o3)
T:finish()
