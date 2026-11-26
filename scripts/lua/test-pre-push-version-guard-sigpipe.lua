-- @trace spec:methodology-accountability, order:702-pwhc, order:2380-psba
-- @env PATH HOME
--
-- test-pre-push-version-guard-sigpipe.lua — scripts/hooks/pre-push-version-guard.sh reaches
-- a verdict on a LARGE diff. Ported from test-pre-push-version-guard-sigpipe.sh (2380-psba);
-- same four arms.
--
-- THE BUG (measured 2026-08-13): `git diff --name-only "$r" | grep -qx VERSION` under
-- pipefail. grep -q exits on the first match, git dies of SIGPIPE (141), pipefail makes the
-- `if` FALSE because the match was found early: the guard failed OPEN as a function of diff
-- size. So the load-bearing case is the large one: VERSION sorts first, and ~120 KB of long
-- path names keeps git writing when grep exits (12 KB did not reproduce; 28 KB did).
-- Hermetic: a scratch repo with a local refs/remotes/origin/main; nothing real is touched.
--
--   1  LOAD-BEARING: a large (>500 file) VERSION-changing range is refused
--   2  the same range to a NEW branch (all-zero remote sha) is refused
--   3  NEGATIVE CONTROL: a range that does not touch VERSION is allowed
--   4  sync-forward (VERSION back to main's value) over a large range is allowed
--
-- GRAMMAR ok:pre-push-version-guard-sigpipe:<n> arms | violation:pre-push-version-guard-sigpipe:<n>-failed
--       | refused:pre-push-version-guard-sigpipe:guard-missing | refused:pre-push-version-guard-sigpipe:setup-failed

local fixture = require "common.fixture"
local T = fixture.new("pre-push-version-guard-sigpipe")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local GUARD = ROOT .. "/scripts/hooks/pre-push-version-guard.sh"
if not fs.exists("scripts/hooks/pre-push-version-guard.sh") then T:refuse("guard-missing", GUARD) end

local R = T:git_repo()
local function git(...) return T:must{ "git", "-C", R.abs, ... } end
local function head() return text.trim(git("rev-parse", "HEAD").stdout or "") end
-- 2000 long-named files in <dir>, one write each (setup, not the subject).
local function filler(dir)
    T:must{ SH, "-s", "--", dir, cwd = R.abs, timeout_ms = 120000, stdin =
        'mkdir -p "$1"; i=0\nwhile [ "$i" -lt 2000 ]; do printf "filler %s\\n" "$i" > "$1/some-reasonably-long-filename-to-pad-the-diff-output-$i.txt"; i=$((i + 1)); done\n' }
end

fs.write(R.rel .. "/VERSION", "0.0.0.1\n")
git("add", "VERSION"); git("commit", "-qm", "base: VERSION 0.0.0.1")
local BASE = head()
git("update-ref", "refs/remotes/origin/main", BASE)

git("checkout", "-q", "-b", "work")
fs.write(R.rel .. "/VERSION", "0.0.0.2\n")
filler("many")
git("add", "-A"); git("commit", "-qm", "bump VERSION and touch many files")
local BIG = head()

local function guard(branch, l, r)
    return T:run{ SH, GUARD, "origin", "https://example.test/repo.git", cwd = R.abs, timeout_ms = 120000,
        stdin = "refs/heads/" .. branch .. " " .. l .. " refs/heads/target " .. r .. "\n" }.code
end

local n = 0
for _ in (git("diff", "--name-only", BASE .. ".." .. BIG).stdout or ""):gmatch("[^\n]+") do n = n + 1 end
if n <= 500 then T:refuse("setup-failed", "fixture too small to exercise the SIGPIPE path (" .. n .. " files)") end

local rc = guard("work", BIG, BASE)
T:arm("1 large range (" .. n .. " files) changing VERSION refused", rc ~= 0, "rc=" .. tostring(rc) .. " — failing open (702-pwhc)")
rc = guard("work", BIG, string.rep("0", 40))
T:arm("2 large range to a new branch changing VERSION refused", rc ~= 0, "rc=" .. tostring(rc))

git("checkout", "-q", "-b", "no-version-change", BASE)
fs.write(R.rel .. "/unrelated.txt", "unrelated\n")
git("add", "unrelated.txt"); git("commit", "-qm", "change nothing that matters")
rc = guard("no-version-change", head(), BASE)
T:arm("3 NC: push not touching VERSION allowed", rc == 0, "rc=" .. tostring(rc) .. " — must not block ordinary work")

git("checkout", "-q", "-b", "sync-forward", BASE)
filler("many2")
fs.write(R.rel .. "/VERSION", "0.0.0.9\n")
git("add", "-A"); git("commit", "-qm", "diverge VERSION")
fs.write(R.rel .. "/VERSION", "0.0.0.1\n")    -- back to main's: a catch-up, not a bump
git("add", "VERSION"); git("commit", "-qm", "sync forward to main's VERSION")
rc = guard("sync-forward", head(), BASE)
T:arm("4 sync-forward (VERSION == main's) allowed", rc == 0, "rc=" .. tostring(rc))

T:finish()
