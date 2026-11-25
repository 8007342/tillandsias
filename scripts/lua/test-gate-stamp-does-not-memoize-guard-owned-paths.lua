-- @trace order:1127-waxf, order:930-i6x4, order:1036-e5w9, order:1142-85zx, order:1276-mugq, order:2373-f26m
--
-- test-gate-stamp-does-not-memoize-guard-owned-paths.lua — the gate memo tells "nothing
-- moved" from "only the plan ledger moved", so a plan-only commit cannot memoize away the
-- guards written for plan-only commits. Measured 2026-09-12: a planted violation passed
-- ./build.sh --check in 2 s as ok:gate-fresh, its guard never run. It drives gate-stamp.sh,
-- the memo DECISION, in a scratch repository; it cannot run build.sh (it runs inside it), so
-- arm 5 pins the wiring as text. Ported from the .sh (2373-f26m).
--
--   1 the code digest ignores a plan fragment (930-i6x4); the plan digest does not
--   2 nothing moved: whole-gate fresh
--   3 only the ledger moved: ok:gate-fresh-except-plan, never stale (that would re-impose
--     the cost 930-i6x4 removed). 3b plan/issues likewise. 3c a SUBDIRECTORY re-gates.
--     3d the PRE-FIX stamp, rebuilt by content, does not take that lane, or 3b proves nothing
--   4 a stamp with no plan_digest fails closed
--   5 build.sh's partial-memo arm runs both ledger guards and the issue guard
--   6 a plan-only MERGE leaves verify fresh
--   7 staging and committing a NEW executable after the gate is invisible. 9b the pre-fix
--     stamp goes stale there, or 7 proves nothing
--   8 a TRACKED file's staged chmod stales the stamp and movers names it; restoring restores
--   9 core.fileMode=false: the index is the source; update-index --chmod is named
--
-- Verdict: ok:gate-stamp-does-not-memoize-guard-owned-paths:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("gate-stamp-does-not-memoize-guard-owned-paths")
local SH = fixture.posix_shell()
local STAMPER = fs.read("scripts/gate-stamp.sh")
local d = T:git_repo("wc")
local function git(...)
    local argv = { "git", "-C", d.abs }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    return T:must(argv)
end
local function put(p, s)
    local dir = p:match("^(.*)/")
    if dir then fs.mkdir(d.rel .. "/" .. dir) end
    fs.write(d.rel .. "/" .. p, s)
end
local function rm(p) T:must{ "rm", "-f", d.abs .. "/" .. p } end
local function chmod(m, p) T:must{ "chmod", m, d.abs .. "/" .. p } end
local function S(...)
    local argv = { SH, "scripts/gate-stamp.sh" }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    argv.cwd, argv.env_unset = d.abs, { "TILLANDSIAS_*", "GIT_*", "CARGO_TARGET_DIR" }
    return text.trim(T:run(argv).stdout or "")
end
local STAMP = ".git/tillandsias-gate-stamp"
-- The real writer, so the toolchain field is this host's; the one-shot token stands in for
-- the gate that issues it (940-f77j).
local function stamp()
    put(".git/tillandsias-gate-pass-token", "version 1\ndigest " .. S("compute") .. "\ndispatch check\nissued now\n")
    local o = S("write", "--dispatch", "check")
    if o ~= "ok:gate-stamped" then T:refuse("setup-failed", "stamp write said " .. o) end
end
local function first(o) return (o:match("^%S*")) end
local function memo() return first(S("memo-check", "check")) end
local function V() return first(S("verify")) end
local PARTIAL, FRESH = "ok:gate-fresh-except-plan", "ok:gate-fresh"

git("config", "core.autocrlf", "false")
put("scripts/gate-stamp.sh", STAMPER); put("scripts/some-code.sh", "code\n"); put("plan/index.yaml", "packets: []\n")
fs.mkdir(d.rel .. "/plan/index.d"); fs.mkdir(d.rel .. "/plan/loop_status.d")
git("add", "-A"); git("commit", "-qm", "base")

local d0, p0 = S("compute"), S("plan-digest")
put("plan/index.d/20260912t000000z-probe.yaml", "packets: []\n")
local d1, p1 = S("compute"), S("plan-digest")
T:arm("1 a plan fragment does NOT move the code digest (930-i6x4)", d0 ~= "" and d0 == d1, d0 .. " / " .. d1)
T:arm("1 it DOES move the plan digest", p0 ~= "" and p0 ~= p1, p0 .. " / " .. p1)

rm("plan/index.d/20260912t000000z-probe.yaml"); stamp()
local o = memo()
T:arm("2 with both digests matching the memo is whole-gate fresh", o == FRESH, o)
put("plan/index.d/20260912t000001z-moved.yaml", "packets: []\n")
o = memo()
T:arm("3 a plan-only change is the partial verdict, neither fresh nor stale", o == PARTIAL, o)
fs.mkdir(d.rel .. "/plan/issues"); stamp()
put("plan/issues/zzz-probe.md", "a drill record\n")
o = memo()
T:arm("3b a plan/issues-only change takes the same lane", o == PARTIAL, o)
rm("plan/issues/zzz-probe.md"); stamp()
put("plan/issues/research/zzz-nested.md", "a nested record\n")
o = memo()
T:arm("3c a plan/issues SUBDIRECTORY change still stales the stamp", o:find("^stale:"), o)
rm("plan/issues/research/zzz-nested.md"); T:must{ "rmdir", d.abs .. "/plan/issues/research" }

