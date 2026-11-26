-- @trace order:1173-a5ng, order:1148-3439, order:2380-psba
-- @env PATH HOME
--
-- test-salvage-refs-ledger.lua — check-salvage-refs-ledger.sh's trunk fallback.
-- Ported from test-salvage-refs-ledger.sh (2380-psba); same seven arms.
--
-- REGIME: hermetic. Each case is its own scratch repo with a REAL, REACHABLE, EMPTY bare
-- origin (an unreachable one makes ls-remote fail, the checker takes its
-- origin-unreachable skip, and the reachability half never runs), a branch standing in for
-- trunk (TILLANDSIAS_SALVAGE_TRUNK_REF), and the checker pointed at it with
-- TILLANDSIAS_SALVAGE_ROOT. Nothing here touches this checkout's ledger or origin.
-- THE RACE (1173-a5ng, yolanda 2026-09-13): a gate on a tree merged BEFORE the marker
-- commit refused while trunk carried the marker; mark-land-delete does not protect it.
-- Ledger line grammar is the checker header's: | utc | ref | sha | ancestry | files |.
--
--   1  unmarked locally + marked on trunk -> ok:...:marker-on-trunk:<ref>, exit 0
--   2  ... and stderr says MERGE TRUNK
--   3  NC: unmarked in BOTH copies still refuses (violation)
--   4  a locally marked line passes without the trunk token
--   5  an unreadable trunk copy REFUSES (a zero-byte `git show` is not "no marker")
--   6  ... and says the behind-tree case could NOT be ruled out
--   7  sweep-salvage-refs.sh states the one-pass-AFTER-the-marker deletion rule
--
-- GRAMMAR ok:salvage-refs-ledger-fixture:<n> arms | violation:salvage-refs-ledger-fixture:<n>-failed
--       | refused:salvage-refs-ledger-fixture:missing-checker

local fixture = require "common.fixture"
local T = fixture.new("salvage-refs-ledger-fixture")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local CHECK = ROOT .. "/scripts/check-salvage-refs-ledger.sh"
if T:run{ "test", "-x", CHECK }.code ~= 0 then T:refuse("missing-checker", CHECK) end

local REF = "salvage/yolanda/20260913-1172-dyvd"
local function line(marked)
    local l = "| 2026-09-13T20:29:00Z | " .. REF .. " | 0123456789abcdef0123456789abcdef01234567 | on:linux-next | 3 |"
    if marked then l = l .. " deleted" end
    return l .. "\n"
end

-- One repo per case, so no arm inherits another's state.
local function repo(local_marked, trunk_marked)
    local d, o = T:scratch("repo"), T:scratch("origin")
    T:must{ "git", "init", "-q", d.abs }
    T:must{ "git", "init", "-q", "--bare", o.abs }
    T:must{ "git", "-C", d.abs, "remote", "add", "origin", o.abs }
    T:must{ "git", "-C", d.abs, "config", "user.email", "t@example.invalid" }
    T:must{ "git", "-C", d.abs, "config", "user.name", "t" }
    T:must{ "git", "-C", d.abs, "config", "commit.gpgsign", "false" }
    fs.mkdir(d.rel .. "/plan"); fs.mkdir(d.rel .. "/plan/salvage-refs.d")
    local led = d.rel .. "/plan/salvage-refs.d/yolanda.md"
    fs.write(led, line(trunk_marked))           -- trunk's copy, committed
    T:must{ "git", "-C", d.abs, "add", "-A" }
    T:must{ "git", "-C", d.abs, "commit", "-qm", "trunk" }
    T:must{ "git", "-C", d.abs, "branch", "-f", "trunk-stand-in" }
    fs.write(led, line(local_marked))           -- the local working copy the checker reads
    return d
end
local function check(d, trunk)
    local r = T:run{ SH, CHECK, cwd = d.abs, env_unset = { "TILLANDSIAS_*" },
        env = { TILLANDSIAS_SALVAGE_ROOT = d.abs, TILLANDSIAS_SALVAGE_TRUNK_REF = trunk or "trunk-stand-in" },
        timeout_ms = 60000 }
    return r.stdout or "", r.code, r.stderr or ""
end
local function has(s, n) return s:find(n, 1, true) ~= nil end

-- 1. the case the row exists for
local o, rc, err = check(repo(false, true))
T:arm("1 unmarked locally + marked on trunk -> ok:...:marker-on-trunk:<ref>, exit 0",
    rc == 0 and has(o, ":marker-on-trunk:" .. REF), "rc=" .. tostring(rc) .. " " .. o)
T:arm("2 the verdict says on stderr what to do about it (merge trunk)",
    has(err:upper(), "MERGE TRUNK"), err:sub(1, 200))

-- 2. NC: an outstanding rescue still refuses (fails if the fallback widens to "trunk has the line")
o, rc = check(repo(false, false))
T:arm("3 NC: absent from the remote and unmarked in BOTH copies still refuses",
    rc ~= 0 and has(o, "violation:salvage-refs-ledger:"), "rc=" .. tostring(rc) .. " " .. o)

-- 3. marked locally: unchanged, never consults trunk
o, rc = check(repo(true, false))
T:arm("4 a locally marked line passes as before, without the trunk token",
    rc == 0 and not has(o, "marker-on-trunk") and o:find("^ok:salvage%-refs%-ledger:") ~= nil,
    "rc=" .. tostring(rc) .. " " .. o)

-- 4. trunk's copy unreadable is not forgiveness
o, rc, err = check(repo(false, true), "refs/heads/no-such-branch")
local refused = rc ~= 0 and has(o, "violation:salvage-refs-ledger:")
T:arm("5 an unreadable trunk copy REFUSES — a zero-byte read is not a clean answer",
    refused, "rc=" .. tostring(rc) .. " " .. o)
T:arm("6 and it says the behind-tree case could not be ruled out, rather than asserting a rescue",
    refused and has(err, "could NOT be ruled out"), err:sub(1, 300))

-- 5. the deletion protocol lives where the delete happens
local SWEEP = "scripts/sweep-salvage-refs.sh"
local sw = fs.exists(SWEEP) and fs.read(SWEEP) or ""
T:arm("7 sweep-salvage-refs.sh states the one-pass-after-the-marker deletion rule",
    has(sw:lower(), "pass after") and has(sw, "1173-a5ng"), fs.exists(SWEEP) and "rule absent" or "sweep script absent")

T:finish()
