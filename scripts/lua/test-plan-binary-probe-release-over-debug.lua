-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:1508-7s4w, order:2080-zcur
--
-- test-plan-binary-probe-release-over-debug.lua — resolve_plan_binary in
-- scripts/plan-binary-probe.sh answers the RELEASE binary over the debug one
-- when both run. LINUX negative control: two runnable stubs, the probe must
-- answer target/release/tillandsias-plan. MSYS arm (Windows Git Bash): an
-- unrunnable ELF at the extensionless release path, the probe must answer the
-- release .exe. Each host runs the arm its kernel can.
-- Keeps the established verdict line the gate step reads:
--   ok:plan-binary-probe-release-over-debug:<p>/<t>
-- Ported from scripts/test-plan-binary-probe-release-over-debug.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-plan-binary-probe-release-over-debug.lua

local fixture = require "common.fixture"
local T = fixture.new("plan-binary-probe-release-over-debug")
local uname = text.trim(proc.run{ argv = { "uname", "-s" } }.stdout or "")
local W = T:scratch()
fs.mkdir(W.rel .. "/target/release"); fs.mkdir(W.rel .. "/target/debug")
fs.write(W.rel .. "/answer.sh", '. "$1"\nresolve_plan_binary\n')
local function answer()
    local r = T:run{ "bash", W.abs .. "/answer.sh", fixture.repo_root() .. "/scripts/plan-binary-probe.sh", cwd = W.abs }
    local got = text.trim(r.stdout or "")
    if got:sub(1, 2) == "./" then got = W.abs .. got:sub(2) end
    return got
end

if uname:find("^MINGW") or uname:find("^MSYS") or uname:find("^CYGWIN") then
    -- MSYS: an unrunnable ELF planted at the extensionless release path must not
    -- win over the release .exe (pre-fix: ./target/debug/tillandsias-plan).
    local real = fixture.plan_bin()
    if not real then T:skip("no-plan-binary") end
    if not real:find("%.exe$") and fs.exists(real .. ".exe") then real = real .. ".exe" end
    fs.write(W.rel .. "/target/release/tillandsias-plan", "\127ELF\2\1\1\0")
    T:must{ "cp", real, W.abs .. "/target/debug/tillandsias-plan.exe" }
    T:must{ "cp", real, W.abs .. "/target/release/tillandsias-plan.exe" }
    T:must{ "touch", "-d", "2020-01-01", W.abs .. "/target/debug/tillandsias-plan.exe" }
    local want = W.abs .. "/target/release/tillandsias-plan.exe"
    local got = answer()
    T:arm("MSYS: with an unrunnable ELF at the release path, the probe answers the release .exe",
        got == want, "the probe answered [" .. got .. "], want " .. want)
    out.line("skip: LINUX arm needs a Linux kernel (negative control runs there)")
else
    for _, d in ipairs{ "release", "debug" } do
        fs.write(W.rel .. "/target/" .. d .. "/tillandsias-plan", '#!/bin/sh\n[ "$1" = capabilities ] && exit 0\nexit 0\n')
        T:must{ "chmod", "+x", W.abs .. "/target/" .. d .. "/tillandsias-plan" }
    end
    local want = W.abs .. "/target/release/tillandsias-plan"
    local got = answer()
    T:arm("LINUX negative control: the order is unchanged, release extensionless answers",
        got == want, "the probe answered [" .. got .. "], want " .. want)
    out.line("skip: MSYS arm needs an MSYS kernel (it runs on Windows Git Bash)")
end
T:finish{
    ok = function(p) return "ok:plan-binary-probe-release-over-debug:" .. p .. "/" .. p end,
    fail = function(n) return "violation:plan-binary-probe-release-over-debug:0/" .. n end,
}
