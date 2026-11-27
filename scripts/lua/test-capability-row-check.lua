-- @env PATH HOME
-- @trace order:859-b2zc, spec:accel-capability-probe, order:2311-xca3
--
-- test-capability-row-check.lua — check-capability-row.sh resolves a host WITHOUT a `hostname`
-- binary, and refuses to publish an EPHEMERAL identity. Ported from the .sh of the same name
-- (2311-xca3); same nine arms. `hostname -s || hostname` answered host-unresolvable in every
-- forge and WSL distro, none of which ships it, so the gate never prompted them.
--
-- `hostname` is a STUB that fails silently, first on PATH: to the call sites
-- (`hostname -s 2>/dev/null ||`) a missing binary and a failing one are the same. The plan
-- binary is a stub serving a canned matrix, and the live-probe half (889-ewvt) is switched
-- off: this is about identity. No forge marker is ever written to the checkout.
--
-- Usage: tillandsias-plan script run scripts/lua/test-capability-row-check.lua
-- Verdict: ok:capability-row-check:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("capability-row-check")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local d = T:scratch()
fs.mkdir(d.rel .. "/bin")
fs.write(d.rel .. "/bin/hostname", "#!/usr/bin/env bash\nexit 1\n")
-- The subject matches ^host:<name><TAB>, so the tab is load-bearing.
fs.write(d.rel .. "/matrix.txt", "capability-matrix: 1 row(s)\nhost:knownbox\tlocus:bare-metal\tkind:linux\n")
fs.write(d.rel .. "/bin/stub-plan", [==[
#!/usr/bin/env bash
case "${1:-}" in
    capabilities)      printf 'compact\ncapability-matrix\n'; exit 0 ;;
    capability-matrix) cat "${0%/bin/*}/matrix.txt"; exit 0 ;;
esac
exit 1
]==])
fs.write(d.rel .. "/etc-hostname", "knownbox\n")
T:must{ "chmod", "+x", d.abs .. "/bin/hostname", d.abs .. "/bin/stub-plan" }

-- Every identity variable is unset first: this process may itself be a forge, and the gate's
-- own TILLANDSIAS_* reach a child (2305-zm8j). Arguments are NAME=value for this case alone.
local SCRIPT = [==[
W=$PWD S=$1; shift
for v in $(compgen -v TILLANDSIAS_); do unset "$v"; done
export PATH="$W/bin:$PATH" TILLANDSIAS_CAPABILITY_LIVE_UNRUNNABLE=1
export TILLANDSIAS_PLAN_BIN="$W/bin/stub-plan" TILLANDSIAS_FORGE_CONTEXT="$W/no-forge-context"
for kv in "$@"; do export "${kv%%=*}=${kv#*=}"; done
exec bash "$S" </dev/null 2>/dev/null
]==]
local function run(...)
    local r = proc.run{ argv = { SH, "-s", "--", ROOT .. "/scripts/check-capability-row.sh", ... }, cwd = d.abs, stdin = SCRIPT, timeout_ms = 60000 }
    return text.trim(r.stdout or "") .. "|" .. tostring(r.code)
end
local function ck(name, want, ...)
    local got = run(...)
    T:arm(name, got == want, "want " .. want .. " got " .. got)
end
local OK, EPHEMERAL = "ok:capability-row-reported:knownbox|0", "HOSTNAME=d872da8c03df"
ck("1 no hostname binary, HOSTNAME known is ok", OK, "HOSTNAME=knownbox")
ck("2 no hostname binary, HOSTNAME unknown is due, not unavailable", "due:no-capability-row:otherbox|1", "HOSTNAME=otherbox")
ck("3 HOSTNAME empty falls through to /etc/hostname", OK, "HOSTNAME=", "TILLANDSIAS_ETC_HOSTNAME=" .. d.abs .. "/etc-hostname")
ck("4 an uppercase node name is lowercased", OK, "HOSTNAME=KnownBox")
ck("5 a FQDN is domain-stripped", OK, "HOSTNAME=knownbox.example.invalid")
ck("6 TILLANDSIAS_WORKSTATION overrides HOSTNAME", OK, "TILLANDSIAS_WORKSTATION=knownbox", "HOSTNAME=otherbox")
ck("7 a forge with no stable identity refuses to publish", "unavailable:forge-identity-ephemeral|2", "TILLANDSIAS_HOST_KIND=forge", EPHEMERAL)
ck("8 a forge WITH TILLANDSIAS_WORKSTATION resolves", OK, "TILLANDSIAS_HOST_KIND=forge", "TILLANDSIAS_WORKSTATION=knownbox", EPHEMERAL)
ck("9 no runnable plan binary is reported, never guessed around", "unavailable:no-runnable-plan-binary|2",
    "HOSTNAME=knownbox", "TILLANDSIAS_PLAN_BIN=" .. d.abs .. "/bin/does-not-exist", "TILLANDSIAS_CAPABILITY_LIVE_UNRUNNABLE=")
T:finish()
