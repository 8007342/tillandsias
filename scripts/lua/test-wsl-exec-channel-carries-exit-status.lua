-- @env PATH HOME
-- @trace order:1155-jurn, order:2332-ae6r
--
-- test-wsl-exec-channel-carries-exit-status.lua — scripts/lib-wsl-exec.sh sends known answers
-- through the wsl.exe hop and refuses when they do not come back. Ported from the .sh of the same
-- name. The .sh judged a copy of the comparison; here the real function runs against a stub
-- wsl.exe, so every host exercises it. The first lib version probed its own shell and passed over
-- a hop that zeroed every status: arm 5 pins that the probe goes THROUGH the hop.
--
-- Usage: tillandsias-plan script run scripts/lua/test-wsl-exec-channel-carries-exit-status.lua
-- Verdict: ok:wsl-exec-channel-fixture:<n> arms | violation:wsl-exec-channel-fixture:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("wsl-exec-channel-fixture")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local LIB = "scripts/lib-wsl-exec.sh"
if not fs.exists(LIB) then T:refuse("lib-missing", LIB) end
local body = fs.read(LIB):gsub("\r\n", "\n")
local W = T:scratch()

-- The shell's stdin is the script, so anything that reads stdin gets /dev/null.
local function sh(script, lib)
    local r = T:run{ SH, "-s", cwd = ROOT, stdin = ". ./" .. (lib or LIB) .. "\n" .. script .. "\n" }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
-- A stub wsl.exe: it logs its argv, answers <b> to the exit-7 probe and <a> to the other.
local LOG = W.rel .. "/calls"
local function stub(a, b)
    return 'wsl.exe() { printf "%s\\n" "$*" >> "' .. LOG .. '"; case "$*" in *"exit 7"*) printf "'
        .. b .. '\\n" ;; *) printf "' .. a .. '\\n" ;; esac; }\n'
end
local CALL = "wsl_exec_transport_ok some-distro </dev/null"
local OK = "ok:wsl-exec-transport:carries-exit-status:some-distro"
local DROPS = "refused:wsl-exec-transport:drops-exit-status:some-distro"

local rc1, o1 = sh(stub("1", "7") .. "wsl_exec_transport_ok </dev/null")
T:arm("1 a missing distro refuses with rc 1",
    rc1 == 1 and text.contains(o1, "refused:wsl-exec-transport:no-distro-named"), o1)
local rc2, o2 = sh("PATH=/nonexistent-wsl-exec\nwsl_exec_transport_ok some-distro")
T:arm("2 no wsl.exe is a named skip, not a pass",
    rc2 == 0 and text.trim(o2) == "skip:wsl-exec-transport:no-wsl-on-this-host", o2)
T:arm("3 the lib says to run it BEFORE the measurement",
    text.contains(body, "run it BEFORE the measurement it protects"), "instruction missing")

local rc4, o4 = sh(stub("1", "7") .. CALL)
T:arm("4 a sound pair passes", rc4 == 0 and text.trim(o4) == OK, o4)
local refusal = ""
for _, c in ipairs{ { "0", "0", "the msys shape (0,0)" }, { "", "", "a pair of empty answers" },
    { "1", "0", "a pair sound only in the first" }, { "0", "7", "a pair sound only in the second" } } do
    local rc, o = sh(stub(c[1], c[2]) .. CALL)
    T:arm("4 " .. c[3] .. " refuses", rc == 1 and text.contains(o, DROPS), o)
    refusal = o
end

fs.write(LOG, "")
sh(stub("1", "7") .. CALL)
local calls = fs.read(LOG)
T:arm("5 both probes go through the hop with $? in the argument string",
    text.contains(calls, '-d some-distro -- bash -lc false; echo "$?"')
    and text.contains(calls, '-d some-distro -- bash -lc ( exit 7 ); echo "$?"'), calls)
for _, want in ipairs{ "it is the argument string that is", "script FILE", "MSYS_NO_PATHCONV", "MSYS2_ARG_CONV_EXCL" } do
    T:arm("6 the refusal says: " .. want, text.contains(refusal, want), refusal)
end

-- MUTATION: a lib that probes its own shell passes over a hop that answers 0.
local local_probe, n = body:gsub('wsl%.exe %-d "%$distro" %-%- bash %-lc', "bash -c")
if n ~= 2 then T:refuse("mutation-anchor-missing", "hop probes found: " .. tostring(n)) end
fs.write(W.rel .. "/local.sh", local_probe)
local rc7, o7 = sh(stub("0", "0") .. CALL, W.rel .. "/local.sh")
T:arm("7 MUTATION a local probe passes over a hop that drops statuses", rc7 == 0 and text.trim(o7) == OK, o7)

-- The live hop, on an msys host with wsl.exe. Either verdict is a finding the canary can make.
local _, live = sh('case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) wsl_exec_transport_ok tillandsias-build </dev/null ;;'
    .. " *) echo skip:not-msys ;; esac")
live = text.trim(live)
T:arm("8 live: the real hop gives one of its verdicts, or skips by name",
    live == "skip:not-msys" or live == "skip:wsl-exec-transport:no-wsl-on-this-host"
    or live:find("^ok:wsl%-exec%-transport:carries%-exit%-status:") ~= nil
    or live:find("^refused:wsl%-exec%-transport:drops%-exit%-status:") ~= nil, live)

T:finish()
