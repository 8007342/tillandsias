-- @trace order:1512-3afc, order:1629-xtfw, order:2333-rqjn
--
-- test-gate-step-prefix-across-refs.lua — check-gate-step-prefix-across-refs.lua
-- against a scratch repo with a bare remote. Trunk holds 100-a.step; the branch
-- under test adds 110-mine.step. Ported from the .sh (2333-rqjn).
--
--   1  another RECENT unlanded ref holds 110 -> refused, naming ref and file, with
--      why/remedy and a free prefix (120)
--   2  the same branch at 120 -> accepted
--   3  NEGATIVE CONTROL the only holder is the branch's own pushed ref -> accepted
--   4  a holder older than the window -> ignored (control: a wide window refuses)
--   5  unrelated free prefixes pass; a prefix on trunk refuses against TRUNK, not
--      the merged work ref that landed it
--   6  no new steps -> ok:no-new-steps
--   7  a collision on 085 is refused (1629-xtfw: an octal error once passed it)
--   8  a collision on 020 suggests 30, the base-10 next ten
--   9  010 collides with a held 10: one prefix in base 10
--  10  no work refs at all -> skip:no-work-refs, never ok
--
-- Verdict: ok:gate-step-prefix-across-refs-fixture:<n>/<n> | violation:gate-step-prefix-across-refs-fixture:<pass>/<n>

local fixture = require "common.fixture"
local T = fixture.new("gate-step-prefix-across-refs-fixture")
local PLAN = fixture.plan_binary()
if PLAN == "" then verdict.emit("could-not-run:gate-step-prefix-across-refs-fixture:no-plan-binary", 3) end
local CHECK = fixture.repo_root() .. "/scripts/lua/check-gate-step-prefix-across-refs.lua"
local W = T:scratch()
local WC = W.abs .. "/wc"
-- A gate's TILLANDSIAS_* names are not this scratch repo's (1592-idmu: its frozen
-- base). The runner's audit log goes beside the clone, whose `add -A` would
-- commit it otherwise (1443-w9hf).
local DROP = { "TILLANDSIAS_*" }
local AUDIT = W.abs .. "/command-policy-audit.jsonl"

local function git(...)
    return T:must{ "git", "-C", WC, "-c", "user.email=t@example.invalid", "-c", "user.name=t", "-c", "commit.gpgsign=false", ... }
end
local function step(...) for _, n in ipairs({ ... }) do fs.write(W.rel .. "/wc/scripts/gate-steps.d/" .. n, 'STEP_SCRIPT="scripts/x.sh"\n') end end
local function commit(msg) git("add", "-A"); git("commit", "-qm", msg) end
local function fresh(b, from)
    git("checkout", "-q", "-B", b, from or "linux-next")
    fs.mkdir(W.rel .. "/wc/scripts/gate-steps.d")
end
local function check(extra)
    local e = { TILLANDSIAS_POLICY_AUDIT_LOG = AUDIT }
    for k, v in pairs(extra or {}) do e[k] = v end
    local r = T:run{ PLAN, "script", "run", CHECK, cwd = WC, env = e, env_unset = DROP, timeout_ms = 120000 }
    local o = text.trim(r.stdout or "")
    return r.code, o, r.stderr or "", "rc=" .. tostring(r.code) .. " [" .. o .. "] err=[" .. (r.stderr or ""):gsub("\n", " ") .. "]"
