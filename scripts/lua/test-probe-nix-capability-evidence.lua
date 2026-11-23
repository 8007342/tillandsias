-- @trace order:917-zkge, order:2247-fb89
--
-- test-probe-nix-capability-evidence.lua — the nix-capability probe's EVIDENCE
-- must survive a noisy shell. Ported whole from
-- scripts/test-probe-nix-capability-evidence.sh (2247-fb89); arms and
-- assertions unchanged.
--
-- Third-generation defect in probe-nix-capability.sh, found by pirria 2026-08-30:
-- the capable branch captured `nix --version 2>&1 | head -1`, which merges the
-- invoking shell's stderr ahead of nix's stdout. On a host with a chatty
-- ~/.bashrc, head -1 returned the rc warning — pirria's capable row carried a
-- brew-not-found message as its proof that nix answered.
--
-- The verdict was never wrong (exit status branches correctly). The EVIDENCE was,
-- silently, on exactly the hosts with noisy shells. This pins the capture in
-- isolation, with a deliberately noisy command standing in for the noisy shell.
--
--   1 the defect itself: stderr must not become the evidence
--   2 the defect's shape reproduced (2>&1 then first line), so arm 1 has teeth
--   3 version not on the first stdout line: position must not be trusted
--   4 nothing recognisable: say so rather than present noise as a version
--   5 the SHIM branch keeps merging stderr, with its note (there, the error IS
--     the evidence)
--
-- Verdict: ok:probe-nix-capability-evidence:<n> arms | violation:probe-nix-capability-evidence:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("probe-nix-capability-evidence")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local PROBE = "scripts/probe-nix-capability.sh"

-- The helper under test, as the probe defines it: the version line is found
-- in stdout only, by content, never by position.
local HELPER = [[
_nix_version_evidence() {
    local _out
    _out="$("$@" 2>/dev/null)" || true
    grep -m1 -iE 'nix.*[0-9]+\.[0-9]+' <<<"$_out" && return 0
    printf 'answered, but printed no recognisable version line'
}
]]

local W = T:scratch("fakes")
local function fake(name, body)
    fs.write(W.rel .. "/" .. name, "#!/usr/bin/env bash\n" .. body)
    T:must{ "chmod", "+x", W.abs .. "/" .. name }
    return W.abs .. "/" .. name
end
local function evidence(bin)
    local r = T:run{ SH, "-s", cwd = ROOT, env = { BIN = bin },
        stdin = HELPER .. '_nix_version_evidence "$BIN" --version\n' }
    return text.trim(r.stdout or "")
end

-- A "nix" whose shell is noisy: warnings on stderr BEFORE the real version.
local noisy = fake("noisy-nix", 'echo "bash: brew: command not found" >&2\necho "warning: some rc noise" >&2\necho "nix (Nix) 2.34.8"\n')

local got = evidence(noisy)
T:arm("1 a noisy shell's stderr does not become the evidence",
    got == "nix (Nix) 2.34.8" and not got:lower():find("brew") and not got:lower():find("warning"),
    got)

-- The old capture, stdout and stderr merged in arrival order, first line kept.
-- Read in Lua, so the harness never takes the SIGPIPE the .sh had to dodge.
local old = T:run{ SH, "-s", env = { BIN = noisy }, stdin = '"$BIN" --version 2>&1\n' }
local old_way = (text.lines(old.stdout or "")[1]) or ""
T:arm("2 the old 2>&1 first-line capture still reproduces the defect",
    old_way ~= "nix (Nix) 2.34.8", "old capture=" .. old_way)

local banner = fake("banner-nix", 'echo "some banner line"\necho "nix (Nix) 2.34.8"\n')
got = evidence(banner)
T:arm("3 the version is found by content, not by line position", got == "nix (Nix) 2.34.8", got)

local mute = fake("mute-nix", 'echo "totally unrelated output"\n')
got = evidence(mute)
T:arm("4 nothing recognisable is said, never presented as a version",
    got:find("no recognisable version line", 1, true) ~= nil, got)

T:arm("5 the shim branch keeps its deliberate stderr capture and its note",
    fs.exists(PROBE) and (fs.read(PROBE) or ""):find("Deliberately 2>&1 HERE", 1, true) ~= nil,
    PROBE)

T:finish()
