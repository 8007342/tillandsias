-- @trace order:2245-scgt
-- @env TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-fixture-scratch-git-added.lua — scripts/lua/check-fixture-scratch-git-added.lua
-- over scratch repos (each `git init`ed, with refs/remotes/origin/linux-next as base):
--   1 BARE     an added `git -C "$D" remote set-url ...` in a scripts/test-*.sh is
--              refused, naming file:line and the variable
--   2 HELPER   the same line through `scratch_git "$D"` passes
--   3 REAL     `git -C "$ROOT" rev-parse HEAD` (reading the real repo) passes
--   4 MARKER   a line with `# scratch-git-ok: <why>` passes; an empty marker does not
--   5 BASE     a bare site already in the base is not re-litigated (diff-scoped)
--   6 SCOPE    the same line in a non-fixture script (scripts/tool.sh) is not judged
-- and the runtime guard, scripts/test-support/scratch-git.sh, copied into a FAKE
-- checkout (a miss rewrites the fake's origin, never this one's):
--   7 REFUSES  a plain dir inside the checkout, a missing dir, the checkout, a
--              SIBLING WORKTREE (shared config), and `init` under an inherited
--              GIT_DIR: exit 2 each, the fake checkout's origin unmoved
--   9 HOOK     sourced under a hook's exported GIT_DIR, scratch work lands in the
--              scratch repo (the variable is dropped, not obeyed and not fatal)
--   8 ADMITS   a scratch repo (outside, and nested in the checkout), a bare one
--
-- Verdict: ok:fixture-scratch-git-added-fixture:<n> or violation:...:<failed>.

local BASH = "/bin/bash"
do
    local ep = text.trim(proc.run({ argv = { "git", "--exec-path" }, timeout_ms = 10000 }).stdout or "")
    if ep:find("^%a:/.*/libexec/git%-core$") then
        BASH = (ep:gsub("/[^/]+/libexec/git%-core$", "/bin/bash.exe"))
    end
end
local RUNNER = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN")
if not RUNNER or RUNNER == "" then RUNNER = "target/release/tillandsias-plan" end
local ROOT = text.trim(proc.run{ argv = { "git", "rev-parse", "--show-toplevel" } }.stdout or "")
if RUNNER:sub(1, 1) ~= "/" then RUNNER = ROOT .. "/" .. RUNNER end
local rel = "target/plan-scratch/scratch-git-added-" .. tostring(time.now_ms())
fs.mkdir(rel)
local ABS = ROOT .. "/" .. rel

-- repo(name, base_body): a scratch repo whose base commit holds scripts/test-x.sh
-- with base_body, and the decider under scripts/lua/.
fs.write(rel .. "/mk.sh", [==[
set -e
r="$1"; base="$2"
mkdir -p "$r/scripts/lua"
cp "$3" "$r/scripts/lua/"
printf '%s\n' "$base" > "$r/scripts/test-x.sh"
printf '#!/usr/bin/env bash\n' > "$r/scripts/tool.sh"
git -C "$r" init -q
git -C "$r" -c user.email=t@t -c user.name=t add -A
git -C "$r" -c user.email=t@t -c user.name=t commit -qm base
git -C "$r" update-ref refs/remotes/origin/linux-next HEAD
]==])
local DECIDER = ROOT .. "/scripts/lua/check-fixture-scratch-git-added.lua"
local n = 0
local function repo(base)
    n = n + 1
    local r = ABS .. "/r" .. n
    proc.run{ argv = { BASH, rel .. "/mk.sh", r, base or "#!/usr/bin/env bash", DECIDER }, timeout_ms = 60000 }
    return r
end
fs.write(rel .. "/put.sh", 'printf "%s\\n" "$3" >> "$1/$2"\n')
local function put(r, file, line) proc.run{ argv = { BASH, rel .. "/put.sh", r, file, line } } end
local function judge(r)
    local p = proc.run{ argv = { RUNNER, "script", "run", "scripts/lua/check-fixture-scratch-git-added.lua" }, cwd = r,
        -- The scratch repo's own base: a gate exports TILLANDSIAS_GATE_DIFF_BASE as
        -- a sha of the REAL repo, which this repo does not hold.
        env = { TILLANDSIAS_REPO_ROOT = r, TILLANDSIAS_SCRATCH_GIT_BASE = "origin/linux-next" }, timeout_ms = 60000 }
    return (p.stdout or "") .. (p.stderr or ""), p.code
end

local pass, fail = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) log.raw("FAIL: " .. m); fail = fail + 1 end

local r = repo(); put(r, "scripts/test-x.sh", 'git -C "$D" remote set-url origin "$W/x.git"')
local o, rc = judge(r)
if rc == 1 and o:find("violation:fixture-scratch-git-added:1", 1, true) and o:find("scripts/test-x.sh:2", 1, true) and o:find('"$D"', 1, true) then
    ok("1: a bare git -C \"$D\" is refused, naming scripts/test-x.sh:2 and $D")
else bad("1: rc=" .. tostring(rc) .. " [" .. o .. "]") end

