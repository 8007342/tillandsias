-- @trace order:1759-6z2m, order:1705-bgen, spec:git-mirror-service
--
-- test-forge-empty-project-starts.lua — a forge launched on an EMPTY project
-- (no files, no commits) reaches an agent-ready checkout, while every other
-- HEAD-less clone is still refused.
--
-- THE DEFECT. Measured on yoga 2026-10-17 with v56.10.16.2 AND stable
-- v56.10.13.1: in a plain empty directory and in a `git init` with no commits,
-- `tillandsias . --opencode` exits 1 after `[forge] FATAL: git clone …
-- produced an EMPTY checkout (no HEAD) after 12 attempts`. The guard exists for
-- real reasons (a mirror still seeding, a mirror whose HEAD names a missing
-- branch) and treated a project that has never had a commit as one of them.
-- An empty project is where onboarding (1705-bgen) starts.
--
-- WHAT TELLS "EMPTY PROJECT" APART. Two facts the mirror advertises over the
-- same git:// transport the clone used, BOTH required:
--   1. no refs/heads/* at all. NOT "no refs": an empty project's mirror still
--      advertises its own refs/tillandsias/* state refs (measured on yoga:
--      discipline, relay-state, sync-state, upstream-auth).
--   2. the upstream-auth verdict is `local-only`: no origin, so no seed is
--      coming (images/git/probe-upstream-auth.sh).
--
-- REGIME. Hermetic and offline, with REAL git. The implementation is
-- awk-extracted from images/default/lib-common.sh, as
-- test-forge-clone-wait-is-bounded.sh does, but git is NOT stubbed: a wrapper
-- rewrites the git://test-mirror-host/testproj URL to a local bare mirror and
-- calls the real binary, so clone, ls-remote and HEAD resolution are git's own
-- behaviour on a mirror shaped like images/git/entrypoint.sh leaves it.
--
--   1  an empty directory reaches an agent-ready checkout
--   2  a git-init'd empty directory reaches one, on its branch
--   3  NEGATIVE: HEAD-less with an upstream (authorized) is still refused
--   4  NEGATIVE: HEAD-less with no upstream verdict is still refused
--   5  NEGATIVE: local-only with branches but an unset HEAD is still refused
--      as the unborn-HEAD mirror defect
--   6  CONTROL: a mirror with a commit clones and runs the seed checkout
--
-- Verdicts (last line):
--   ok:forge-empty-project-starts:<pass>
--   violation:forge-empty-project-starts:<pass>/<total>          exit 1
--
-- Usage: tillandsias-plan script run scripts/lua/test-forge-empty-project-starts.lua

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("forge-empty-project-starts", "git rev-parse --show-toplevel did not answer")
end

local LIB = ROOT .. "/images/default/lib-common.sh"
if not fs.exists(LIB) then
    verdict.could_not_run("forge-empty-project-starts", "images/default/lib-common.sh is absent")
end

local ex = proc.run({ argv = { "awk", "/^_clone_project_from_mirror_impl\\(\\) \\{/,/^\\}/", LIB }, timeout_ms = 30000 })
local IMPL = ex.stdout or ""
if not text.contains(IMPL, "produced an EMPTY checkout") then
    verdict.emit("violation:forge-empty-project-starts:premise:the extracted impl has no empty-checkout FATAL; the anchor moved", 1)
end
-- The impl clones into the fixed forge path /home/forge/src/<project>, which a
-- host cannot write. Relocate THAT ONE assignment and prove it took: an impl
-- still pointed at /home/forge fails every arm, the control included, for a
-- reason that has nothing to do with the guard.
local ASSIGN = 'clone_dir="/home/forge/src/${TILLANDSIAS_PROJECT}"'
local s, e = IMPL:find(ASSIGN, 1, true)
if not s then
    verdict.emit("violation:forge-empty-project-starts:premise:the clone_dir assignment moved; cannot relocate the clone", 1)
end
IMPL = IMPL:sub(1, s - 1) .. 'clone_dir="$TARGET"' .. IMPL:sub(e + 1)

-- Scratch inside the checkout (Lua's fs.write and a recursive rm are both
-- confined to it). Every mirror write names its repository with --git-dir:
-- under the litmus runner's fixture regime `git -C <dir> update-ref` on a dir
-- inside the checkout is refused as a write to the real repository
-- (fixture-writes-outside-scope), while --git-dir names the bare mirror itself.
local W = ROOT .. "/target/plan-scratch/forge-empty-project-" .. time.iso_utc():gsub("[^0-9A-Za-z]", "")
    .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(W)
-- The config a gitconfig file would carry travels as GIT_CONFIG_* variables.
local GITENV = {
    GIT_CONFIG_GLOBAL = "/dev/null",
    GIT_CONFIG_NOSYSTEM = "1",
    GIT_CONFIG_COUNT = "1", GIT_CONFIG_KEY_0 = "init.defaultBranch", GIT_CONFIG_VALUE_0 = "main",
    GIT_AUTHOR_NAME = "fixture", GIT_AUTHOR_EMAIL = "fixture@invalid",
    GIT_COMMITTER_NAME = "fixture", GIT_COMMITTER_EMAIL = "fixture@invalid",
}

local function git(args, cwd, stdin)
    local argv = { "git" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, cwd = cwd, stdin = stdin, env = GITENV, timeout_ms = 60000 })
    if r.status ~= "exited" or r.code ~= 0 then
        verdict.could_not_run("forge-empty-project-starts",
            "fixture git " .. table.concat(args, " ") .. " failed: " .. text.trim(r.stderr or ""))
    end
    return text.trim(r.stdout or "")
end

-- A bare mirror shaped like images/git/entrypoint.sh leaves it. auth = the
-- upstream-auth verdict, or "" for none published yet.
local function mirror(name, head, auth)
    local d = W .. "/" .. name
    git({ "init", "-q", "--bare", d })
    git({ "--git-dir=" .. d, "symbolic-ref", "HEAD", "refs/heads/" .. head })
    local blob = git({ "--git-dir=" .. d, "hash-object", "-w", "--stdin" }, nil, "")
    git({ "--git-dir=" .. d, "update-ref", "refs/tillandsias/relay-state/ok/none/0/1", blob })
    git({ "--git-dir=" .. d, "update-ref", "refs/tillandsias/sync-state/heads-unknown/no-tracking-data/1", blob })
    if auth ~= "" then git({ "--git-dir=" .. d, "update-ref", "refs/tillandsias/upstream-auth/" .. auth .. "/1", blob }) end
    return d
end

-- One commit holding README, written straight into the bare mirror with
-- plumbing (no work tree, so no file for Lua to write).
local function commit_onto(d, branch)
    local blob = git({ "--git-dir=" .. d, "hash-object", "-w", "--stdin" }, nil, "x\n")
    local tree = git({ "--git-dir=" .. d, "mktree" }, nil, "100644 blob " .. blob .. "\tREADME\n")
    local commit = git({ "--git-dir=" .. d, "commit-tree", tree, "-m", "seed" })
    git({ "--git-dir=" .. d, "update-ref", "refs/heads/" .. branch, commit })
end

local HARNESS = [=[
set -uo pipefail
git() {
    local a=() x
    for x in "$@"; do a+=("${x/#git:\/\/test-mirror-host\/testproj/$MIRROR}"); done
    command git "${a[@]}"
}
git_mirror_host() { printf "test-mirror-host"; }
trace_lifecycle() { :; }
checkout_forge_seed_branch() { echo "[stub] checkout_forge_seed_branch $*"; }
rewrite_origin_for_enclave_push() { :; }
configure_git_identity() { :; }
probe_mirror_reachable() { return 0; }
forge_mirror_relay_gate() { return 0; }
forge_src_budget_report() { :; }
export_ssh_env() { :; }
sleep() { :; }
TILLANDSIAS_GIT_SERVICE=1
TILLANDSIAS_PROJECT=testproj
TILLANDSIAS_GIT_MIRROR_PATH=
if [ -n "$SEED" ]; then export TILLANDSIAS_FORGE_SEED_BRANCH="$SEED"; fi
eval "$IMPL"
_clone_project_from_mirror_impl "$TARGET"
st=$?
if [ -d "$TARGET/.git" ]; then
    echo "[probe] clone-dir=present branch=$(command git -C "$TARGET" symbolic-ref --short -q HEAD || echo none)"
else
    echo "[probe] clone-dir=absent"
fi
exit $st
]=]

-- A script FILE, not `bash -c`: the runner refuses shell strings (1252-fg9e).
local HARNESS_FILE = W .. "/harness.sh"
fs.write(HARNESS_FILE, HARNESS)

local n = 0
local function run(d, seed)
    n = n + 1
    local env = { MIRROR = d, SEED = seed, IMPL = IMPL, TARGET = W .. "/clone-" .. n }
    for k, v in pairs(GITENV) do env[k] = v end
    local r = proc.run({ argv = { "bash", HARNESS_FILE }, env = env, timeout_ms = 120000 })
    if r.status ~= "exited" then
        verdict.could_not_run("forge-empty-project-starts",
            "the harness did not run: " .. tostring(r.status) .. " " .. tostring(r.decision or ""))
    end
    return r.code, (r.stdout or "") .. (r.stderr or "")
end

local pass, fail = 0, 0
local function arm(name, cond, rc, got)
    if cond then out.line("ok:   " .. name); pass = pass + 1; return end
    local keep = {}
    for _, l in ipairs(text.lines(got)) do
        if text.contains(l, "FATAL") or text.contains(l, "[probe]") or text.contains(l, "[stub]") then keep[#keep + 1] = l end
    end
    out.line("FAIL: " .. name .. " — rc=" .. rc .. " " .. table.concat(keep, " | "))
    fail = fail + 1
end

local rc, o = run(mirror("m-empty", "master", "local-only"), "")
arm("1 an empty directory reaches an agent-ready checkout",
    rc == 0 and text.contains(o, "clone-dir=present") and not text.contains(o, "FATAL"), rc, o)

rc, o = run(mirror("m-gitinit", "main", "local-only"), "main")
arm("2 a git-init'd empty directory reaches an agent-ready checkout on its branch",
    rc == 0 and text.contains(o, "clone-dir=present branch=main") and not text.contains(o, "FATAL"), rc, o)

rc, o = run(mirror("m-upstream", "main", "authorized"), "main")
arm("3 NEGATIVE: a HEAD-less clone with an upstream is still refused",
    rc ~= 0 and text.contains(o, "EMPTY checkout"), rc, o)

rc, o = run(mirror("m-noverdict", "main", ""), "main")
arm("4 NEGATIVE: a HEAD-less clone with no upstream verdict is still refused",
    rc ~= 0 and text.contains(o, "EMPTY checkout"), rc, o)

local defect = mirror("m-defect", "master", "local-only")
commit_onto(defect, "feature")
rc, o = run(defect, "")
arm("5 NEGATIVE: a mirror with branches but an unset HEAD is still refused as a defect",
    rc ~= 0 and text.contains(o, "unborn-HEAD mirror defect"), rc, o)

local normal = mirror("m-normal", "main", "local-only")
commit_onto(normal, "main")
rc, o = run(normal, "main")
arm("6 CONTROL: a mirror with a commit clones and checks out the seed branch as before",
    rc == 0 and text.contains(o, "[stub] checkout_forge_seed_branch resolve") and text.contains(o, "branch=main"), rc, o)

proc.run({ argv = { "rm", "-rf", W }, timeout_ms = 60000 })

if fail == 0 then verdict.emit("ok:forge-empty-project-starts:" .. pass, 0) end
verdict.emit("violation:forge-empty-project-starts:" .. pass .. "/" .. (pass + fail), 1)
