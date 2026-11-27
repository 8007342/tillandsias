-- @trace spec:methodology-accountability, order:765-dt8h, order:940-f77j, order:1521-y72e, order:1524-w8ys, order:1768-2k56, order:1798-khw6, order:2348-yxde
--
-- test-gate-stamp-scope.lua — a gate stamp declares its SCOPE, and pre-push refuses a
-- push that reaches outside it. Every case drives a REAL `git push` against a REAL bare
-- remote through the REAL hook and reads whether the remote moved: a verdict string
-- cannot tell a refusal from a refusal that pushed anyway. Ported from the .sh
-- (2348-yxde), which read a C:/ TILLANDSIAS_PLAN_BIN as relative; fixture.plan_binary()
-- does not.
--
--    0 the classifier is total: an unknown path is `other`
--    1 a full-scope stamp accepts the push
--    2 LOAD-BEARING: a plan-ledger stamp refuses a push touching crates/ (F5), naming the
--      scope, the missing class and the rerun command
--    3 ... and accepts a push inside its scope, loudly
--    4 a legacy v1 stamp is refused with migration guidance
--    5 an unknown scope token on disk is stale, not permissive
--    6 `write` refuses an unknown class up front (the token is issued first, so the
--      refusal reached is the one under test)
--    7 the 668-2xeh plan-only lane works under no stamp. The lane's fragment validator is
--      named: no macOS host has yq, and the arm then measured tool availability
--    8 a fresh rust-scoped stamp admits a plan-only push through that lane (1521-y72e)
--    9 ... and does not launder a README change beside the fragment
--   10 a remote that MOVED is named as a race, and the same stamp carries the push after
--      fetch + merge (1524-w8ys)
--   11 a tag on a commit already on main skips the stamp (1768-2k56)
--   12 ... a tag on a commit not on main does not
--   13 ... nor does a tag pushed beside a branch, even with both on main
--   14 the observatorium deploy ref on a main commit is exempt too (1798-khw6)
--   15 ... and so is a restore commit carrying its first parent's exact tree
--   16 ... but not a new tree whose first parent is on main
--
-- Verdict: ok:gate-stamp-scope:<n> arms | violation:gate-stamp-scope:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("gate-stamp-scope")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end
local HOOK = '#!/usr/bin/env bash\nexec bash "$(git rev-parse --show-toplevel)/scripts/hooks/pre-push-local-gate.sh" "$@"\n'

-- What each case's script starts from. issue() stands in for the gate, which alone
-- issues the one-shot pass token `write` requires (940-f77j).
local PRELUDE = [[
set -u
commit() { git add -A && git commit -qm "$1" >/dev/null 2>&1; }
issue() { _d="$(bash scripts/gate-stamp.sh compute)" || return 1
  printf 'version 1\ndigest %s\ndispatch check\nissued now\n' "$_d" > "$(git rev-parse --absolute-git-dir)/tillandsias-gate-pass-token"; }
stamp() { issue && bash scripts/gate-stamp.sh write --scope "$1" --dispatch check >/dev/null; }
frag() { printf 'packets: []\n' > "plan/index.d/$1.yaml"; }
code() { printf 'pub fn %s() {}\n' "$1" >> crates/demo/lib.rs; }
]]
-- 1745-ntuq: the lane asks its binary whether it is current; the scratch repo has no
-- validator-surface manifest, so the checkout it is measured against is named.
local BASE = { TILLANDSIAS_SURFACE_ROOT = ROOT }
local LANE = { TILLANDSIAS_SURFACE_ROOT = ROOT, TILLANDSIAS_PLAN_BIN = PLAN }

local Repo = {}
Repo.__index = Repo
function Repo:sh(script, e)
    self.n = self.n + 1
    local f = "/case-" .. self.n .. ".sh"
    fs.write(self.rel .. f, PRELUDE .. script)
    local r = T:run{ SH, self.abs .. f, cwd = self.abs .. "/work", env = e or BASE,
        env_unset = { "TILLANDSIAS_*", "GIT_*", "CARGO_TARGET_DIR" }, timeout_ms = 120000 }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
