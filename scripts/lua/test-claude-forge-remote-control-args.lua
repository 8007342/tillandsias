-- @trace spec:default-image, order:2080-zcur
--
-- test-claude-forge-remote-control-args.lua — the Claude forge entrypoint joins
-- Remote Control named after TILLANDSIAS_CLAUDE_SESSION_NAME, only when the
-- installed claude advertises --remote-control.
--
-- Arms (stub CC_BIN, function cut out of the entrypoint by name):
--   supported   name set, --help mentions --remote-control -> args appended
--   unsupported name set, --help lacks it                  -> nothing appended
--   unset       no name                                    -> nothing appended
--   wiring      the entrypoint actually calls it
-- Pre-fix: append_claude_remote_control_args does not exist -> refused.
-- Ported from scripts/test-claude-forge-remote-control-args.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-claude-forge-remote-control-args.lua
-- Verdict: ok:claude-forge-remote-control-args:<n> arms | violation:claude-forge-remote-control-args:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("claude-forge-remote-control-args")
local EP = "images/default/entrypoint-forge-claude.sh"
local src = fs.read(EP) or ""

local buf, inside = {}, false
for _, l in ipairs(text.lines(src)) do
    if not inside and l:find("^append_claude_remote_control_args%(%)") then inside = true end
    if inside then
        buf[#buf + 1] = l
        if l == "}" then break end
    end
end
if #buf == 0 then T:refuse("function-missing", "append_claude_remote_control_args missing from " .. EP) end

local W = T:scratch()
fs.write(W.rel .. "/fn.sh", table.concat(buf, "\n") .. "\n")
-- The driver: source the function, seed the args array from $INIT, call it, print count|args.
fs.write(W.rel .. "/drive.sh", table.concat({
    '. "$1"',
    '# shellcheck disable=SC2206 # word-split INIT on purpose', 'claude_forge_args=(${INIT:-})',
    "append_claude_remote_control_args",
    'printf \'%s|%s\\n\' "${#claude_forge_args[@]}" "${claude_forge_args[*]}"',
}, "\n") .. "\n")
fs.write(W.rel .. "/claude-rc", '#!/bin/sh\necho "  --remote-control [name]  Start remote control"\n')
fs.write(W.rel .. "/claude-old", '#!/bin/sh\necho "  -p, --print"\n')
T:must{ "chmod", "+x", W.abs .. "/claude-rc", W.abs .. "/claude-old" }

local function drive(cc, name, init)
    local e = { CC_BIN = W.abs .. "/" .. cc, INIT = init or "" }
    if name then e.TILLANDSIAS_CLAUDE_SESSION_NAME = name end
    local r = T:run{ "bash", W.abs .. "/drive.sh", W.abs .. "/fn.sh", env = e }
    return text.trim(r.stdout or "") .. (r.code ~= 0 and (" rc=" .. tostring(r.code) .. " " .. tostring(r.stderr)) or "")
end

local got = drive("claude-rc", "tillandsias-forge", "--dangerously-skip-permissions")
T:arm("supported: --remote-control and --name appended",
    got == "5|--dangerously-skip-permissions --remote-control tillandsias-forge --name tillandsias-forge", got)
got = drive("claude-old", "tillandsias-forge")
T:arm("unsupported: nothing appended", got == "0|", got)
got = drive("claude-rc", nil)
T:arm("unset: nothing appended", got == "0|", got)

local wired = false
for _, l in ipairs(text.lines(src)) do if l == "append_claude_remote_control_args" then wired = true end end
T:arm("wiring: the entrypoint calls append_claude_remote_control_args", wired, "never called")

T:finish()
