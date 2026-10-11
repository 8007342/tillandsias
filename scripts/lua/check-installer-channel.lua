-- @trace spec:ci-release, order:1614-5x7m
-- @env TILLANDSIAS_RELEASE_BASE
--
-- check-installer-channel.lua — resolve the release base URL an installer WOULD
-- use, without installing anything. Ported from scripts/check-installer-channel.sh
-- (the shell-to-lua carried obligation paid by 1614-5x7m).
--
-- Order 621-2re2. The litmus that guards channel selection used to grep for a
-- literal default expression in the installers. That pinned an expression, not a
-- property: introducing the unstable channel changed the expression while every
-- property the check existed to protect still held, so the guard failed for the
-- wrong reason. A grep cannot tell those two cases apart. This can: it executes
-- the installer's own channel-resolution prologue and reports the answer.
--
-- The prologue is everything from the REPO assignment through the line that
-- assigns the resolved base. Both installers are written so this range is
-- side-effect free: it defines variables and helper functions, parses "$@"
-- (empty here), and performs no I/O. It still runs in bash, fed on stdin to
-- `bash -s` (the runner refuses `bash -c` strings), under a cleared environment
-- that carries only the channel asked for and TILLANDSIAS_RELEASE_BASE, which
-- still overrides everything (the curl-install smoke pins one release with it).
--
-- Usage:
--   tillandsias-plan script run scripts/lua/check-installer-channel.lua -- <installer-path> [channel]
--
-- Verdicts (one line on stdout):
--   ok:installer-channel:base:https://...                                   exit 0
--   refused:installer-channel:no-installer:<path>                           exit 1
--   refused:installer-channel:no-base-resolved:<path> (no REPO=..RELEASE_BASE= range)  exit 1
--   refused:installer-channel:unknown-channel:<path> channel=<c>            exit 1

local INSTALLER = arg[1] or ""
local CHANNEL = arg[2] or ""

if INSTALLER == "" or not fs.exists(INSTALLER) then
    verdict.emit("refused:installer-channel:no-installer:" .. (INSTALLER ~= "" and INSTALLER or "<empty>"), 1)
end

local prologue, on = {}, false
for l in (fs.read(INSTALLER) .. "\n"):gmatch("(.-)\n") do
    if not on and l:match("^REPO=") then on = true end
    if on then
        prologue[#prologue + 1] = l
        if l:match("^RELEASE_BASE[%u_]*=") then break end
    end
end
if #prologue == 0 then
    verdict.emit("refused:installer-channel:no-base-resolved:" .. INSTALLER .. " (no REPO=..RELEASE_BASE= range)", 1)
end

local envt = {}
if CHANNEL ~= "" then envt.TILLANDSIAS_CHANNEL = CHANNEL end
local pin = env.get("TILLANDSIAS_RELEASE_BASE") or ""
if pin ~= "" then envt.TILLANDSIAS_RELEASE_BASE = pin end

-- `set --` clears positional args so the installers' flag loops see none.
local script = "set --\n" .. table.concat(prologue, "\n") ..
    '\nprintf "%s\\n" "${RELEASE_BASE:-${RELEASE_BASE_LATEST:-}}"\n'
local r = proc.run({ argv = { "bash", "-s" }, stdin = script, env = envt, timeout_ms = 10000 })
local base = text.trim(r.stdout or "")

if base:sub(1, 8) == "https://" and not base:find("%s") then
    verdict.ok("installer-channel", "base", base)
end
verdict.emit("refused:installer-channel:unknown-channel:" .. INSTALLER ..
    " channel=" .. (CHANNEL ~= "" and CHANNEL or "<default>"), 1)
