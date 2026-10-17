-- @trace order:1756-z3kz
-- @env PATH TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-embedded-elf-arch.lua — scripts/lua/check-embedded-elf-arch.lua on
-- constructed binaries (ELF headers built byte by byte, no toolchain needed):
--   1 MATCH     an x86_64 outer binary embedding two x86_64 images: ok, embedded=2
--   2 MISMATCH  an aarch64 outer binary embedding one x86_64 image (the
--               v56.10.16.2 defect): violation naming x86_64@<offset>, exit 1
--   3 DECOY     a "\127ELF" constant with an invalid header is not an image
--               (NEGATIVE CONTROL for arm 2's matcher): ok, embedded=1
--   4 MIN       a binary embedding nothing, asked for at least 2: refused
--   5 NOT-ELF   a file that is not ELF: could-not-run, exit 3
--
-- Usage: tillandsias-plan script run scripts/lua/test-embedded-elf-arch.lua

local SUBJECT = "scripts/lua/check-embedded-elf-arch.lua"
local PLAN = env.get("TILLANDSIAS_PLAN_BIN")
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("embedded-elf-arch-fixture", "no plan binary named (TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("embedded-elf-arch-fixture", "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/embedded-elf-arch-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

-- elf(machine) -> a 64-byte little-endian ELF64 executable header for <machine>
local function elf(machine)
    return "\127ELF" .. string.char(2, 1, 1) .. string.rep("\0", 9)
        .. string.char(2, 0) .. string.char(machine % 256, machine // 256)
        .. string.char(1, 0, 0, 0) .. string.rep("\0", 40)
end
local PAD = string.rep("x", 4096)
local X86, ARM64 = 0x3E, 0xB7

local function run(name, bytes, min)
    fs.write(REL .. "/" .. name, bytes)
    local argv = { PLAN, "script", "run", SUBJECT, "--", REL .. "/" .. name }
    if min then argv[#argv + 1] = tostring(min) end
    local r = proc.run({ argv = argv, cwd = ROOT, timeout_ms = 60000 })
    return r.code or -1, text.trim(r.stdout or "")
end

local rc, o = run("match", elf(X86) .. PAD .. elf(X86) .. PAD .. elf(X86) .. PAD)
arm("1 MATCH an x86_64 binary embedding two x86_64 images passes",
    rc == 0 and o:find("ok:embedded-elf-arch:match:x86_64:embedded=2", 1, true) ~= nil, rc .. " " .. o)

local off = #elf(ARM64) + #PAD
rc, o = run("mismatch", elf(ARM64) .. PAD .. elf(X86) .. PAD)
arm("2 MISMATCH an aarch64 binary embedding an x86_64 image is refused, naming its offset",
    rc == 1 and o:find("violation:embedded-elf-arch:mismatch:aarch64:mismatch=1:x86_64@" .. off, 1, true) ~= nil, rc .. " " .. o)

rc, o = run("decoy", elf(ARM64) .. PAD .. "\127ELF" .. string.rep("\255", 60) .. PAD .. elf(ARM64) .. PAD)
arm("3 DECOY a \\127ELF constant with an invalid header is not counted",
    rc == 0 and o:find("ok:embedded-elf-arch:decoy:aarch64:embedded=1", 1, true) ~= nil, rc .. " " .. o)

rc, o = run("empty", elf(X86) .. PAD, 2)
arm("4 MIN a binary embedding nothing, asked for at least 2, is refused",
    rc == 1 and o:find("violation:embedded-elf-arch:empty:x86_64:embedded=0<min=2", 1, true) ~= nil, rc .. " " .. o)

rc, o = run("notelf", "#!/bin/sh\necho hi\n")
arm("5 NOT-ELF a file that is not ELF is could-not-run",
    rc == 3 and o:find("could-not-run:embedded-elf-arch", 1, true) ~= nil, rc .. " " .. o)

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("refused:embedded-elf-arch-fixture:" .. #failed .. "-of-5", 1)
end
verdict.emit("ok:embedded-elf-arch-fixture:5", 0)
