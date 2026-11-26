-- @trace order:851-gpb5, order:2385-psbb
-- @env PATH HOME
--
-- test-pre-push-linux-next-merged.lua — hermetic fixture for
-- scripts/hooks/pre-push-linux-next-merged.sh, the executable half of methodology's
-- pull_merge_cadence.pre_push_gate. Ported from test-pre-push-linux-next-merged.sh
-- (2385-psbb); same seventeen arms. The rule's failure is silent, so the weight is on the
-- REFUSAL and on mutation controls proving it non-vacuous. A real bare "origin" remote:
-- the guard reads refs/remotes/origin/linux-next, which a branch named origin/linux-next
-- would not exercise.
--
--   guard-parses
--   S1  unmerged osx-next push refused (blocked:linux-next-not-merged:osx-next)
--   S2  NEGATIVE-CONTROL twin: merged push allowed (ok:linux-next-merged:1)
--   S3  linux-next itself not gated          S4  a branch deletion not gated
--   S5  windows-next gated too               S6  no origin/linux-next ref: out of scope
--   S7  1259-kn83 subset: plan-only branch behind trunk admitted, naming the trunk sha
--   S8  NEGATIVE CONTROL: the same plus one code file trunk lacks, still refused
--   S9  the measured slow-gate shape admitted
--   scope-mutation-applied / -without-plan-exclude-refuses-S7
--   mutation-applied / mutation-control-neutered-guard-passes-the-breach / -allow-path-unchanged
--   skill-states-the-methodology-gate / skill-no-longer-collides-the-name
--
-- TILLANDSIAS_* is stripped from the guard (it reads none). No build.sh child: gate_inherit n/a.
--
-- GRAMMAR ok:pre-push-linux-next-merged-fixture:<n> arms
--       | violation:pre-push-linux-next-merged-fixture:<n>-failed
--       | refused:pre-push-linux-next-merged-fixture:<reason>

local fixture = require "common.fixture"
local T = fixture.new("pre-push-linux-next-merged-fixture")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local GUARD_REL = "scripts/hooks/pre-push-linux-next-merged.sh"
local SKILL_REL = "skills/meta-orchestration/SKILL.md"
if not fs.exists(GUARD_REL) then T:refuse("guard-missing", GUARD_REL) end
local GUARD = ROOT .. "/" .. GUARD_REL
local W = T:scratch()
local ZERO = string.rep("0", 40)

local r = T:run{ SH, "-n", GUARD }
T:arm("guard-parses", r.code == 0, r.stderr)