function Repo:git(...)
    local a = { "git", "-C", self.abs .. "/work" }
    for _, x in ipairs({ ... }) do a[#a + 1] = x end
    return text.trim(T:must(a).stdout or "")
end
function Repo:bare(...)
    local a = { "git", "--git-dir=" .. self.abs .. "/origin.git" }
    for _, x in ipairs({ ... }) do a[#a + 1] = x end
    return T:must(a)
end
function Repo:head(ref) return (self:git("ls-remote", "origin", ref):match("^%x+")) end

-- A throwaway repo with the real scripts, a bare origin and the real hook.
local SCRIPTS = { "scripts/gate-stamp.sh", "scripts/hooks/pre-push-local-gate.sh", "scripts/plan-binary-probe.sh",
    "scripts/check-scorable-obligation-added.sh" }  -- 1069-5sp4: the lane runs it when present
local function repo(tag)
    local d = T:scratch(tag)
    local R = setmetatable({ rel = d.rel, abs = d.abs, n = 0 }, Repo)
    local w = d.rel .. "/work"
    for _, p in ipairs{ "scripts/hooks", "plan/index.d", "plan/loop_status.d", "crates/demo" } do fs.mkdir(w .. "/" .. p) end
    T:must{ "git", "init", "-q", "-b", "main", d.abs .. "/work" }
    -- core.hooksPath is GLOBAL in a forge and replaces .git/hooks: pin it per repo.
    for k, v in pairs{ ["core.hooksPath"] = ".git/hooks", ["user.email"] = "f@t", ["user.name"] = "f", ["core.autocrlf"] = "false", ["commit.gpgsign"] = "false" } do
        R:git("config", k, v)
    end
    for _, p in ipairs(SCRIPTS) do if fs.exists(p) then fs.write(w .. "/" .. p, fs.read(p)) end end
    fs.write(w .. "/plan/index.yaml", "packets: []\n")
    fs.write(w .. "/crates/demo/lib.rs", "pub fn seed() {}\n")
    fs.write(w .. "/README.md", "seed\n")
    R:git("add", "-A"); R:git("commit", "-qm", "base")
    T:must{ "git", "init", "-q", "--bare", "-b", "main", d.abs .. "/origin.git" }
    R:git("remote", "add", "origin", d.abs .. "/origin.git")
    R:git("push", "-q", "origin", "main")
    fs.mkdir(d.rel .. "/hk"); fs.write(d.rel .. "/hk/pre-push", HOOK)
    T:must{ "cp", d.abs .. "/hk/pre-push", d.abs .. "/work/.git/hooks/pre-push" }
    T:must{ "chmod", "+x", d.abs .. "/work/.git/hooks/pre-push" }
    return R
end
local function has(o, s) return o:find(s, 1, true) ~= nil end
local function flat(rc, o, extra) return "rc=" .. tostring(rc) .. " " .. (extra or "") .. " " .. o:gsub("\n", " | ") end

-- push(script, env): run it on a fresh repo, and whether origin's main moved.
local function push(tag, script, e)
    local R = repo(tag)
    local before = R:head("refs/heads/main")
    local rc, o = R:sh(script, e)
    return rc, o, R:head("refs/heads/main") ~= before
end

local r = T:run{ SH, ROOT .. "/scripts/gate-stamp.sh", "classify", cwd = ROOT, stdin = "plan/index.d/x.yaml\ncrates/a/src/lib.rs\nweird-top-level-thing\n" }
T:arm("0 the classifier is total", text.trim(r.stdout or "") == "other\nplan-ledger\nrust", flat(r.code, r.stdout or ""))

local rc, o, moved = push("c1", "code more && commit edit && stamp full && git push origin main 2>&1")
T:arm("1 a full-scope stamp accepts the push", rc == 0 and moved, flat(rc, o))

rc, o, moved = push("c2", "frag frag && code sneak && commit mixed && stamp plan-ledger && git push origin main 2>&1")
T:arm("2 a scoped stamp refuses an out-of-scope push, naming scope, class and rerun", rc ~= 0 and not moved
    and o:find("scoped to .plan%-ledger.") and has(o, "rust") and has(o, "build.sh --check"), flat(rc, o, "moved=" .. tostring(moved)))

rc, o, moved = push("c3", "frag frag && commit frag && stamp plan-ledger && git push origin main 2>&1")
T:arm("3 a scoped stamp accepts a push inside its scope, loudly", rc == 0 and moved
    and has(o, "scoped stamp 'plan-ledger' covers every outgoing change class"), flat(rc, o))

rc, o, moved = push("c4", "code edit && commit edit && bash scripts/gate-stamp.sh compute > .git/tillandsias-gate-stamp && git push origin main 2>&1")
T:arm("4 a legacy v1 stamp refuses with migration guidance", rc ~= 0 and not moved and has(o, "predates scope recording")
    and has(o, "build.sh --check"), flat(rc, o, "moved=" .. tostring(moved)))

rc, o, moved = push("c5", [[frag frag && commit frag && d="$(bash scripts/gate-stamp.sh compute)" \
  && printf 'version 2\ndigest %s\nscope plan-ledger,typo-class\ndispatch check\n' "$d" > .git/tillandsias-gate-stamp && git push origin main 2>&1]])
T:arm("5 an unknown scope token is stale (fail closed)", rc ~= 0 and not moved and has(o, "does not declare a usable scope"), flat(rc, o, "moved=" .. tostring(moved)))

rc, o = repo("c6"):sh("issue && bash scripts/gate-stamp.sh write --scope nonsense 2>&1")
T:arm("6 write refuses an unknown scope class", rc ~= 0 and text.trim(o) == "stale:unknown-scope-class:nonsense", flat(rc, o))

rc, o, moved = push("c7", "frag lane && commit frag && git push origin main 2>&1", LANE)
T:arm("7 the 668-2xeh plan-only lane is intact", rc == 0 and moved and has(o, "plan-only lane clean"), flat(rc, o, "moved=" .. tostring(moved)))

rc, o, moved = push("c8", "stamp rust && frag close && commit close && git push origin main 2>&1", LANE)
T:arm("8 a fresh rust-scoped stamp admits a plan-only push through the lane", rc == 0 and moved and has(o, "plan-only lane clean"), flat(rc, o, "moved=" .. tostring(moved)))

rc, o, moved = push("c9", "printf 'edited\\n' >> README.md && commit readme && stamp rust && frag close && commit close && git push origin main 2>&1", LANE)
T:arm("9 NEGATIVE the lane carries no out-of-scope class", rc ~= 0 and not moved and o:find("scoped to .rust.") and has(o, "changes: docs"), flat(rc, o, "moved=" .. tostring(moved)))

-- 10: another host lands a plan-only commit after this checkout's last fetch.
local R = repo("c10")
rc, o = R:sh([[cd .. && mkdir -p nohooks && git clone -q "$PWD/origin.git" other && cd other && git checkout -q main \
  && git config core.hooksPath "$PWD/../nohooks" && git config user.email o@t && git config user.name o && git config commit.gpgsign false \
  && mkdir -p plan/index.d && frag theirs && git add -A && git commit -qm theirs && git push -q origin main 2>&1]])
if rc ~= 0 then T:refuse("setup-failed", "could not move origin from the second clone: " .. o) end
rc, o = R:sh("code more && commit code && stamp rust && git push origin main 2>&1", LANE)
T:arm("10 a moved remote is refused as a race, not sent to a full gate", rc ~= 0 and has(o, "remote-moved-since-fetch") and not has(o, "Re-run the full gate"), flat(rc, o))
local before = R:head("refs/heads/main")
rc, o = R:sh("git fetch -q origin && git merge -q --no-edit origin/main >/dev/null 2>&1 && git push origin main 2>&1", LANE)
T:arm("10 the same stamp carries the push after fetch + merge", rc == 0 and R:head("refs/heads/main") ~= before, flat(rc, o))

-- 11-16: origin carries a tag on base and a code commit landed on main. Seeding goes
-- straight into the bare remote (a fetch INTO it), so the hook under test is the only one
-- that runs; the local origin/main stays stale on purpose, the hook must fetch main itself.
local function seeded(tag)
    local S = repo(tag)
    S.base = S:git("rev-parse", "HEAD")
    S:bare("update-ref", "refs/tags/stable", S.base)
    if S:sh("code landed && commit landed") ~= 0 then T:refuse("setup-failed", "seed commit") end
    S.next = S:git("rev-parse", "HEAD")
    S:bare("fetch", "-q", S.abs .. "/work", "+refs/heads/main:refs/heads/main")
    return S
end
local EXEMPT = "local gate: tag-on-main"
local DEPLOY = "refs/heads/deploy/observatorium"

local S = seeded("c11")
rc, o = S:sh("stamp plan-ledger && git push -f origin " .. S.next .. ":refs/tags/stable 2>&1")
T:arm("11 a tag on a commit already on main skips the stamp, and says so", rc == 0 and S:head("refs/tags/stable") == S.next and has(o, EXEMPT), flat(rc, o))

S = seeded("c12")
rc, o = S:sh("code unlanded && commit unlanded && git push origin HEAD:refs/tags/v-off-main 2>&1")
T:arm("12 NEGATIVE a tag on a commit not on main keeps the full gate", rc ~= 0 and not S:head("refs/tags/v-off-main") and not has(o, EXEMPT)
    and has(o, "tag-on-main:not-on-main:refs/tags/v-off-main"), flat(rc, o))

S = seeded("c13")
rc, o = S:sh("stamp plan-ledger && git push -f origin " .. S.next .. ":refs/tags/stable " .. S.next .. ":refs/heads/release 2>&1")
T:arm("13 NEGATIVE a tag beside a branch gets no exemption, even with both on main", rc ~= 0 and not has(o, EXEMPT) and S:head("refs/tags/stable") ~= S.next, flat(rc, o))

S = seeded("c14")
rc, o = S:sh("stamp plan-ledger && git push origin " .. S.next .. ":" .. DEPLOY .. " 2>&1")
T:arm("14 a deploy ref on a commit already on main skips the stamp", rc == 0 and S:head(DEPLOY) == S.next and has(o, EXEMPT), flat(rc, o))

S = seeded("c15")
S:bare("update-ref", DEPLOY, S.next)
local restore = S:git("commit-tree", S:git("rev-parse", S.base .. "^{tree}"), "-p", S.base, "-p", S.next, "-m", "restore")
rc, o = S:sh("stamp plan-ledger && git push origin " .. restore .. ":" .. DEPLOY .. " 2>&1")
T:arm("15 a restore commit carrying a main commit's exact tree skips the stamp", rc == 0 and S:head(DEPLOY) == restore, flat(rc, o))

S = seeded("c16")
rc, o = S:sh("git reset -q --hard " .. S.next .. " && code smuggled && commit smuggled && git push origin HEAD:" .. DEPLOY .. " 2>&1")
T:arm("16 NEGATIVE a deploy-ref commit with a new tree keeps the full gate", rc ~= 0 and not S:head(DEPLOY)
    and has(o, "tag-on-main:not-on-main:" .. DEPLOY), flat(rc, o))
T:finish()