end
local OK = "ok:gate-step-prefix-across-refs:"
local NO = "refused:gate-step-prefix-across-refs:"
local function starts(s, p) return s:sub(1, #p) == p end

T:must{ "git", "init", "-q", "--bare", W.abs .. "/bare.git" }
T:must{ "git", "init", "-q", "-b", "linux-next", WC }
git("remote", "add", "origin", W.abs .. "/bare.git")
git("config", "core.autocrlf", "false")
fs.mkdir(W.rel .. "/wc/scripts/gate-steps.d")
step("100-a.step"); commit("base"); git("push", "-q", "-u", "origin", "linux-next")
fresh("work/other"); step("110-other.step"); commit("other"); git("push", "-q", "origin", "work/other")
-- an OLD ref holding 130, outside the window
fresh("work/old"); step("130-old.step"); git("add", "-A")
T:must{ "git", "-C", WC, "-c", "user.email=t@example.invalid", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-qm", "old",
    env = { GIT_COMMITTER_DATE = "2020-01-01T00:00:00Z", GIT_AUTHOR_DATE = "2020-01-01T00:00:00Z" } }
git("push", "-q", "origin", "work/old")
-- a ref holding 140, already merged into trunk
fresh("work/landed"); step("140-landed.step"); commit("landed"); git("push", "-q", "origin", "work/landed")
git("checkout", "-q", "linux-next"); git("merge", "-q", "--ff-only", "work/landed"); git("push", "-q", "origin", "linux-next")
fresh("work/mine"); git("fetch", "-q", "origin")

local c, o, e, why = check()
T:arm("6 no new steps is ok", c == 0 and o == OK .. "no-new-steps", why)

step("110-mine.step"); commit("mine")
c, o, e, why = check()
T:arm("1 a prefix held by another recent unlanded ref is refused by name, remedy suggests 120",
    c == 1 and o == NO .. "110-mine.step:origin/work/other:110-other.step"
    and ("\n" .. e):find("\n  why: ", 1, true) ~= nil and ("\n" .. e):find("\n  remedy: [^\n]*120%-mine%.step") ~= nil, why)

-- 3, before renaming: our own pushed ref is the only holder
git("push", "-q", "origin", "work/mine"); git("push", "-q", "origin", "--delete", "work/other"); git("fetch", "-q", "--prune", "origin")
c, o, e, why = check()
T:arm("3 our own pushed ref is not a rival", c == 0 and starts(o, OK), why)

fresh("work/other2"); step("110-other.step"); commit("other2"); git("push", "-q", "origin", "work/other2")
git("checkout", "-q", "work/mine"); git("fetch", "-q", "origin")
git("mv", "scripts/gate-steps.d/110-mine.step", "scripts/gate-steps.d/120-mine.step"); git("commit", "-qm", "rename")
c, o, e, why = check()
T:arm("2 at a free prefix the same branch is accepted", c == 0 and starts(o, OK .. "1 added"), why)

git("mv", "scripts/gate-steps.d/120-mine.step", "scripts/gate-steps.d/130-mine.step"); git("commit", "-qm", "to130")
c, o, e, why = check()
T:arm("4 a holder older than the window is ignored", c == 0 and starts(o, "ok:"), why)
c, o, e, why = check{ TILLANDSIAS_STEP_PREFIX_WINDOW_DAYS = "100000" }
T:arm("4 CONTROL with the window widened the old ref refuses", c == 1 and o == NO .. "130-mine.step:origin/work/old:130-old.step", why)

git("mv", "scripts/gate-steps.d/130-mine.step", "scripts/gate-steps.d/150-mine.step"); git("commit", "-qm", "to150")
step("145-x.step"); commit("extra")
c, o, e, why = check()
T:arm("5 CONTROL unrelated free prefixes are accepted", c == 0 and starts(o, "ok:"), why)
step("140-dup.step"); commit("dup")
c, o, e, why = check()
T:arm("5 a prefix on trunk is refused against trunk, not the merged work ref", c == 1 and o == NO .. "140-dup.step:origin/linux-next:140-landed.step", why)

-- 7, 8, 9: base 10. A rival holds 085, 020 and 10; each arm starts from trunk.
fresh("work/octal"); step("085-r.step", "020-r.step", "10-r.step"); commit("octal"); git("push", "-q", "origin", "work/octal"); git("fetch", "-q", "origin")
-- 085 sorts first, so 110-m behind it (held by work/other2) is no longer hidden.
fresh("work/mine2"); step("085-m.step", "110-m.step"); commit("arm7")
c, o, e, why = check()
T:arm("7 a collision on 085 is refused, not passed as an octal error", c == 1 and o == NO .. "085-m.step:origin/work/octal:085-r.step", why)
fresh("work/mine2"); step("020-m.step"); commit("arm8")
c, o, e, why = check()
T:arm("8 a collision on 020 suggests the base-10 free prefix 30", c == 1 and o == NO .. "020-m.step:origin/work/octal:020-r.step"
    and ("\n" .. e):find("\n  remedy: [^\n]*/30%-m%.step ") ~= nil, why)
fresh("work/mine2"); step("010-m.step"); commit("arm9")
c, o, e, why = check()
T:arm("9 010 collides with a held 10 (one prefix, base 10)", c == 1 and o == NO .. "010-m.step:origin/work/octal:10-r.step", why)

-- 10: a free prefix, so only the empty namespace can make it anything but ok.
fresh("work/mine2"); step("150-m.step"); commit("arm10")
c, o, e, why = check{ TILLANDSIAS_STEP_PREFIX_REFS = "refs/remotes/nowhere/" }
T:arm("10 no work refs at all is a skip, not ok", c == 0 and starts(o, "skip:gate-step-prefix-across-refs:no-work-refs"), why)

local n = T.passed + #T.failed
T:finish({ ok = function(k) return "ok:gate-step-prefix-across-refs-fixture:" .. k .. "/" .. n end,
    fail = function(f) return "violation:gate-step-prefix-across-refs-fixture:" .. (n - f) .. "/" .. n end })
