-- @trace order:1162-qbrx, order:2375-ch7i
--
-- test-gate-step-prefix-allocation.lua — a gate-step prefix the integrate took is
-- reallocated at land time, so two lands that chose one prefix both land. Scratch
-- repositories; the land is the integrate (merge) then allocate-gate-step-prefix.sh --base
-- <tip> --commit. Arm 9 EXECUTES the land tool's own block against a stub allocator: a
-- grep for the call passed for a commented-out one. Ported from the .sh (2375-ch7i).
--
-- Verdict: PASS: gate-step-prefix-allocation <n>/<n> (1162-qbrx) (the litmus reads it), then
--          ok:gate-step-prefix-allocation:<n> | violation:gate-step-prefix-allocation:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("gate-step-prefix-allocation")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local ALLOC, LAND, STEPS = "scripts/allocate-gate-step-prefix.sh", "scripts/land-on-platform-branch.sh", "scripts/gate-steps.d/"
if not fs.exists(ALLOC) then T:refuse("absent", ALLOC) end
local UNSET = { "TILLANDSIAS_*", "GIT_*" }
local R -- the current scratch repository
local function G(...)
    local a = { "git", "-C", R.abs, ... }
    a.env_unset = UNSET
    return T:must(a)
end
local function git(...)
    local a = { "git", "-C", R.abs, ... }
    a.env_unset = UNSET
    return text.trim(T:run(a).stdout or "")
end
local function write(name, body) fs.write(R.rel .. "/" .. STEPS .. name, body) end
local function step(name) write(name, ('STEP_DESC="%s"\nSTEP_SCRIPT="scripts/test-%s.sh"\n'):format(name, name)) end
local function commit(m) G("add", "-A"); G("commit", "-qm", m) end
local function branch(name, files, at)
    if at then G("checkout", "-q", "-b", name, at) else G("checkout", "-q", "-b", name) end
    for _, f in ipairs(files) do step(f) end
    commit(name .. " adds steps")
end
local function repo(tag, ...)
    R = T:git_repo(tag)
    G("config", "core.autocrlf", "false")
    fs.mkdir(R.rel .. "/" .. STEPS)
    for _, p in ipairs{ ... } do write(p .. "-base-" .. p .. ".step", 'STEP_SCRIPT="scripts/test-base-' .. p .. '.sh"\n') end
    commit("baseline")
