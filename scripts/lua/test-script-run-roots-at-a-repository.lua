-- @trace order:2213-ag5u, spec:ci-release
-- @env TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-script-run-roots-at-a-repository.lua — `tillandsias-plan script run`
-- roots a script at the repository containing its cwd, else the repository
-- containing the script, and otherwise REFUSES. It never falls back to the
-- runner binary's own checkout.
--
-- MEASURED 2026-11-22 (2212-2m8s): test-plan-binary-runnability-precondition
-- ran a Lua port inside an un-`git init`-ed scratch dir holding a dead ELF.
-- The runner rooted at its OWN checkout (a current_exe walk), so fs.*,
-- proc.run's default cwd and the port's probe all measured the real tree:
-- 27/27 with the base folding, where the dead ELF should have made it skip.
--
-- Every arm runs the REAL runner from a directory under $TMPDIR, outside any
-- repository (asserted as a premise):
--   1 a decider there REFUSES: could-not-run:script-run:no-repository-root,
--     exit 3, and its body never runs. Pre-fix: it ran, rooted at the
--     runner's checkout (the MUTANT this arm reds on).
--   2 a --helper there still runs (the forge's ported lib-*.sh bodies live
--     under /usr/local/lib and need no repository).
--   3 after `git init` the same dir is the root.
--   4 a script inside this checkout, run from a foreign cwd, roots at this
--     checkout (the script's repository), not at the foreign cwd.
--
-- Verdict: ok:script-run-roots-at-a-repository:4 arms | violation:script-run-roots-at-a-repository:<n> failed

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local failn = 0
local function ok(m) out.line("ok:   " .. m) end
local function bad(m) out.line("FAIL: " .. m); failn = failn + 1 end

local stamp = tostring(time.now_ms())
local rel = "target/plan-scratch/script-run-root-" .. stamp
proc.run{ argv = { "mkdir", "-p", root .. "/" .. rel } }

local RUNNER = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or ""
if RUNNER == "" then
    fs.write(rel .. "/resolve.sh", ". scripts/plan-binary-probe.sh && resolve_plan_binary\n")
    RUNNER = text.trim(proc.run{ argv = { "bash", root .. "/" .. rel .. "/resolve.sh" } }.stdout or "")
    if RUNNER:sub(1, 2) == "./" then RUNNER = root .. "/" .. RUNNER:sub(3) end
end
local function cleanup_in() proc.run{ argv = { "find", root .. "/" .. rel, "-delete" }, timeout_ms = 60000 } end
if RUNNER == "" then cleanup_in(); verdict.could_not_run("script-run-roots-at-a-repository:no-runner") end

-- The probe: prints a marker and the directory the runner rooted it at.
fs.write(rel .. "/probe.lua", 'out.line("probe-ran")\nout.line("root=" .. text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or ""))\nverdict.ok("probe")\n')
fs.write(rel .. "/helper.lua", 'out.line("helper-ran")\n')

local D = text.trim(proc.run{ argv = { "mktemp", "-d" } }.stdout or "")
local E = text.trim(proc.run{ argv = { "mktemp", "-d" } }.stdout or "")
local function cleanup()
    cleanup_in()
    for _, d in ipairs({ D, E }) do
        if d ~= "" then proc.run{ argv = { "find", d, "-delete" }, timeout_ms = 60000 } end
    end
end
if D == "" or E == "" then cleanup(); verdict.could_not_run("script-run-roots-at-a-repository:no-tmpdir") end
D = text.trim(proc.run{ argv = { "realpath", D } }.stdout or D)
proc.run{ argv = { "cp", root .. "/" .. rel .. "/probe.lua", root .. "/" .. rel .. "/helper.lua", D .. "/" } }

-- PREMISE: D is outside any repository, or arm 1 proves nothing.
if proc.run{ argv = { "git", "-C", D, "rev-parse", "--git-dir" } }.ok then
    cleanup(); verdict.could_not_run("script-run-roots-at-a-repository:tmpdir-is-inside-a-repository")
end

local function run_in(cwd, args)
    -- An explicit TILLANDSIAS_REPO_ROOT would decide every arm; unset it.
    local a = { "env", "-u", "TILLANDSIAS_REPO_ROOT", RUNNER, "script", "run" }
    for _, x in ipairs(args) do a[#a + 1] = x end
    local r = proc.run{ argv = a, cwd = cwd, timeout_ms = 120000 }
    return r.stdout or "", r.stderr or "", r.code
end

-- ── 1: a decider outside any repository refuses, and runs nothing ─────────
local o, e, rc = run_in(D, { D .. "/probe.lua" })
if rc == 3 and o:find("could-not-run:script-run:no-repository-root", 1, true) and not o:find("probe-ran", 1, true) then
    ok("1 a decider outside any repository refuses (exit 3, named cause) and its body never runs")
else
    bad("1 rc=" .. tostring(rc) .. " out=[" .. o:gsub("\n", "|") .. "] — pre-fix it ran rooted at the runner's own checkout")
end

-- ── 2: a --helper outside any repository still runs ──────────────────────
o, e, rc = run_in(D, { "--helper", D .. "/helper.lua" })
if rc == 0 and o:find("helper-ran", 1, true) then ok("2 a --helper outside any repository still runs")
else bad("2 rc=" .. tostring(rc) .. " out=[" .. o:gsub("\n", "|") .. "] err=[" .. e:gsub("\n", "|") .. "]") end

-- ── 3: after git init the scratch dir is the root ─────────────────────────
proc.run{ argv = { "git", "init", "-q", D } }
o, e, rc = run_in(D, { D .. "/probe.lua" })
if rc == 0 and o:find("root=" .. D, 1, true) then ok("3 after git init the scratch dir itself is the root")
else bad("3 rc=" .. tostring(rc) .. " out=[" .. o:gsub("\n", "|") .. "]") end

-- ── 4: a script in this checkout, from a foreign cwd, roots here ─────────
o, e, rc = run_in(E, { root .. "/" .. rel .. "/probe.lua" })
if rc == 0 and o:find("root=" .. root, 1, true) then ok("4 a script in this checkout, run from a foreign cwd, roots at this checkout")
else bad("4 rc=" .. tostring(rc) .. " out=[" .. o:gsub("\n", "|") .. "] want root=" .. root) end

cleanup()
if failn == 0 then verdict.ok("script-run-roots-at-a-repository:4 arms") end
verdict.emit("violation:script-run-roots-at-a-repository:" .. failn .. " failed", 1)