local kept, dropped = {}, 0
for l in STAMPER:gmatch("([^\n]*)\n") do
    if l:find('plan/issues/*.md) case "${path#plan/issues/}"', 1, true) or l:find('find "$REPO_ROOT/plan/issues" -maxdepth 1', 1, true) then dropped = dropped + 1
    else kept[#kept + 1] = l end
end
T:arm("3d the pre-fix reconstruction is real: it strips the skip glob and the digest's find", dropped == 2, dropped .. " line(s) stripped")
put("scripts/gate-stamp.sh", table.concat(kept, "\n") .. "\n"); stamp()
put("plan/issues/zzz-mutant.md", "a drill record\n")
o = memo()
T:arm("3d the pre-fix stamp does NOT put plan/issues on the fast lane", o ~= PARTIAL and o ~= "", o)
rm("plan/issues/zzz-mutant.md"); put("scripts/gate-stamp.sh", STAMPER); stamp()

local without = fs.read(d.rel .. "/" .. STAMP):gsub("plan_digest [^\n]*\n", "")
put(STAMP, without)
o = S("memo-check", "check")
T:arm("4 a stamp with no plan_digest is stale, not assumed unchanged", o == "stale:no-plan-digest-recorded", o)

local arm, on = {}, false
for l in (fs.read("build.sh") .. "\n"):gmatch("([^\n]*)\n") do
    if l:find('"ok:gate-fresh-except-plan "*)', 1, true) then on = true end
    if on then arm[#arm + 1] = l end
    if on and l:find(";;", 1, true) then break end
end
arm = table.concat(arm, "\n")
T:arm("5 build.sh's partial-memo arm runs both ledger guards", arm:find("check-fragment-status-loss.lua", 1, true) and arm:find("strict-fragments", 1, true), "arm: " .. #arm .. " bytes")
T:arm("5 and the issue guard, whose subject joined the lane (1142-85zx)", arm:find("check-issue-citation-convention.sh", 1, true), "absent")

git("checkout", "-q", "-b", "m6-side")
put("plan/index.d/20260928t000001z-side.yaml", "packets: []\n"); put("plan/loop_status.d/20260928-side.md", "loop\n"); put("plan/issues/side-drill.md", "drill\n")
git("add", "-A"); git("commit", "-qm", "side: plan-only")
git("checkout", "-q", "main")
put("scripts/some-code.sh", "code v2\n"); git("add", "-A"); git("commit", "-qm", "code"); stamp()
git("merge", "-q", "--no-edit", "m6-side")
local diff = git("diff", "--name-only", "HEAD^1", "HEAD").stdout or ""
local only_plan = diff ~= ""
for l in diff:gmatch("[^\n]+") do if not l:find("^plan/") then only_plan = false end end
o = V()
T:arm("6 a plan-only merge leaves verify fresh", only_plan and o == FRESH, o .. " diff: " .. diff)

put("scripts/new-guard.sh", "#!/bin/sh\necho new\n"); chmod("+x", "scripts/new-guard.sh"); stamp()
git("add", "scripts/new-guard.sh"); git("commit", "-qm", "new guard")
o = V()
T:arm("7 staging and committing a new executable after the gate is invisible", o == FRESH, o)

chmod("-x", "scripts/new-guard.sh")
local unstaged = V()
git("add", "scripts/new-guard.sh")
local staged, movers = V(), S("movers")
T:arm("8 a tracked file's staged chmod stales the stamp and movers names it", unstaged == FRESH and staged:find("^stale:") and movers == "mode\tscripts/new-guard.sh", unstaged .. " / " .. staged .. " / " .. movers)
chmod("+x", "scripts/new-guard.sh"); git("add", "scripts/new-guard.sh")
o = V()
T:arm("8 restoring the staged bit restores it", o == FRESH, o)

git("config", "core.fileMode", "false"); stamp()
put("scripts/win-new.sh", "#!/bin/sh\necho win\n"); chmod("+x", "scripts/win-new.sh"); stamp()
git("add", "scripts/win-new.sh"); git("commit", "-qm", "win new")
local added = V()
git("update-index", "--chmod=+x", "scripts/win-new.sh")
local edited
edited, movers = V(), S("movers")
git("config", "core.fileMode", "true")
T:arm("9 fileMode=false: a staged new file is invisible, update-index --chmod is named", added == FRESH and edited:find("^stale:") and movers == "mode\tscripts/win-new.sh", added .. " / " .. edited .. " / " .. movers)
git("commit", "-qm", "win chmod")

local mutant, n = STAMPER:gsub('\n        if %[%[ "%$fm" != false %]%]; then\n', "\n        if false; then\n")
T:arm("9b the untracked-is-dash reconstruction is real", n >= 1, n .. " site(s) changed")
put("scripts/gate-stamp.sh", mutant); git("commit", "-qam", "mutant stamper")
put("scripts/mut-guard.sh", "#!/bin/sh\necho mut\n"); chmod("+x", "scripts/mut-guard.sh"); stamp()
git("add", "scripts/mut-guard.sh")
o = V()
T:arm("9b the pre-fix stamp goes stale on arm 7's sequence, so 7 discriminates", o:find("^stale:"), o)
T:finish()
