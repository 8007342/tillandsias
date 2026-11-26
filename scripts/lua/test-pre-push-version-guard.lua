-- @trace spec:versioning, order:2375-psb9
-- @env PATH HOME
--
-- test-pre-push-version-guard.lua — hermetic fixture for scripts/hooks/pre-push-version-guard.sh
-- (order 643-64bx). Ported from test-pre-push-version-guard.sh (2375-psb9); same nine cases.
--
-- main's VERSION is the release identity and a platform branch must not move it, yet a guard
-- that must be bypassed trains --no-verify (which also disables the local gate). Both
-- directions are pinned. A scratch repo carries the three-tier topology: branch names with a
-- slash are legal refs, so origin/main and origin/linux-next resolve without a remote.
--
--   1  a platform branch that merged linux-next (carrying its VERSION) pushes
--   2  RETIRED NEGATIVE: a well-formed strictly-greater bump committed alone pushes (643-64bx exc. 5)
--   3  a range not touching VERSION pushes
--   4  a release bump on main is allowed
--   5  NEGATIVE a bump LOWER than linux-next is refused
--   6  NEGATIVE a bump below the target's previous VERSION (non-monotonic) is refused
--   7  NEGATIVE a malformed VERSION (month 13) is refused
--   8  NEGATIVE a malformed VERSION (legacy 0.4.YYMMDD.N) is refused
--   9  NEGATIVE a mixed-content bump (VERSION + unrelated file, 702-eusw) is refused
--
-- GRAMMAR ok:pre-push-version-guard:<n> arms | violation:pre-push-version-guard:<n>-failed
--       | refused:pre-push-version-guard:<reason>

local fixture = require "common.fixture"
local T = fixture.new("pre-push-version-guard")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local GUARD = ROOT .. "/scripts/hooks/pre-push-version-guard.sh"
if not fs.exists("scripts/hooks/pre-push-version-guard.sh") then T:refuse("subject-missing", GUARD) end

local W = T:scratch()
local function git(...)
    local argv = { "git", "-C", W.abs, ... }
    return T:must(argv)
end
local function head() return text.trim(git("rev-parse", "HEAD").stdout or "") end
local function version(v) fs.write(W.rel .. "/VERSION", v .. "\n") end

git("init", "-q", ".")
git("config", "user.email", "fixture@example.invalid")
git("config", "user.name", "Fixture")
git("config", "commit.gpgsign", "false")
git("symbolic-ref", "HEAD", "refs/heads/main")
version("56.9.10.1"); fs.write(W.rel .. "/file.txt", "seed\n")
git("add", "-A"); git("commit", "-qm", "seed at release identity")
local MAIN = head()
git("branch", "origin/main", MAIN)

-- linux-next runs ahead of main between releases: the documented normal state.
git("checkout", "-q", "-b", "origin/linux-next", MAIN)
version("56.9.12.1"); git("commit", "-qam", "linux-next build counter")

-- The push git would describe: "<lref> <lsha> <rref> <rsha>" on stdin. True when allowed.
local function guard(branch, remote_sha, local_sha)
    git("checkout", "-q", branch)
    local r = T:run{ SH, GUARD, "origin", "https://example.invalid/repo.git", cwd = W.abs,
        env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000,
        stdin = string.format("refs/heads/%s %s refs/heads/%s %s\n", branch, local_sha, branch, remote_sha) }
    return r.code == 0, "rc=" .. tostring(r.code) .. " " .. text.trim((r.stdout or "") .. (r.stderr or ""))
end

-- 1: refusing this makes the merge the pre-push gate REQUIRES produce an unpushable branch.
git("checkout", "-q", "-b", "windows-next", MAIN)
fs.write(W.rel .. "/platform.txt", "work\n")
git("add", "-A"); git("commit", "-qm", "platform work")
git("merge", "-q", "--no-edit", "origin/linux-next")
local CATCHUP = head()
local ok, got = guard("windows-next", MAIN, CATCHUP)
T:arm("1 platform branch carrying linux-next's VERSION pushes", ok, got)

-- 2: RETIRED negative control. Until 2026-09-17 this asserted refusal; the operator's ruling
-- made the build counter monotonic on any branch, so an isolated strictly-greater bump pushes.
version("56.9.12.2"); git("commit", "-qam", "platform-local counter bump, alone")
ok, got = guard("windows-next", MAIN, head())
T:arm("2 a monotonic build bump committed alone pushes", ok, got)

-- 3: commits that do not touch VERSION are none of the guard's business.
git("checkout", "-q", "-B", "windows-next", CATCHUP)
fs.write(W.rel .. "/platform.txt", fs.read(W.rel .. "/platform.txt") .. "more\n")
git("commit", "-qam", "ordinary work, VERSION untouched")
ok, got = guard("windows-next", CATCHUP, head())
T:arm("3 range not touching VERSION pushes", ok, got)

-- 4: main is where a release bump lands.
git("checkout", "-q", "-B", "main", MAIN)
version("56.9.13.1"); git("commit", "-qam", "release bump on main")
ok, got = guard("main", MAIN, head())
T:arm("4 release bump on main allowed", ok, got)

-- 5-9: what exception 5 must still refuse. Each starts from the catch-up branch.
local function refuse(n, why, sha, remote)
    local allowed, g = guard("windows-next", remote or CATCHUP, sha)
    T:arm(n .. " " .. why .. " refused", not allowed, g)
end
git("checkout", "-q", "-B", "windows-next", CATCHUP)
version("56.9.11.9"); git("commit", "-qam", "lower than linux-next")
refuse(5, "a bump LOWER than linux-next", head())

-- 6 NEGATIVE CONTROL: above linux-next (56.9.12.1) yet BACKWARDS on the branch it lands on.
-- "Equal" has no arm: ending on the target's value is case 3, on linux-next's is case 1.
git("checkout", "-q", "-B", "windows-next", CATCHUP)
version("56.9.12.5"); git("commit", "-qam", "target's earlier bump"); local PRIOR = head()
version("56.9.12.4"); git("commit", "-qam", "backwards on the target")
refuse(6, "a bump BELOW the target's previous VERSION (non-monotonic)", head(), PRIOR)

git("checkout", "-q", "-B", "windows-next", CATCHUP)
version("56.13.12.2"); git("commit", "-qam", "month 13")
refuse(7, "a MALFORMED VERSION (month 13)", head())
git("checkout", "-q", "-B", "windows-next", CATCHUP)
version("0.4.260812.2"); git("commit", "-qam", "legacy shape")
refuse(8, "a MALFORMED VERSION (legacy 0.4.YYMMDD.N shape)", head())

git("checkout", "-q", "-B", "windows-next", CATCHUP)
version("56.9.12.2"); fs.write(W.rel .. "/platform.txt", fs.read(W.rel .. "/platform.txt") .. "swept\n")
git("commit", "-qam", "bump swept in with work")
refuse(9, "a MIXED-CONTENT bump (VERSION + unrelated file, 702-eusw)", head())

T:finish()