r = repo(); put(r, "scripts/test-x.sh", 'scratch_git "$D" remote set-url origin "$W/x.git"')
o, rc = judge(r)
if rc == 0 then ok("2: the same line through scratch_git passes") else bad("2: rc=" .. tostring(rc) .. " [" .. o .. "]") end

r = repo(); put(r, "scripts/test-x.sh", 'head="$(git -C "$ROOT" rev-parse HEAD)"')
o, rc = judge(r)
if rc == 0 then ok("3: git -C \"$ROOT\" (reading the real repo) passes") else bad("3: rc=" .. tostring(rc) .. " [" .. o .. "]") end

r = repo(); put(r, "scripts/test-x.sh", 'git -C "$D" log  # scratch-git-ok: D is a fixed literal path set two lines up')
local o1, rc1 = judge(r)
r = repo(); put(r, "scripts/test-x.sh", 'git -C "$D" log  # scratch-git-ok:')
local o2, rc2 = judge(r)
if rc1 == 0 and rc2 == 1 then ok("4: a reasoned marker passes; an empty one does not")
else bad("4: reasoned rc=" .. tostring(rc1) .. ", empty rc=" .. tostring(rc2) .. " [" .. o1 .. "][" .. o2 .. "]") end

r = repo('git -C "$D" remote set-url origin "$W/x.git"'); put(r, "scripts/test-x.sh", 'echo unrelated')
o, rc = judge(r)
if rc == 0 then ok("5: a bare site already in the base is not re-litigated") else bad("5: rc=" .. tostring(rc) .. " [" .. o .. "]") end

r = repo(); put(r, "scripts/tool.sh", 'git -C "$D" remote set-url origin "$W/x.git"')
o, rc = judge(r)
if rc == 0 then ok("6: a non-fixture script is not judged") else bad("6: rc=" .. tostring(rc) .. " [" .. o .. "]") end

fs.write(rel .. "/guard.sh", [==[
w="$1"; c="$w/co"; mkdir -p "$c/scripts/test-support" "$c/plain"
cp "$2" "$c/scripts/test-support/"
git -C "$c" init -q
git -C "$c" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$c" remote add origin https://example.invalid/real.git
git -C "$c" worktree add -q "$w/sibling" -b sib
mkdir -p "$w/hook"
( export GIT_DIR="$c/.git" GIT_WORK_TREE="$c"; . "$c/scripts/test-support/scratch-git.sh"
  scratch_git "$w/hook" init -q && scratch_git "$w/hook" remote add origin x ) >/dev/null 2>&1; echo "hook=$?"
. "$c/scripts/test-support/scratch-git.sh"
cd "$c" || exit 9
hit() { ( scratch_git "$@" ) >/dev/null 2>&1; echo "$?"; }
echo "plain=$(hit "$c/plain" remote set-url origin x)"
echo "missing=$(hit "$c/not-yet" remote set-url origin x)"
echo "real=$(hit "$c" remote set-url origin x)"
echo "sibling=$(hit "$w/sibling" remote set-url origin x)"
echo "gitdir=$(GIT_DIR="$c/.git" hit "$c/plain" init -q)"
echo "origin=$(git -C "$c" config remote.origin.url)"
mkdir -p "$w/out" "$c/nested" "$w/bare"
echo "init=$(hit "$w/out" init -q)$(hit "$c/nested" init -q)$(hit "$w/bare" init -q --bare)"
echo "use=$(hit "$w/out" config a.b c)$(hit "$c/nested" config a.b c)$(hit "$w/bare" config a.b c)"
]==])
local g = proc.run{ argv = { BASH, rel .. "/guard.sh", ABS .. "/g", ROOT .. "/scripts/test-support/scratch-git.sh" }, timeout_ms = 60000 }
local go = g.stdout or ""
local refuses = true
for _, k in ipairs({ "plain", "missing", "real", "sibling", "gitdir" }) do
    if not go:find(k .. "=2\n", 1, true) then refuses = false end
end
if refuses and go:find("origin=https://example.invalid/real.git\n", 1, true) then
    ok("7: plain dir, missing dir, checkout, sibling worktree and init under GIT_DIR are refused; origin unmoved")
else bad("7: [" .. go .. "] err=[" .. (g.stderr or "") .. "]") end
if go:find("init=000\n", 1, true) and go:find("use=000\n", 1, true) then
    ok("8: a scratch repo outside, one nested in the checkout, and a bare one are admitted")
else bad("8: [" .. go .. "] err=[" .. (g.stderr or "") .. "]") end
if go:find("hook=0\n", 1, true) and go:find("origin=https://example.invalid/real.git\n", 1, true) then
    ok("9: sourced under an exported GIT_DIR, scratch_git works on the scratch repo only")
else bad("9: [" .. go .. "] err=[" .. (g.stderr or "") .. "]") end

fs.write(rel .. "/cleanup.sh", 'rm -rf -- "$1"\n')
proc.run{ argv = { BASH, rel .. "/cleanup.sh", rel } }
if fail == 0 then verdict.emit("ok:fixture-scratch-git-added-fixture:" .. pass, 0) end
verdict.emit("violation:fixture-scratch-git-added-fixture:" .. fail, 1)
