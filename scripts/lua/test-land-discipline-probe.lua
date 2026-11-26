-- @trace order:1443-z3vb, spec:branch-discipline, order:2386-lrg1
-- @env PATH
--
-- test-land-discipline-probe.lua — scripts/land-on-platform-branch.sh asks the runtime WHERE
-- to land before any fetch or gate (order 1443-z3vb). Ported from test-land-discipline-probe.sh
-- (2386-lrg1); same ten arms, same order. Scratch projects, each with a copy of the tool and
-- the plan binary on PATH. Every origin is a scratch path (an absent nowhere.git or a scratch
-- bare mirror.git), and a scratch copy carries no build.sh, so no arm can push anywhere real.
--
--   arm 7  a seed AHEAD of reality (level 2 seeded, level 0 observed) warns
--          land:discipline:seed-ahead-of-reality with the missing qualifier and proceeds
--   arm 1  level 2 seeded AND observed, `land main`, unreachable origin: exit 9,
--          refused:land:discipline:default-branch-protected, why:, the seed's remedy, no fetch
--   arm 2  level 0 (no seed), `land main`: land:target:main:from=default:level=0, proceeds
--   arm 3  level 2 on work/1443-z3vb, no argument (forge): land:target:linux-next:from=seed:level=2
--   arm 4  drift (exit 9, both digests) / mirror-agrees / mirror-silent / seed-change-in-flight
--   arm 5  `land feature-x` at level 2: refused:land:discipline:ref-outside-grammar
--   arm 6  no plan binary with the discipline verb: warn:land:discipline:probe-unavailable
--
-- GRAMMAR ok:land-discipline-probe:<n> arms | violation:land-discipline-probe:<n>-failed
--       | refused:land-discipline-probe:<reason>
-- (the .sh's "PASS: land-discipline-probe n/n" is not a verdict word verdict.emit accepts)

local fixture = require "common.fixture"
local T = fixture.new("land-discipline-probe")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary", "no runnable plan binary") end
local caps = T:run{ PLAN, "capabilities", timeout_ms = 30000 }
if not ("\n" .. (caps.stdout or "") .. "\n"):find("\ndiscipline\n", 1, true) then
    T:refuse("no-discipline-verb", PLAN .. " has no discipline verb (stale artifact)")
end
local SEED_SRC = ROOT .. "/.tillandsias/branch-discipline.yaml"
local PATH = env.get("PATH") or ""

local W = T:scratch()
T:must{ "mkdir", "-p", W.abs .. "/bin", W.abs .. "/nobin" }
T:must{ "ln", "-s", PLAN, W.abs .. "/bin/tillandsias-plan" }

-- Hermetic git: no global hooks or identity from the host; TILLANDSIAS_TRUNK_BRANCH unset.
fs.write(W.rel .. "/gitconfig", "[user]\n\tname = t\n\temail = t@example.invalid\n[init]\n\tdefaultBranch = main\n")
local GENV = { GIT_CONFIG_GLOBAL = W.abs .. "/gitconfig", GIT_CONFIG_NOSYSTEM = "1" }
local UNSET = { "TILLANDSIAS_TRUNK_BRANCH", "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL" }
local function envw(extra)
    local e = {}
    for k, v in pairs(GENV) do e[k] = v end
    for k, v in pairs(extra or {}) do e[k] = v end
    return e
end
local function git(extra, ...)
    local spec = { "git", ... }  -- `...` last, or it truncates to one value
    spec.env, spec.env_unset, spec.timeout_ms = envw(extra), UNSET, 60000
    return T:must(spec)
end

local function project(d, seed, branch)
    git(nil, "init", "-q", "-b", branch, d)
    T:must{ "mkdir", "-p", d .. "/scripts" }
    T:must{ "cp", ROOT .. "/scripts/land-on-platform-branch.sh", d .. "/scripts/" }
    if seed then
        T:must{ "mkdir", "-p", d .. "/.tillandsias" }
        T:must{ "cp", SEED_SRC, d .. "/.tillandsias/" }
    end
    git(nil, "-C", d, "add", "-A")
    git(nil, "-C", d, "commit", "-q", "-m", "init")
end
-- land <dir> <path-dir> [args…] -> rc, combined output
local function land(d, pdir, extra, ...)
    local e = { PATH = pdir .. ":" .. PATH }
    for k, v in pairs(extra or {}) do e[k] = v end
    local spec = { SH, "scripts/land-on-platform-branch.sh", ... }
    spec.cwd, spec.env, spec.env_unset, spec.timeout_ms = d, envw(e), UNSET, 300000
    local r = T:run(spec)
    return tostring(r.code), (r.stdout or "") .. "\n" .. (r.stderr or "")
end
local function lines(s) local t = {} for l in (s .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = l end return t end
local function line_eq(s, want) for _, l in ipairs(lines(s)) do if l == want then return true end end return false end
local function starts(s, pre) for _, l in ipairs(lines(s)) do if l:sub(1, #pre) == pre then return true end end return false end
local function lmatch(s, pat) for _, l in ipairs(lines(s)) do if l:find(pat) then return true end end return false end
local function has(s, sub) return s:find(sub, 1, true) ~= nil end
local function digest_of(d)
    local show = T:run{ PLAN, "discipline", "show", "--json", "--root", d, timeout_ms = 30000 }
    local g = T:run{ PLAN, "json", "get", "-r", ".digest", stdin = show.stdout or "", timeout_ms = 30000 }
    return text.trim(g.stdout or "")
end
local function observed_level2(d)
    git({ GIT_AUTHOR_EMAIL = "b@hostb.example", GIT_COMMITTER_EMAIL = "b@hostb.example" },
        "-C", d, "commit", "-q", "--allow-empty", "-m", "second host")
    for _, r in ipairs{ "linux-next", "osx-next", "work/1443-abcd" } do
        git(nil, "-C", d, "update-ref", "refs/remotes/origin/" .. r, "HEAD")
    end
    git(nil, "-C", d, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/linux-next")
end
local BIN, NOBIN, L2, L0 = W.abs .. "/bin", W.abs .. "/nobin", W.abs .. "/l2", W.abs .. "/l0"
local function got(rc, o) return "rc=" .. rc .. " [" .. o .. "]" end

-- ── 7 (before arm 1 makes reality level 2): a seed AHEAD of reality ────────
project(L2, true, "linux-next")
git(nil, "-C", L2, "remote", "add", "origin", W.abs .. "/nowhere.git")
local rc, o = land(L2, BIN, nil, "main", "1")
T:arm("arm 7: a seed ahead of reality warns (naming the missing qualifier) and proceeds instead of refusing",
    starts(o, "land:discipline:seed-ahead-of-reality — warn:discipline:default-branch-protected:seed-ahead-of-reality")
    and lmatch(o, "^  missing: .*integration branch on origin") and starts(o, "land: attempt 1/1")
    and not has(o, "refused:land:discipline"), got(rc, o))

-- ── 1 ───────────────────────────────────────────────────────────────────────
observed_level2(L2)
rc, o = land(L2, BIN, nil, "main", "1")
T:arm("arm 1: level 2 refuses main before any fetch (exit 9, the seed's remedy, the skill named)",
    rc == "9" and line_eq(o, "refused:land:discipline:default-branch-protected") and starts(o, "  why: ")
    and lmatch(o, "^  remedy: push to main denied: .*use /project%-discipline for instructions$")
    and not has(o, "land: attempt") and not has(o, "land:fetch-failed"), got(rc, o))

-- ── 2 ───────────────────────────────────────────────────────────────────────
project(L0, false, "main")
git(nil, "-C", L0, "remote", "add", "origin", W.abs .. "/nowhere.git")
rc, o = land(L0, BIN, nil, "main", "1")
T:arm("arm 2: level 0 lands its default branch unrefused (land:target:main:from=default:level=0, then the attempt)",
    line_eq(o, "land:target:main:from=default:level=0") and starts(o, "land: attempt 1/1")
    and not has(o, "refused:land:discipline"), got(rc, o))

-- ── 3 ───────────────────────────────────────────────────────────────────────
git(nil, "-C", L2, "switch", "-q", "-c", "work/1443-z3vb")
rc, o = land(L2, BIN, { TILLANDSIAS_HOST_KIND = "forge" })
T:arm("arm 3: with no argument on a work ref the seed names linux-next, and the attempt integrates onto it",
    line_eq(o, "land:target:linux-next:from=seed:level=2")
    and line_eq(o, "land: attempt 1/4 — fetch + integrate onto origin/linux-next")
    and not has(o, "onto origin/work/"), got(rc, o))
git(nil, "-C", L2, "switch", "-q", "linux-next")

-- ── 4 ───────────────────────────────────────────────────────────────────────
local real = digest_of(L2)
local fake = string.rep("0", 63) .. "7"
local MIRROR = W.abs .. "/mirror.git"
git(nil, "init", "-q", "--bare", MIRROR)
local blob = text.trim(git(nil, "-C", MIRROR, "hash-object", "-w", SEED_SRC).stdout or "")
git(nil, "-C", L2, "remote", "set-url", "origin", MIRROR)
local function ref(d) return "refs/tillandsias/discipline/2/enforced/" .. d .. "/1700000000" end
git(nil, "-C", MIRROR, "update-ref", ref(fake), blob)
rc, o = land(L2, BIN, nil, "linux-next", "1")
T:arm("arm 4: a published digest the checkout lacks is refused:land:discipline:seed-drift naming both, exit 9",
    rc == "9" and line_eq(o, "refused:land:discipline:seed-drift:mirror=" .. fake .. ":checkout=" .. real)
    and not has(o, "land: attempt"), got(rc, o))
git(nil, "-C", MIRROR, "update-ref", "-d", ref(fake))
git(nil, "-C", MIRROR, "update-ref", ref(real), blob)
rc, o = land(L2, BIN, nil, "linux-next", "1")
T:arm("arm 4: the same digest reads land:discipline:mirror-agrees and proceeds",
    line_eq(o, "land:discipline:mirror-agrees:" .. real) and starts(o, "land: attempt 1/1"), got(rc, o))
git(nil, "-C", MIRROR, "update-ref", "-d", ref(real))
rc, o = land(L2, BIN, nil, "linux-next", "1")
T:arm("arm 4: no published ref reads land:discipline:mirror-silent and proceeds",
    starts(o, "land:discipline:mirror-silent") and starts(o, "land: attempt 1/1"), got(rc, o))
-- The checkout's OWN seed change, ahead of origin/linux-next, is not drift. Pushes go to the
-- scratch MIRROR only.
git(nil, "-C", L2, "push", "-q", "origin", "linux-next")
git(nil, "-C", L2, "fetch", "-q", "origin")
git(nil, "-C", MIRROR, "update-ref", ref(real), blob)
local seed_rel = W.rel .. "/l2/.tillandsias/branch-discipline.yaml"
fs.write(seed_rel, fs.read(seed_rel) .. "# changed\n")
git(nil, "-C", L2, "commit", "-q", "-am", "seed change")
rc, o = land(L2, BIN, nil, "linux-next", "1")
T:arm("arm 4: this checkout's own seed change is land:discipline:seed-change-in-flight, not drift",
    starts(o, "land:discipline:seed-change-in-flight:mirror=" .. real .. ":checkout=")
    and starts(o, "land: attempt 1/1") and not has(o, "refused:land:discipline"), got(rc, o))

-- ── 5 ───────────────────────────────────────────────────────────────────────
git(nil, "-C", L2, "remote", "set-url", "origin", W.abs .. "/nowhere.git")
rc, o = land(L2, BIN, nil, "feature-x", "1")
T:arm("arm 5: a target outside the seed's grammar is refused:land:discipline:ref-outside-grammar",
    rc == "9" and line_eq(o, "refused:land:discipline:ref-outside-grammar") and not has(o, "land: attempt"), got(rc, o))

-- ── 6 ───────────────────────────────────────────────────────────────────────
fs.write(W.rel .. "/nobin/tillandsias-plan", "#!/bin/sh\necho query\n")
T:must{ "chmod", "+x", NOBIN .. "/tillandsias-plan" }
rc, o = land(L2, NOBIN, nil, "main", "1")
T:arm("arm 6: with no discipline verb the probe says probe-unavailable and the tool proceeds as before",
    starts(o, "warn:land:discipline:probe-unavailable")
    and line_eq(o, "land: attempt 1/1 — fetch + integrate onto origin/main"), got(rc, o))

T:finish()
