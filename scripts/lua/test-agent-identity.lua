-- @env PATH HOME
-- @trace order:756-hn3a, order:743-mgf3, spec:methodology-accountability, order:2313-gbza
--
-- test-agent-identity.lua — the canonical agent-identity helper. Ported from the .sh of the
-- same name (2313-gbza); same eleven scenarios. The 2026-08-15 breach: a forge image without
-- a hostname executable minted `forge--codex-20260815t162555z` while HOSTNAME and
-- /etc/hostname were both present. The helper must complete the id, or refuse BEFORE a claim.
--
-- Every scenario runs under `env -i` with PATH an EMPTY directory, so nothing the host has
-- can leak in. TILLANDSIAS_ETC_HOSTNAME stands in for /etc/hostname. A refusal must print
-- nothing on stdout: nothing a claim recipe could paste in.
--
-- Usage: tillandsias-plan script run scripts/lua/test-agent-identity.lua
-- Verdict: ok:agent-identity:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("agent-identity")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local d = T:scratch()
for _, p in ipairs{ "nobin", "cwd", "iso/scripts" } do fs.mkdir(d.rel .. "/" .. p) end
fs.write(d.rel .. "/etc-hostname", "Forge-Tillandsias.local\n")
fs.write(d.rel .. "/iso/etc-hostname", "Seam-Host.example\n")
for _, f in ipairs{ "agent-identity.sh", "mo-full-attest.sh" } do fs.write(d.rel .. "/iso/scripts/" .. f, fs.read("scripts/" .. f)) end

-- $1 cwd, $2 script, $3 verb, $4 argument or empty, then NAME=value for env -i.
local SCRIPT = [==[
cd "$1" || exit 90
S=$2 V=$3 A=$4 N=$5; shift 5
exec env -i PATH="$N" "$@" "$BASH" "$S" "$V" ${A:+"$A"} </dev/null
]==]
local function run(cwd, script, verb, arg, ...)
    return proc.run{ argv = { SH, "-s", "--", cwd, script, verb, arg, d.abs .. "/nobin", ... }, stdin = SCRIPT,
        env_unset = { "TILLANDSIAS_*" }, timeout_ms = 30000 }
end
local function id(arg, ...) return run(d.abs .. "/cwd", ROOT .. "/scripts/agent-identity.sh", "id", arg, ...) end
local function why(r) return "rc=" .. tostring(r.code) .. " [" .. text.trim(r.stdout or "") .. "] [" .. text.trim(r.stderr or "") .. "]" end
-- The id is `<prefix><yyyymmddthhmmssz>`, or exactly `prefix` when it ends in z.
local function is(name, arg, prefix, ...)
    local r = id(arg, ...)
    local o = text.trim(r.stdout or "")
    local tail = o:sub(1, #prefix) == prefix and o:sub(#prefix + 1) or "?"
    T:arm(name, r.code == 0 and (tail == "" or tail:find("^%d%d%d%d%d%d%d%dt%d%d%d%d%d%dz$") ~= nil)
        and o:find("^[a-z0-9][a-z0-9-]*[a-z0-9]$") ~= nil, why(r))
end
local function refused(name, reason, ...)
    local r = id("", ...)
    local e = "\n" .. (r.stderr or ""):gsub("\r", "")
    T:arm(name, r.code == 1 and (r.stdout or "") == "" and text.contains(e, "\nrefused:agent-identity:" .. reason .. "\n"), why(r))
end
local FORGE, HOST, CODEX = "TILLANDSIAS_HOST_KIND=forge", "HOSTNAME=forge-tillandsias", "TILLANDSIAS_AGENT=codex"
local WHOLE = "forge-forge-tillandsias-codex-"

is("1 THE BREACH SHAPE: no hostname binary, HOSTNAME present, gives a complete id", "", WHOLE, FORGE, HOST, CODEX)
is("2 HOSTNAME empty falls through to /etc/hostname, domain stripped and case folded", "", WHOLE,
    FORGE, "HOSTNAME=", "TILLANDSIAS_ETC_HOSTNAME=" .. d.abs .. "/etc-hostname", CODEX)
refused("3 CONTROL every identity source absent is refused with an empty stdout", "empty-workstation",
    FORGE, "HOSTNAME=", "TILLANDSIAS_ETC_HOSTNAME=" .. d.abs .. "/absent", CODEX)
refused("4 CONTROL no backend is refused, never invented", "empty-backend", FORGE, HOST)
is("5 an explicit TILLANDSIAS_AGENT_ID is taken whole, sanitized once", "", "linux-macuahuitl-claude-20260815t000000z",
    "HOSTNAME=", "TILLANDSIAS_AGENT_ID=Linux--Macuahuitl__Claude.20260815T000000Z")
refused("6 CONTROL an explicit id that sanitizes to nothing is refused", "empty-explicit-id", "HOSTNAME=", "TILLANDSIAS_AGENT_ID=___")
is("7 a launch-provided workstation outranks HOSTNAME", "", "forge-ws-launch-codex-", FORGE, "TILLANDSIAS_WORKSTATION=ws-launch", "HOSTNAME=other", CODEX)
is("8 the backend argument outranks TILLANDSIAS_AGENT", "claude", "forge-forge-tillandsias-claude-", FORGE, HOST, CODEX)
is("9 hostile characters collapse to the id grammar", "", WHOLE, FORGE, "HOSTNAME=Forge__Tillandsias!!", CODEX)

local r = id("", "HOSTNAME=box", "TILLANDSIAS_AGENT=claude")
local o = text.trim(r.stdout or "")
T:arm("10 a bare host's platform needs no uname", r.code == 0 and o:find("^%a+%-box%-claude%-%d%d%d%d%d%d%d%dt%d%d%d%d%d%dz$") ~= nil
    and ({ linux = 1, macos = 1, windows = 1 })[o:match("^%a+")] ~= nil, why(r))
r = run(d.abs .. "/iso", "scripts/mo-full-attest.sh", "host", "", "TILLANDSIAS_ETC_HOSTNAME=" .. d.abs .. "/iso/etc-hostname")
T:arm("11 mo-full-attest's host label flows through the shared probe", text.trim(r.stdout or "") == "seam-host", why(r))
T:finish()
