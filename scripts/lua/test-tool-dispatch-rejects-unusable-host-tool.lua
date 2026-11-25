-- @env PATH HOME
-- @trace order:1138-bb5r, order:1570-k4fx, order:2361-y7pf
--
-- test-tool-dispatch-rejects-unusable-host-tool.lua — resolve_tool (scripts/lib/tool-dispatch.sh) must not
-- hand back a tool that is PRESENT and cannot RUN. `command -v` speaks for the PATH, not the binary, and a
-- caller of a broken tool passed over nothing. Both tools are fabricated under names no host carries.
-- Ported from the .sh of the same name.
--
-- Usage: tillandsias-plan script run scripts/lua/test-tool-dispatch-rejects-unusable-host-tool.lua
-- Verdict: ok:tool-dispatch-rejects-unusable-host-tool:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("tool-dispatch-rejects-unusable-host-tool")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local LIB = ROOT .. "/scripts/lib/tool-dispatch.sh"
if not fs.exists("scripts/lib/tool-dispatch.sh") then T:refuse("subject-missing") end
local W = T:scratch()

fs.mkdir(W.rel .. "/bin")
fs.write(W.rel .. "/bin/tilde-probe-usable", '#!/bin/sh\n[ "$1" = "--version" ] && { echo "tilde-probe-usable 1.0"; exit 0; }\necho ran\n')
-- The shim shape: installed, resolvable and dead.
fs.write(W.rel .. "/bin/tilde-probe-broken", "#!/bin/sh\necho 'tilde-probe-broken: not installed' >&2\nexit 127\n")
-- The shape every caller has: an empty answer is could-not-run (2), otherwise it scans and passes.
fs.write(W.rel .. "/caller.sh", '. "$1" || exit 9\nT="$(resolve_tool tilde-probe-broken || printf "")"\n'
    .. '[ -n "$T" ] || exit 2\n"$T" --scan >/dev/null 2>&1 || exit 0\nexit 0\n')

-- The PATH is set INSIDE the shell, in the shell's own spelling of the directory.
local PRE = 'lib="$1"; cd "$2" || exit 9; PATH="$PWD/bin:$PATH"; chmod +x bin/* || exit 9\n'
    .. 'command -v tilde-probe-broken >/dev/null && command -v tilde-probe-usable >/dev/null || exit 8\n'
local function sh(body, lib)
    local r = T:run{ SH, "-s", "--", lib or LIB, W.abs, stdin = PRE .. body, env_unset = { "TILLANDSIAS_*" } }
    if r.code == 8 or r.code == 9 then T:refuse("setup-failed", "rc=" .. r.code .. " " .. tostring(r.stderr)) end
    return r.code, r.stdout or ""
end
local function resolve(tool, lib) return sh('. "$lib" || exit 9\nresolve_tool ' .. tool .. " 2>/dev/null\n", lib) end

local rc, got = resolve("tilde-probe-usable")
T:arm("1 CONTROL a usable host tool resolves to its bare name", rc == 0 and got == "tilde-probe-usable", "rc=" .. rc .. " " .. got)
rc, got = resolve("tilde-probe-broken")
T:arm("2 a present but unusable tool is not handed back", got == "", got)
T:arm("3 and the return code says so", rc == 1, "rc=" .. rc)
rc = sh('"$BASH" ./caller.sh "$lib" >/dev/null 2>&1\n')
T:arm("4 its caller reaches could-not-run instead of passing over nothing", rc == 2, "rc=" .. rc)

-- MUTATION: without the usability probe the broken tool comes back and the caller passes.
local src = fs.read("scripts/lib/tool-dispatch.sh"):gsub("\r\n", "\n")
local PROBE = ' \\\n       && "$_rt_tool" $(_tool_probe_args "$_rt_tool") >/dev/null 2>&1; then'
local a, b = src:find(PROBE, 1, true)
if not a then T:refuse("mutation-anchor-missing") end
fs.write(W.rel .. "/noprobe.sh", src:sub(1, a - 1) .. "; then" .. src:sub(b + 1))
rc, got = resolve("tilde-probe-broken", W.abs .. "/noprobe.sh")
T:arm("5 MUTATION without the probe the unusable tool is handed back", rc == 0 and got == "tilde-probe-broken", "rc=" .. rc .. " " .. got)
rc = sh('"$BASH" ./caller.sh "$lib" >/dev/null 2>&1\n', W.abs .. "/noprobe.sh")
T:arm("5 MUTATION and the caller passes having examined nothing", rc == 0, "rc=" .. rc)

T:finish()
