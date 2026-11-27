-- @env PATH HOME
-- @trace order:1150-q462, order:1175-wuwr, order:2359-a3c5
--
-- test-competing-gate-consumer.lua — with-tillandsias-builder.sh, the consumer of
-- check-no-competing-gate.sh, answers each of its exit codes differently and never stops the build.
-- Ported from the .sh of the same name (2359-a3c5). The case block is cut from the shipped wrapper and
-- driven with a stub check, under the wrapper's own `set -euo pipefail` in its own process: an
-- extracted block tested under other options is a test of a shell nobody runs (1175-wuwr).
--
--   1 the block is there     2 0 is clean, 1 warns, 2 names the call site, 3 is not a clean verdict
--   3 2 and 3 differ         4 an unknown code is reported    5 every code completes the block
--
-- Usage: tillandsias-plan script run scripts/lua/test-competing-gate-consumer.lua
-- Verdict: ok:competing-gate-consumer:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("competing-gate-consumer")
local SRC = "\n" .. fs.read("scripts/with-tillandsias-builder.sh"):gsub("\r", "")
local a = SRC:find("\n    _cg_rc=0\n", 1, true)
local _, z = SRC:find("\n    esac\n", a or 1, true)
if not a or not z then T:refuse("extraction-empty", "the consumer's case block is not in the wrapper") end
local d = T:scratch()
fs.write(d.rel .. "/case.sh", SRC:sub(a + 1, z))
-- Returns what the consumer printed and whether the block ran to its end.
local function drive(code, says, strict)
    fs.write(d.rel .. "/check-no-competing-gate.sh", "#!/usr/bin/env bash\nprintf '%s\\n' \"" .. says .. "\"\nexit " .. code .. "\n")
    local r = T:run{ fixture.posix_shell(), "-s", cwd = d.abs, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 30000,
        stdin = "chmod +x check-no-competing-gate.sh\n" .. (strict and "set -euo pipefail\n" or "") .. '_tb_self_dir="$PWD"\n. ./case.sh\necho consumer-block-completed\n' }
    local o = (r.stdout or "") .. (r.stderr or "")
    return o, r.code == 0 and text.contains(o, "consumer-block-completed"), "rc=" .. tostring(r.code) .. " " .. o
end
local function says(name, code, text_in, ...)
    local want = { ... }
    for _, strict in ipairs{ false, true } do
        local o, done, why = drive(code, text_in, strict)
        local hit = false
        for _, w in ipairs(want) do hit = hit or text.contains(o, w) end
        T:arm("2 " .. name .. (strict and " (set -e)" or ""), hit and done, why)
    end
end
T:arm("1 the consumer's case block is cut from the shipped wrapper", text.contains(SRC:sub(a, z), "case "), SRC:sub(a, z))
says("0 reports the clean answer", 0, "ok:no-competing-gate", "ok:no-competing-gate")
says("1 warns the run may be raced", 1, "competing-gate: a build.sh is running in this checkout", "may be raced")
says("2 names the call site as the thing to fix", 2, "refused:competing-gate:x", "call site", "caller-contract")
says("3 is not a clean verdict", 3, "could-not-run:competing-gate:blind (...)", "NOT a clean-room verdict", "could not be asked")
local o2, _, w2 = drive(2, "X", true)
local o3, _, w3 = drive(3, "X", true)
T:arm("3 2 and 3 answer differently", o2 ~= o3, w2 .. " | " .. w3)
local o9, done9, w9 = drive(9, "something new", true)
T:arm("4 an unknown code is reported", text.contains(o9, "unrecognised") and done9, w9)
local stopped = {}
for _, c in ipairs{ 0, 1, 2, 3, 9 } do
    local _, done = drive(c, "x", true)
    if not done then stopped[#stopped + 1] = tostring(c) end
end
T:arm("5 no code stops the build", #stopped == 0, "stopped on: " .. table.concat(stopped, " "))
T:finish()
