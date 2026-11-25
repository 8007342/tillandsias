-- @trace order:851-gpb5, order:2333-rqjn
--
-- test-gate-stamp-portable-digest.lua — gate-stamp.sh's SHA-256 dispatch. A Mac
-- without sha256sum has only shasum; a bare sha256sum there fails silently and
-- memoization never engages. The digest must be BYTE-IDENTICAL whichever tool
-- computed it, or a host switching tools invalidates every stamp. Ported from
-- the .sh (2333-rqjn).
--
-- A throwaway repo holds a file, a file in a subdirectory and a symlink (readlink
-- hashing is its own call site). S1 computes on the normal PATH; S2 on a farm PATH
-- with every tool gate-stamp needs except sha256sum (shasum is the host's, else
-- a shim onto coreutils). MUTATION CONTROL: the dispatch reverted to a bare
-- sha256sum fails on the farm PATH and still works on the full one.
--
-- Verdict: ok:gate-stamp-portable-digest-fixture:9 | violation:gate-stamp-portable-digest-fixture:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("gate-stamp-portable-digest-fixture")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local STAMP = ROOT .. "/scripts/gate-stamp.sh"
local DROP = { "TILLANDSIAS_*" }
local src = fs.read("scripts/gate-stamp.sh")

local parse = T:run{ SH, "-n", STAMP, timeout_ms = 20000 }
T:arm("gate-stamp-parses", parse.code == 0, parse.stderr)
T:arm("portable-dispatch-present", src:find("GATE_STAMP_SHA256=(shasum -a 256)", 1, true) ~= nil, "no shasum dispatch in gate-stamp.sh")

local W = T:scratch()
local REPO = W.abs .. "/repo"
local function git(...)
    return T:must{ "git", "-C", REPO, "-c", "user.email=fixture@example.invalid", "-c", "user.name=Fixture", "-c", "commit.gpgsign=false", ... }
end
fs.mkdir(W.rel .. "/repo/sub")
T:must{ "git", "init", "-q", "-b", "main", REPO }
fs.write(W.rel .. "/repo/a.txt", "alpha\n")
fs.write(W.rel .. "/repo/sub/b.txt", "beta\n")
T:must{ "ln", "-s", "a.txt", REPO .. "/link" }
git("add", "-A")
git("commit", "-qm", "seed")

-- The farm: what gate-stamp needs, minus sha256sum.
local FARM = W.abs .. "/farm"
fs.mkdir(W.rel .. "/farm")
-- native-argv: names to link into the farm, not a spawn; the farm bash is spawned by its absolute path
for _, t in ipairs({ "bash", "sh", "git", "sort", "cut", "xargs", "readlink", "grep", "sed", "awk", "mktemp", "rm", "cat", "mv",
    "dirname", "basename", "date", "head", "tail", "wc", "tr", "find", "ls", "env" }) do
    local p = fixture.which(t)
    if p then T:must{ "ln", "-s", p, FARM .. "/" .. t } end
end
local shasum, real = fixture.which("shasum"), fixture.which("sha256sum")
if shasum then
    T:must{ "ln", "-s", shasum, FARM .. "/shasum" }
elseif real then
    fs.write(W.rel .. "/farm/shasum", '#!/bin/sh\nif [ "${1:-}" = "-a" ] && [ "${2:-}" = "256" ]; then shift 2; fi\nexec "' .. real .. '" "$@"\n')
    T:must{ "chmod", "+x", FARM .. "/shasum" }
else
    T:refuse("no-sha256-tool", "host has neither shasum nor sha256sum")
end

local function compute(stamp, farm)
    local r
    if farm then
        r = T:run{ FARM .. "/bash", stamp, "compute", cwd = REPO, env = { PATH = FARM }, env_unset = DROP, timeout_ms = 60000 }
    else
        r = T:run{ SH, stamp, "compute", cwd = REPO, env_unset = DROP, timeout_ms = 60000 }
    end
    return r.code, (text.trim(r.stdout or "")), "rc=" .. tostring(r.code) .. " [" .. text.trim(r.stdout or "") .. "] " .. (r.stderr or ""):sub(1, 200)
end

local c1, d1, w1 = compute(STAMP, false)
T:arm("S1-compute-succeeds-on-full-path", c1 == 0 and #d1 == 64 and not d1:find("[^0-9a-f]"), w1)
local hidden = fixture.which("sha256sum", FARM)
T:arm("farm-hides-sha256sum", hidden == nil and fixture.which("shasum", FARM) ~= nil, "sha256sum=" .. tostring(hidden))
local c2, d2, w2 = compute(STAMP, true)
T:arm("S2-compute-succeeds-without-sha256sum", c2 == 0, w2)
T:arm("S2-digest-byte-identical-across-tools", d1 ~= "" and d1 == d2, d1 .. " vs " .. d2)

local mutant, n = src:gsub('"%${GATE_STAMP_SHA256%[@%]}"', "sha256sum")
fs.write(W.rel .. "/gate-stamp-mutant.sh", mutant)
T:arm("mutation-applied", n > 0, "no dispatch call site in gate-stamp.sh")
local MUT = W.abs .. "/gate-stamp-mutant.sh"
local c3, d3, w3 = compute(MUT, true)
T:arm("mutation-control-bare-sha256sum-fails-without-it", c3 ~= 0 or d3 ~= d1, w3)
if real then
    local c4, d4, w4 = compute(MUT, false)
    T:arm("mutation-control-full-path-unchanged", c4 == 0 and d4 == d1, w4)
else
    T:arm("mutation-control-full-path-unchanged (skipped: host has no sha256sum)", true)
end
T:finish({ ok = function(k) return "ok:gate-stamp-portable-digest-fixture:" .. k end })
