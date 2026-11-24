-- @trace order:1508-7s4w, order:1680-yf9z, order:1637-arwp
--
-- On MSYS (Git Bash) an extensionless candidate whose .exe sibling exists IS
-- that .exe (exe magic). resolve_plan_binary used to try
-- ./target/debug/tillandsias-plan before ./target/release/tillandsias-plan.exe,
-- so with an unrunnable file at the extensionless release path it answered the
-- DEBUG build ahead of a fresh release one (measured on yolanda 2026-09-29).
-- Lua port of the .sh.
--
--   MSYS arms   a scratch target/ with runnable release and debug .exe files and
--               an unrunnable ELF header at target/release/tillandsias-plan: the
--               probe answers the release .exe; a copy of the probe without the
--               .exe-sibling guard answers the DEBUG build (the control)
--   other arm   runnable extensionless release and debug stubs: the probe still
--               answers the release one, so the order there is unchanged
--
-- The stubs are exe COPIES on MSYS because only a real .exe runs there. The ELF
-- is written by the native runner, which has no exe magic to redirect it.
--
-- Usage: tillandsias-plan script run scripts/lua/test-plan-binary-probe-release-over-debug.lua
-- Verdict: ok:plan-binary-probe-release-over-debug:<n> arms | violation:...:<n>
--        | refused:plan-binary-probe-release-over-debug:no-plan-binary

local fixture = require "common.fixture"
local T = fixture.new("plan-binary-probe-release-over-debug")
local PROBE = "scripts/plan-binary-probe.sh"
local W = T:scratch()
local REL = W.rel .. "/target/release/tillandsias-plan"
local DBG = W.rel .. "/target/debug/tillandsias-plan"
fs.mkdir(W.rel .. "/target/release")
fs.mkdir(W.rel .. "/target/debug")

local ROOT = fixture.repo_root()
local function shell(script, args)
    local spec = { fixture.posix_shell(), "-s", "--", cwd = ROOT, stdin = script }
    for _, a in ipairs(args) do spec[#spec + 1] = a end
    return T:run(spec)
end

-- 1637-arwp: the resolver answers absolute, in the shell's own spelling of W.
-- 1680-yf9z: the "//" is macOS's TMPDIR spelling, so every host exercises it.
local function answer(probe)
    local r = shell([=[
unset CARGO_TARGET_DIR TILLANDSIAS_PLAN_BIN
. "$1" || exit 97
cd "$2//" && cd "$PWD" || exit 98
got="$(resolve_plan_binary 2>/dev/null)" || got=""
printf '%s' "${got#"$PWD"/}"
]=], { probe, W.abs })
    return text.trim(r.stdout or "")
end

local kernel = text.trim(shell("uname -s\n", {}).stdout or "")
if kernel:find("^MINGW") or kernel:find("^MSYS") or kernel:find("^CYGWIN") then
    local real = fixture.plan_binary()
    if real == "" then T:refuse("no-plan-binary") end
    if not real:find("%.exe$") then real = real .. ".exe" end
    T:must{ fixture.posix_shell(), "-s", "--", real, W.abs, cwd = ROOT,
        stdin = 'cp -- "$1" "$2/target/debug/tillandsias-plan.exe" && cp -- "$1" "$2/target/release/tillandsias-plan.exe"\n'
            .. 'touch -d 2020-01-01 -- "$2/target/debug/tillandsias-plan.exe"\n' }
    fs.write(REL, "\127ELF\002\001\001\000")
    local size = #(fs.read(REL) or "")
    T:arm("setup: the unrunnable file is its own file beside the .exe", size == 8, "size=" .. size)
    local got = answer(PROBE)
    T:arm("MSYS: the probe answers the release .exe past the unrunnable ELF",
        got == "target/release/tillandsias-plan.exe", "answered [" .. got .. "]")

    local src = fs.read(PROBE):gsub("\r\n", "\n")
    local GUARD = '*) [ -e "$candidate.exe" ] && continue ;;'
    local s, e = src:find(GUARD, 1, true)
    T:arm("the guard is where the control cuts it", s ~= nil and src:find(GUARD, e + 1, true) == nil, "guard line moved")
    if s then
        fs.write(W.rel .. "/probe.sh", src:sub(1, s - 1) .. "*) ;;" .. src:sub(e + 1))
        got = answer(W.abs .. "/probe.sh")
        T:arm("MSYS control: without the guard the DEBUG build is answered",
            got == "target/debug/tillandsias-plan", "answered [" .. got .. "]")
    end
    out.line("skip: the other arm needs a kernel without exe magic")
else
    for _, p in ipairs{ REL, DBG } do fs.write(p, "#!/bin/sh\nexit 0\n") end
    T:must{ "chmod", "+x", W.abs .. "/target/release/tillandsias-plan", W.abs .. "/target/debug/tillandsias-plan" }
    local got = answer(PROBE)
    T:arm("the order is unchanged: release extensionless answers",
        got == "target/release/tillandsias-plan", "answered [" .. got .. "]")
    out.line("skip: the MSYS arms need an MSYS kernel (they run on Windows Git Bash)")
end

T:finish()