end
local function alloc(...)
    local a = { SH, ROOT .. "/" .. ALLOC, ... }
    a.cwd, a.env_unset = R.abs, UNSET
    local r = T:run(a)
    local l = text.lines(text.trim(r.stdout or ""))
    return l[#l] or "", r.code, r.stdout or "", r.stderr or ""
end
local function has(n) return fs.exists(R.rel .. "/" .. STEPS .. n) end
local function names()
    local t = fs.list(R.rel .. "/" .. STEPS); local o = {}
    for _, e in ipairs(t) do o[#o + 1] = type(e) == "table" and e.name or e:match("[^/]+$") end
    table.sort(o); return o
end
local function dups()
    local seen, d = {}, {}
    for _, n in ipairs(names()) do local p = n:match("^(%d+)%-"); if p then if seen[p] then d[#d + 1] = p end; seen[p] = true end end
    return table.concat(d, " ")
end
local function head() return git("rev-parse", "HEAD") end
local function clean() return git("status", "--porcelain") == "" end
local function ls() return table.concat(names(), " ") end

repo("r1", "010", "270", "290")
local base0 = head()
branch("hostA", { "280-1111-aaaa.step" })
G("checkout", "-q", "main"); G("merge", "-q", "--no-edit", "hostA")
branch("hostB", { "280-2222-bbbb.step" }, base0)
G("merge", "-q", "--no-edit", "main")
T:arm("1 PRE-FIX CONTROL the integrated tree carries a shared prefix", dups() == "280", dups())
local h = head()
local o, rc, _, err = alloc("--base", "main", "--commit")
T:arm("1 the second land's step moves 280 to 285, the midpoint", o == "ok:gate-step-prefix:reallocated:1" and has("285-2222-bbbb.step") and not has("280-2222-bbbb.step"), o .. " " .. ls() .. err)
T:arm("1 the first land's 280 is untouched", has("280-1111-aaaa.step"), ls())
T:arm("1 the rename is committed, naming 1162-qbrx, and the tree is clean", head() ~= h and git("log", "-1", "--format=%s"):find("1162-qbrx", 1, true) and clean(), git("status", "--porcelain"))
T:arm("1 no two steps share a prefix afterwards", dups() == "", dups())

repo("r2", "280", "285", "290")
branch("hostC", { "285-3333-cccc.step" })
o = alloc("--base", "main", "--commit")
T:arm("2 NEGATIVE an explicit ordering is kept: 285 lands at 287", o == "ok:gate-step-prefix:reallocated:1"
    and ls():find("280%-%S+ 285%-%S+ 287%-3333%-cccc%.step 290%-"), o .. " " .. ls())

repo("r3", "010", "020")
branch("hostD", { "030-4444-dddd.step" })
h = head(); local tree = git("write-tree")
o = alloc("--base", "main", "--commit")
T:arm("3 no collision: no rename, no commit, tree unchanged", o == "ok:gate-step-prefix:no-collision" and head() == h and git("write-tree") == tree, o)

repo("r4", "300", "301", "302", "303", "304", "305", "306", "307", "308", "309", "310")
branch("hostE", { "300-5555-eeee.step" })
h = head()
o, rc = alloc("--base", "main", "--commit")
T:arm("4 no gap: refused, nothing renamed or staged, non-zero exit", rc ~= 0 and o == "refused:gate-step-prefix:no-gap:scripts/gate-steps.d/300-5555-eeee.step"
    and head() == h and has("300-5555-eeee.step") and clean(), tostring(rc) .. " " .. o)

repo("r5", "100", "120")
branch("hostF", { "110-6666-ffff.step", "110-7777-gggg.step" })
o = alloc("--base", "main", "--commit")
T:arm("5 of two added files at 110 the first stays and the second moves to 115", o == "ok:gate-step-prefix:reallocated:1" and has("110-6666-ffff.step") and has("115-7777-gggg.step"), o .. " " .. ls())
local function two_at_110(tag)
    repo(tag, "110", "120")
    branch("hostH", { "110-8888-aaaa.step", "110-9999-bbbb.step" })
end
two_at_110("r5b")
o = alloc("--base", "main", "--commit")
T:arm("5 two colliding with a remote 110 move to 115 and 116", o == "ok:gate-step-prefix:reallocated:2" and has("115-8888-aaaa.step") and has("116-9999-bbbb.step") and dups() == "", o .. " " .. ls())

two_at_110("r6")
h = head()
local dry, real
local function plan(s) local t = {}; for _, l in ipairs(text.lines(s)) do if l:find("^gate%-step%-prefix:") then t[#t + 1] = l end end; return table.concat(t, "\n") end
o, _, dry = alloc("--base", "main", "--dry-run")
T:arm("6 --dry-run names 115 and 116 and moves nothing", o == "ok:gate-step-prefix:dry-run:2" and dry:find("110-8888-aaaa.step -> 115-8888-aaaa.step", 1, true)
    and dry:find("110-9999-bbbb.step -> 116-9999-bbbb.step", 1, true) and head() == h and clean(), dry)
_, _, real = alloc("--base", "main", "--commit")
T:arm("6 --commit performs exactly that plan", plan(dry) ~= "" and plan(real) == plan(dry), plan(dry) .. " / " .. plan(real))

o, rc = alloc("--bogus")
T:arm("7 an unknown flag is refused with exit 2", rc == 2 and o == "refused:gate-step-prefix:usage:--bogus", tostring(rc) .. " " .. o)
repo("r7", "010", "020")
branch("hostI", { "020-1212-iiii.step" })
G("checkout", "-q", "main"); step("030-base-030.step"); commit("remote moves on"); G("checkout", "-q", "hostI")
o, rc = alloc("--base", "main", "--commit")
T:arm("7 a --base that is not an ancestor is refused", rc == 2 and o:find("refused:gate-step-prefix:usage:main is not an ancestor", 1, true) == 1 and has("020-1212-iiii.step"), tostring(rc) .. " " .. o)
repo("r7c", "990", "999")
branch("hostJ", { "999-1313-jjjj.step" })
o, rc = alloc("--base", "main", "--commit")
T:arm("7 a 999 that would widen to 1000 is refused, tree untouched", rc ~= 0 and o == "refused:gate-step-prefix:overflow:scripts/gate-steps.d/999-1313-jjjj.step"
    and has("999-1313-jjjj.step") and clean(), tostring(rc) .. " " .. o)
repo("r7d", "010", "020")
write("zzz-common.step", 'STEP_SCRIPT="scripts/test-common.sh"\n'); commit("a non-numeric step, last in the tree")
branch("hostK", { "030-1414-kkkk.step" })
o, rc = alloc("--base", "main", "--commit")
T:arm("7 a non-numeric step last in the tree still yields a verdict", rc == 0 and o == "ok:gate-step-prefix:no-collision", tostring(rc) .. " " .. o)

repo("r8", "100", "200")
G("branch", "-q", "-m", "main", "linux-next")
branch("windows-next", { "150-windows-local.step" })
G("checkout", "-q", "linux-next"); step("150-1177-linux.step"); commit("trunk lands a step at 150")
G("update-ref", "refs/remotes/origin/linux-next", "linux-next"); G("update-ref", "refs/remotes/origin/windows-next", "windows-next")
G("checkout", "-q", "windows-next"); fs.write(R.rel .. "/note.txt", "unrelated\n"); commit("an unrelated change")
G("merge", "-q", "--no-edit", "origin/linux-next")
h = head()
local ctrl = alloc("--base", "origin/windows-next", "--dry-run")
o = alloc("--base", "origin/windows-next", "--exclude", "origin/linux-next", "--commit")
T:arm("8 a platform branch never renames trunk's step (without --exclude it would)", ctrl == "ok:gate-step-prefix:dry-run:1" and o == "ok:gate-step-prefix:no-collision"
    and head() == h and has("150-1177-linux.step") and has("150-windows-local.step"), ctrl .. " " .. o .. " " .. ls())

local call, integ, gate, block, open = nil, nil, nil, {}, false
for i, l in ipairs(text.lines(fs.read(LAND))) do
    if l == "    if [ -f scripts/allocate-gate-step-prefix.sh ]; then" and not call then call = i; open = true end
    if open then block[#block + 1] = l; if l == "    fi" then open = false end end
    if l:find("_integrated=1", 1, true) then integ = i end
    if not gate and l:find("^ *%./build%.sh %-%-check") then gate = i end
end
T:arm("9 the block sits after the integrate and before ./build.sh --check", call and integ and gate and integ < call and call < gate,
    tostring(integ) .. " " .. tostring(call) .. " " .. tostring(gate))
local L = T:scratch("land")
fs.mkdir(L.rel .. "/scripts")
fs.write(L.rel .. "/block.sh", table.concat(block, "\n") .. "\n")
fs.write(L.rel .. "/" .. ALLOC, '#!/usr/bin/env bash\nprintf \'%s\\n\' "$*" > "$STUB_ARGS"\nprintf \'%s\\n\' "$STUB_OUT"\nexit "${STUB_RC:-0}"\n')
local function drive(br, verdict, code)
    local r = T:run{ SH, "-s", cwd = L.abs, env_unset = UNSET, stdin = '. ./block.sh\necho block-completed\n',
        env = { STUB_ARGS = L.abs .. "/args", STUB_OUT = verdict, STUB_RC = tostring(code), BRANCH = br, TRUNK = "linux-next", attempt = "1" } }
    return text.trim(fs.exists(L.rel .. "/args") and fs.read(L.rel .. "/args") or ""), "\n" .. (r.stdout or "") .. (r.stderr or ""), r.code
end
local a
a, o = drive("osx-next", "ok:gate-step-prefix:no-collision", 0)
T:arm("9 executed: a platform branch passes --exclude, and no-collision prints nothing", #block >= 5 and a == "--base origin/osx-next --exclude origin/linux-next --commit"
    and o:find("\nblock-completed\n", 1, true) and not o:find("gate-step-prefix", 1, true), a .. o)
a, o = drive("linux-next", "gate-step-prefix: 280-x.step -> 285-x.step (280 taken by 280-y.step)\nok:gate-step-prefix:reallocated:1", 0)
T:arm("9 executed: trunk has no --exclude, and a rename is echoed with the attempt", a == "--base origin/linux-next --commit"
    and o:find("\nland: attempt 1 — gate-step-prefix: 280-x.step -> 285-x.step", 1, true) and o:find("\nblock-completed\n", 1, true), a .. o)
a, o, rc = drive("osx-next", "refused:gate-step-prefix:no-gap:scripts/gate-steps.d/280-x.step", 1)
T:arm("9 executed: a refusing allocator stops the land with exit 8", rc == 8 and o:find("\nrefused:land:gate-step-prefix — refused:gate-step-prefix:no-gap", 1, true)
    and not o:find("\nblock-completed\n", 1, true), tostring(rc) .. o)
if #T.failed == 0 then out.line(("PASS: gate-step-prefix-allocation %d/%d (1162-qbrx)"):format(T.passed, T.passed)) end
T:finish({ ok = function(n) return "ok:gate-step-prefix-allocation:" .. n end })
