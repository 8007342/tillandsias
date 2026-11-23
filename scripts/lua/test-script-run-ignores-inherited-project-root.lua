-- @trace order:2225-prrt, spec:ci-release
-- @env TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @env TMPDIR
--
-- test-script-run-ignores-inherited-project-root.lua — pins that `script run`
-- does not take its repository root from an inherited PROJECT_ROOT (2225-prrt).
--
-- WHY. scripts/run-litmus-test.sh exports PROJECT_ROOT, set to the real
-- checkout, for its metrics logs (1268-m2ir). The runner read PROJECT_ROOT
-- right after TILLANDSIAS_REPO_ROOT and BEFORE the caller's cwd, so every Lua
-- decider a litmus step ran inside a `git init`-ed scratch repo judged the
-- real checkout instead, and a refusal arm could pass for the wrong reason
-- (measured on calmecacpilli 2026-11-22). PROJECT_ROOT is a generic name that
-- many tools set; the root order is now TILLANDSIAS_REPO_ROOT, the cwd's
-- repository, the script's repository, else a refusal.
--
-- Each arm starts the runner the way a litmus step does, with PROJECT_ROOT
-- naming this checkout, and a probe script that prints the root it was given
-- (proc.run's default cwd is the root).
--
--   1 run from a git-init'd scratch repo with PROJECT_ROOT=<checkout>: the root is the scratch repo
--   2 CONTROL: TILLANDSIAS_REPO_ROOT, the explicit override, still wins over the cwd
--   3 CONTROL: from a non-repository dir, with the probe in it, the run is refused, not rooted at PROJECT_ROOT
--
-- Verdict: ok:script-run-ignores-inherited-project-root:3 arms
--        | violation:script-run-ignores-inherited-project-root:<n> failed

local fixture = require "common.fixture"
local SH = fixture.posix_shell()
local root = fixture.repo_root()
local failn = 0
local function ok(m) out.line("ok:   " .. m) end
local function bad(m) out.line("FAIL: " .. m); failn = failn + 1 end

local RUNNER = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or ""
local rel = "target/plan-scratch/script-run-project-root-" .. tostring(time.now_ms())
local W = root .. "/" .. rel
proc.run{ argv = { "mkdir", "-p", W .. "/scratch", W .. "/bare" } }
local function cleanup() proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 } end

if RUNNER == "" then
    fs.write(rel .. "/resolve.sh", ". scripts/plan-binary-probe.sh && resolve_plan_binary\n")
    RUNNER = text.trim(proc.run{ argv = { SH, W .. "/resolve.sh" } }.stdout or "")
    if RUNNER:sub(1, 2) == "./" then RUNNER = root .. "/" .. RUNNER:sub(3) end
end
if RUNNER == "" then cleanup(); verdict.could_not_run("script-run-ignores-inherited-project-root:no-runner") end

-- the scratch repository. GIT_* are cleared so a hook-launched gate's
-- GIT_DIR cannot point this init at the real repository.
local GITENV = { GIT_DIR = "", GIT_WORK_TREE = "", GIT_INDEX_FILE = "" }
fs.write(rel .. "/init.sh", "unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE; git init -q \"$1\"\n")
proc.run{ argv = { SH, W .. "/init.sh", W .. "/scratch" }, env = GITENV, timeout_ms = 60000 }

local PROBE = "out.line('root=' .. text.trim(proc.run{ argv = { 'pwd', '-P' } }.stdout or ''))\n"
    .. "verdict.ok('probe')\n"
fs.write(rel .. "/scratch/probe.lua", PROBE)
fs.write(rel .. "/bare/probe.lua", PROBE)

local function probe(cwd, extra)
    local e = { PROJECT_ROOT = root, TILLANDSIAS_REPO_ROOT = "" }
    for k, v in pairs(extra or {}) do e[k] = v end
    local r = proc.run{ argv = { RUNNER, "script", "run", cwd .. "/probe.lua" }, cwd = cwd, env = e, timeout_ms = 60000 }
    local said = (r.stdout or "") .. (r.stderr or "")
    return r.code, said:match("root=([^\n]*)"), said
end

-- 1 the defect
local rc, got, said = probe(W .. "/scratch")
if rc == 0 and got == W .. "/scratch" then
    ok("1 from a scratch repo with PROJECT_ROOT=<checkout>, the root is the scratch repo")
else
    bad("1 rc=" .. tostring(rc) .. " root=" .. tostring(got) .. " (want " .. W .. "/scratch): " .. text.trim(said))
end

-- 2 the explicit override still wins
rc, got, said = probe(W .. "/scratch", { TILLANDSIAS_REPO_ROOT = root })
if rc == 0 and got == root then
    ok("2 CONTROL: TILLANDSIAS_REPO_ROOT still wins over the cwd")
else
    bad("2 rc=" .. tostring(rc) .. " root=" .. tostring(got) .. ": " .. text.trim(said))
end

-- 3 no repository anywhere but PROJECT_ROOT: refused, not rooted there. The
-- bare dir sits inside this checkout, so it is copied out to $TMPDIR first.
local tmp = text.trim(proc.run{ argv = { "mktemp", "-d", (env.get("TMPDIR") or "/tmp") .. "/prrt-bare.XXXXXX" } }.stdout or "")
proc.run{ argv = { "cp", W .. "/bare/probe.lua", tmp .. "/probe.lua" } }
rc, got, said = probe(tmp)
proc.run{ argv = { "find", tmp, "-delete" }, timeout_ms = 60000 }
if rc ~= 0 and got ~= root and said:find("no-repository-root", 1, true) then
    ok("3 CONTROL: with no repository but PROJECT_ROOT, the run is refused by name")
else
    bad("3 rc=" .. tostring(rc) .. " root=" .. tostring(got) .. ": " .. text.trim(said))
end

cleanup()
if failn == 0 then verdict.ok("script-run-ignores-inherited-project-root:3 arms") end
verdict.emit("violation:script-run-ignores-inherited-project-root:" .. failn .. " failed", 1)