local function git(dir, ...)
    local a = { "git", "-C", dir }
    for _, v in ipairs({ ... }) do a[#a + 1] = v end
    return T:must(a)
end
local function head(dir) return text.trim(git(dir, "rev-parse", "HEAD").stdout or "") end
local function ident(dir)
    git(dir, "config", "user.email", "fixture@example.invalid"); git(dir, "config", "user.name", "Fixture")
    git(dir, "config", "commit.gpgsign", "false")
end
local function put(rel, s) fs.write(W.rel .. "/" .. rel, s .. "\n") end
local function commit(dir, msg) git(dir, "add", "-A"); git(dir, "commit", "-qm", msg) end

-- Two-repo topology.
T:must{ "git", "init", "-q", "--bare", W.abs .. "/origin.git" }
git(W.abs, "clone", "-q", W.abs .. "/origin.git", "clone")
local REPO = W.abs .. "/clone"
ident(REPO)
git(REPO, "checkout", "-q", "-b", "linux-next")
put("clone/base.txt", "base"); commit(REPO, "linux-next base")
git(REPO, "push", "-q", "origin", "linux-next")
local BASE_SHA = head(REPO)
put("clone/advance.txt", "advance"); commit(REPO, "linux-next advances")
git(REPO, "push", "-q", "origin", "linux-next")
git(REPO, "checkout", "-q", "-b", "osx-next", BASE_SHA)
put("clone/platform.txt", "platform"); commit(REPO, "platform work without the merge")
local UNMERGED_SHA = head(REPO)

-- guard(path, cwd, url, lref, lsha, rref, rsha) -> rc, stdout (stderr dropped, as the .sh does)
local function guard(path, cwd, url, lref, lsha, rref, rsha)
    local res = T:run{ SH, path, "origin", url, cwd = cwd, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000,
        stdin = string.format("%s %s %s %s\n", lref, lsha, rref, rsha) }
    return res.code, text.trim(res.stdout or "")
end
local function run_guard(path, lref, lsha, rref, rsha)
    return guard(path, REPO, W.abs .. "/origin.git", lref, lsha, rref, rsha)
end
local function g(rc, o) return "rc=" .. tostring(rc) .. " out=" .. o end

local rc, o = run_guard(GUARD, "refs/heads/osx-next", UNMERGED_SHA, "refs/heads/osx-next", ZERO)
T:arm("S1-unmerged-platform-push-refused", rc ~= 0 and o == "blocked:linux-next-not-merged:osx-next", g(rc, o))

git(REPO, "merge", "-q", "--no-edit", "origin/linux-next")
local MERGED_SHA = head(REPO)
rc, o = run_guard(GUARD, "refs/heads/osx-next", MERGED_SHA, "refs/heads/osx-next", ZERO)
T:arm("S2-merged-platform-push-allowed", rc == 0 and o == "ok:linux-next-merged:1", g(rc, o))

rc, o = run_guard(GUARD, "refs/heads/linux-next", UNMERGED_SHA, "refs/heads/linux-next", ZERO)
T:arm("S3-linux-next-not-gated", rc == 0 and o == "ok:linux-next-merged:0", g(rc, o))

rc, o = run_guard(GUARD, "(delete)", ZERO, "refs/heads/osx-next", UNMERGED_SHA)
T:arm("S4-branch-deletion-not-gated", rc == 0 and o == "ok:linux-next-merged:0", g(rc, o))

rc, o = run_guard(GUARD, "refs/heads/windows-next", UNMERGED_SHA, "refs/heads/windows-next", ZERO)
T:arm("S5-windows-next-gated", rc ~= 0 and o == "blocked:linux-next-not-merged:windows-next", g(rc, o))

local PLAIN = W.abs .. "/plain"
T:must{ "git", "init", "-q", PLAIN }
ident(PLAIN); put("plain/x.txt", "x"); commit(PLAIN, "x")
rc, o = guard(GUARD, PLAIN, "https://example.invalid/r.git", "refs/heads/osx-next", head(PLAIN), "refs/heads/osx-next", ZERO)
T:arm("S6-no-linux-next-ref-out-of-scope", rc == 0 and o == "ok:no-linux-next-ref", g(rc, o))

-- 1259-kn83 subset exception: its own topology.
T:must{ "git", "init", "-q", "--bare", W.abs .. "/o2.git" }
git(W.abs, "clone", "-q", W.abs .. "/o2.git", "c2")
local R2 = W.abs .. "/c2"
ident(R2)
git(R2, "checkout", "-q", "-b", "linux-next")
fs.mkdir(W.rel .. "/c2/src"); fs.mkdir(W.rel .. "/c2/plan/index.d")
put("c2/src/code.rs", "v1"); commit(R2, "trunk base")
git(R2, "push", "-q", "origin", "linux-next")
git(R2, "checkout", "-q", "-b", "osx-next")
put("c2/plan/index.d/early.yaml", "osx-only-plan"); commit(R2, "platform plan fragment")
git(R2, "checkout", "-q", "linux-next")
put("c2/src/code.rs", "v2"); commit(R2, "trunk code X")
git(R2, "push", "-q", "origin", "linux-next")
local X_SHA = head(R2)
git(R2, "checkout", "-q", "osx-next")
git(R2, "merge", "-q", "--no-edit", "linux-next")
put("c2/plan/index.d/claim.yaml", "claim"); commit(R2, "claim fragment")
local SUBSET_TIP = head(R2)
git(R2, "checkout", "-q", "linux-next")
put("c2/src/code.rs", "v3"); commit(R2, "trunk code lands mid-gate")
git(R2, "push", "-q", "origin", "linux-next")
git(R2, "fetch", "-q", "origin")
git(R2, "checkout", "-q", "osx-next")
local function run_guard2(path, sha)
    return guard(path, R2, W.abs .. "/o2.git", "refs/heads/osx-next", sha, "refs/heads/osx-next", ZERO)
end

rc, o = run_guard2(GUARD, SUBSET_TIP)
T:arm("S7-plan-only-platform-behind-trunk-admitted-naming-the-trunk-sha",
    rc == 0 and o == "ok:pre-push:platform-subset-of:" .. X_SHA, g(rc, o))

put("c2/src/osx-only.rs", "osx-code"); commit(R2, "platform code trunk lacks")
rc, o = run_guard2(GUARD, head(R2))
T:arm("S8-one-code-file-trunk-lacks-still-refused", rc ~= 0 and o == "blocked:linux-next-not-merged:osx-next", g(rc, o))

rc, o = run_guard2(GUARD, SUBSET_TIP)
T:arm("S9-measured-slow-gate-overtaken-by-a-code-landing-is-admitted", rc == 0, g(rc, o))

-- Mutants are exact-string replacements (plain find, not a pattern), written to scratch;
-- an unchanged copy is a control that proves nothing, so "applied" is its own arm.
local SRC = fs.read(GUARD_REL)
local function mutate(old, new)
    local i, j = SRC:find(old, 1, true)
    if not i then return SRC end
    return SRC:sub(1, i - 1) .. new .. SRC:sub(j + 1)
end
local MUT2_SRC = mutate("-- . ':(exclude)plan/'", "-- .")
fs.write(W.rel .. "/mutant-no-plan-exclude.sh", MUT2_SRC)
T:arm("scope-mutation-applied", MUT2_SRC ~= SRC, "the replacement changed nothing — the control proves nothing")
rc, o = run_guard2(W.abs .. "/mutant-no-plan-exclude.sh", SUBSET_TIP)
T:arm("scope-mutation-without-plan-exclude-refuses-S7", rc ~= 0, g(rc, o))

local MUT_SRC = mutate('git merge-base --is-ancestor "$LINUX_NEXT" "$lsha" 2>/dev/null', "true")
fs.write(W.rel .. "/mutant-guard.sh", MUT_SRC)
T:arm("mutation-applied", MUT_SRC ~= SRC, "the replacement changed nothing — the control proves nothing")
rc, o = run_guard(W.abs .. "/mutant-guard.sh", "refs/heads/osx-next", UNMERGED_SHA, "refs/heads/osx-next", ZERO)
T:arm("mutation-control-neutered-guard-passes-the-breach", rc == 0 and o == "ok:linux-next-merged:1", g(rc, o))
rc, o = run_guard(W.abs .. "/mutant-guard.sh", "refs/heads/osx-next", MERGED_SHA, "refs/heads/osx-next", ZERO)
T:arm("mutation-control-allow-path-unchanged", rc == 0, g(rc, o))

-- Docs pin (851-gpb5): the skill names the methodology key; the colliding phrase stays gone.
if fs.exists(SKILL_REL) then
    local sk = fs.read(SKILL_REL)
    T:arm("skill-states-the-methodology-gate", text.contains(sk, "pull_merge_cadence.pre_push_gate"), SKILL_REL)
    T:arm("skill-no-longer-collides-the-name", not text.contains(sk, "local pre-push gate"), SKILL_REL)
else
    T:arm("skill-pins-skipped (no " .. SKILL_REL .. " here)", true)
end

T:finish()
