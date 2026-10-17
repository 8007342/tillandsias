-- @trace order:1600-nn5b
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-worktree-add-cleanup.lua — both layers of 1600-nn5b.
--
-- THE SCAN (scripts/lua/check-worktree-add-cleanup.lua) on CONSTRUCTED roots:
--   1 GOOD     EXIT trap, then a TERM trap that exits, then the add, and a
--              worktree remove: ok, real=1, unguarded=0
--   2 EXITONLY trap cleanup EXIT only (an untrapped TERM kills bash with no
--              EXIT trap): unguarded:no-term-trap-that-exits-before-the-add
--   3 RMONLY   the cleanup only rm -rf's (the registration stays):
--              unguarded:cleanup-never-runs-worktree-remove
--   4 LATE     traps registered AFTER the add: unguarded:no-exit-trap-before-the-add
--   5 SCRATCH  an add into a scratch repo (-C "$d/w") and a commented add are
--              not this checkout's: ok, adders=1, real=0
--   6 EXEMPT   a reasoned exemption is honoured (exempt=1); a stale one is refused
--   7 EMPTY    no scripts/ is could-not-run, exit 3
-- THE DOOR (build.sh _pf_now, _pf_run_guard and _pf_sweep_guard_tmp, extracted
-- at run time, not copied) against a planted guard that adds a worktree to a
-- one-file scratch repo and ignores TERM, so the deadline KILL always lands and
-- no trap of its own runs:
--   8 PRE-FIX  the same function with its sweep calls removed leaves the
--              registration behind (the defect, constructed)
--   9 POST-FIX the real function leaves 0 and records swept:worktree:<path>
--  10 LOCKED   the guard locks its worktree (as one KILLed inside `git worktree
--              add` leaves it): a single --force fails it, and the real sweep's
--              -f -f removes it
-- Every worktree this fixture causes is removed at the end of its arm.
--
-- Usage: tillandsias-plan script run scripts/lua/test-worktree-add-cleanup.lua [-- --plan <bin>]

local SUBJECT_REL = "scripts/lua/check-worktree-add-cleanup.lua"
if not fs.exists(SUBJECT_REL) then
    verdict.emit("violation:worktree-add-cleanup-fixture:no-subject", 1, SUBJECT_REL .. " does not exist (1600-nn5b)")
end
local PLAN
for i = 1, #arg do if arg[i] == "--plan" then PLAN = arg[i + 1] end end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("worktree-add-cleanup-fixture", "no plan binary named (--plan, TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("worktree-add-cleanup-fixture", "git rev-parse --show-toplevel did not answer")
end
local SUBJECT = ROOT .. "/" .. SUBJECT_REL
local REL = "target/plan-scratch/worktree-add-cleanup-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)

local failed = {}
local function arm(name, cond, got)
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. got)
        failed[#failed + 1] = name
    end
end

-- ── the scan ───────────────────────────────────────────────────────────────
local function root_with(name, files, exempt)
    local r = REL .. "/" .. name
    fs.mkdir(r .. "/scripts/portability")
    for f, body in pairs(files) do fs.write(r .. "/scripts/" .. f, body) end
    if exempt then fs.write(r .. "/scripts/portability/worktree-add-scan-exempt.txt", exempt) end
    return r
end
local function scan(rel)
    local r = proc.run({ argv = { PLAN, "script", "run", SUBJECT }, cwd = ROOT,
        env = { TILLANDSIAS_REPO_ROOT = ROOT .. "/" .. rel }, timeout_ms = 60000 })
    return (r.status == "exited" and r.code or -1), text.trim(r.stdout or "")
end
local TRAPS = "trap cleanup EXIT\ntrap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP\n"
local CLEAN = "cleanup() { git -C \"$ROOT\" worktree remove --force \"$wt\"; }\n"
local ADD = "git -C \"$ROOT\" worktree add -q --detach \"$wt\" HEAD\n"

local rc, o = scan(root_with("good", { ["test-good.sh"] = CLEAN .. TRAPS .. ADD }))
arm("1 GOOD a guarded real-checkout add passes and is counted",
    rc == 0 and o == "ok:worktree-add-cleanup:scanned=1:adders=1:real=1:unguarded=0:exempt=0", rc .. " " .. o)

rc, o = scan(root_with("exitonly", { ["test-x.sh"] = CLEAN .. "trap cleanup EXIT\n" .. ADD }))
arm("2 EXITONLY an EXIT-only trap is refused (TERM must exit)",
    rc == 1 and o:find("unguarded:scripts/test-x.sh:no-term-trap-that-exits-before-the-add", 1, true) ~= nil, rc .. " " .. o)

rc, o = scan(root_with("rmonly", { ["test-x.sh"] = "cleanup() { rm -rf \"$wt\"; }\n" .. TRAPS .. ADD }))
arm("3 RMONLY a cleanup that never runs worktree remove is refused",
    rc == 1 and o:find("unguarded:scripts/test-x.sh:cleanup-never-runs-worktree-remove", 1, true) ~= nil, rc .. " " .. o)

rc, o = scan(root_with("late", { ["test-x.sh"] = CLEAN .. ADD .. TRAPS }))
arm("4 LATE traps registered after the add are refused",
    rc == 1 and o:find("unguarded:scripts/test-x.sh:no-exit-trap-before-the-add", 1, true) ~= nil, rc .. " " .. o)

rc, o = scan(root_with("scratch", { ["test-x.sh"] = "git -C \"$d/w\" worktree add -q \"$d/wt\"\n# git worktree add --detach \"$wt\" HEAD\n" }))
arm("5 SCRATCH a scratch-repo add and a commented add are not this checkout's",
    rc == 0 and o == "ok:worktree-add-cleanup:scanned=1:adders=1:real=0:unguarded=0:exempt=0", rc .. " " .. o)

rc, o = scan(root_with("exempt", { ["test-x.sh"] = "flags j 'git worktree add --detach -q \"$wt\" HEAD'\n" },
    "scripts/test-x.sh the add is checker input inside a string, never executed\n"))
local rc2, o2 = scan(root_with("stale", { ["test-y.sh"] = "echo nothing\n" },
    "scripts/test-gone.sh no longer here\n"))
arm("6 EXEMPT a reasoned exemption is honoured and a stale one refused",
    rc == 0 and o == "ok:worktree-add-cleanup:scanned=1:adders=1:real=0:unguarded=0:exempt=1"
    and rc2 == 1 and o2:find("stale-exempt:scripts/test-gone.sh", 1, true) ~= nil,
    rc .. " " .. o .. " / " .. rc2 .. " " .. o2)

fs.mkdir(REL .. "/empty/x")
rc, o = scan(REL .. "/empty")
arm("7 EMPTY no scripts/ is could-not-run", rc == 3 and o:find("could-not-run:worktree-add-cleanup:empty-population", 1, true) ~= nil, rc .. " " .. o)

-- ── the door ───────────────────────────────────────────────────────────────
local function extract(text_, name)
    local acc, on = {}, false
    for l in (text_ .. "\n"):gmatch("(.-)\n") do
        if l:match("^" .. name .. "%(%) {") then on = true end
        if on then
            acc[#acc + 1] = l
            if l == "}" then break end
        end
    end
    return table.concat(acc, "\n")
end
local build = fs.read("build.sh")
-- Every helper _pf_run_guard calls is extracted with it (1618-baia added
-- _pf_sweep_fixture_scratch to the killed path, 1630-dwab _pf_sweep_declared_artifacts, 1650-fb7z _pf_sweep_index_lock, 1753-p925 _pf_worktree_list): an absent one would print
-- "command not found" there and pass only because nothing checks that call.
local fns = extract(build, "_pf_worktree_list") .. "\n" .. extract(build, "_pf_sweep_under") .. "\n" .. extract(build, "_pf_sweep_guard_tmp") .. "\n" ..
    extract(build, "_pf_sweep_fixture_scratch") .. "\n" .. extract(build, "_pf_sweep_declared_artifacts") .. "\n" ..
    extract(build, "_pf_index_lock_held") .. "\n" .. extract(build, "_pf_sweep_index_lock") .. "\n" ..
    extract(build, "_pf_now") .. "\n" ..
    extract(build, "_pf_run_guard") .. "\n"
if not fns:find("_pf_sweep_guard_tmp \"$_gtmp\" \"$_out\"", 1, true) then
    arm("8/9 DOOR premise: build.sh's _pf_run_guard calls _pf_sweep_guard_tmp", false, "the call is not in the extracted function")
else
    -- The defect, constructed: the same function without its sweep calls.
    local pre = fns:gsub("\n%s*_pf_sweep_guard_tmp \"%$_gtmp\" \"%$_out\"\n", "\n")
    fs.write(REL .. "/door-post.sh", fns)
    fs.write(REL .. "/door-pre.sh", pre)
    -- The harness: everything under one base dir in the door's own TMPDIR, so
    -- this fixture's worktrees are swept even if IT is killed. It reports the
    -- worktrees registered under the base after the guard ends, then removes them.
    -- The guard adds a worktree of a ONE-FILE scratch repo, never the checkout:
    -- adding the checkout (11084 files) took 3.85 s under taskpolicy -b against
    -- the 2 s deadline, so the KILL landed mid-add and arm 9 read
    -- swept:worktree-failed one run in five (1600-nn5b's close note). The repo
    -- sits OUTSIDE the base, or the sweep would try to remove it too.
    fs.write(REL .. "/harness.sh", table.concat({
        "set -u",
        "ROOT=\"$1\"; FN=\"$2\"",
        "REPO=\"$(mktemp -d \"${TMPDIR:-/tmp}/wtsweep-repo.XXXXXX\")\"",
        "git init -q \"$REPO\" && echo x > \"$REPO/f\" && git -C \"$REPO\" add f && git -C \"$REPO\" -c user.name=t -c user.email=t@t commit -qm x || { echo no-scratch-repo; exit 3; }",
        "BASE=\"$(mktemp -d \"${TMPDIR:-/tmp}/wtsweep.XXXXXX\")\"; export TMPDIR=\"$BASE\"",
        "SCRIPT_DIR=\"$REPO\"",
        ". \"$FN\"",
        "G=\"$BASE/plant.sh\"",
        "printf '%s\\n' 'git -C \"$1\" worktree add --detach -q \"$TMPDIR/wt\" HEAD' > \"$G\"",
        "[ -z \"${LOCK:-}\" ] || printf '%s\\n' 'git -C \"$1\" worktree lock \"$TMPDIR/wt\"' >> \"$G\"",
        "printf '%s\\n' \"trap '' TERM\" 'sleep 6' >> \"$G\"",
        "rc=0; _pf_run_guard \"$G\" 2 \"$BASE/out\" \"$REPO\" || rc=$?",
        "echo \"rc=$rc\"",
        "real=\"$(cd \"$BASE\" && pwd -P)\"; n=0",
        "while read -r k v; do [ \"$k\" = worktree ] || continue; case \"$v\" in \"$real\"/*|\"$BASE\"/*) n=$((n+1)); git -C \"$REPO\" worktree remove -f -f \"$v\" >/dev/null 2>&1;; esac; done < <(git -C \"$REPO\" worktree list --porcelain)",
        "echo \"left=$n\"",
        "[ ! -f \"$BASE/out.swept\" ] || cat \"$BASE/out.swept\"",
        "rm -rf \"$BASE\" \"$REPO\"",
        "",
    }, "\n"))
    -- The single-force variant: what the sweep did before it learned that a
    -- guard KILLed inside `git worktree add` leaves the worktree LOCKED.
    fs.write(REL .. "/door-oneforce.sh", (fns:gsub("worktree remove %-f %-f", "worktree remove --force")))
    local function door(which, lock)
        local r = proc.run({ argv = { "bash", ROOT .. "/" .. REL .. "/harness.sh", ROOT, ROOT .. "/" .. REL .. "/door-" .. which .. ".sh" },
            env = lock and { LOCK = "1" } or {}, cwd = ROOT, timeout_ms = 60000 })
        return text.trim(r.stdout or ""), text.trim(r.stderr or "")
    end
    local pre_out, pre_err = door("pre")
    arm("8 PRE-FIX a KILLed guard's worktree stays registered without the sweep (the defect)",
        pre_out:find("rc=124", 1, true) ~= nil and pre_out:find("left=1", 1, true) ~= nil,
        pre_out:gsub("\n", " ") .. " " .. pre_err:sub(1, 200))
    local post_out, post_err = door("post")
    arm("9 POST-FIX the door sweeps it: 0 left, swept:worktree: recorded, no helper missing on the killed path",
        post_out:find("rc=124", 1, true) ~= nil and post_out:find("left=0", 1, true) ~= nil
        and post_out:find("swept:worktree:", 1, true) ~= nil
        and post_err:find("command not found", 1, true) == nil,
        post_out:gsub("\n", " ") .. " " .. post_err:sub(1, 200))
    local one_out = door("oneforce", true)
    local two_out, two_err = door("post", true)
    arm("10 LOCKED a worktree locked mid-add needs -f -f: one --force fails it, the door's sweep removes it",
        one_out:find("swept:worktree-failed:", 1, true) ~= nil and one_out:find("left=1", 1, true) ~= nil
        and two_out:find("left=0", 1, true) ~= nil and two_out:find("swept:worktree:", 1, true) ~= nil,
        "one-force=[" .. one_out:gsub("\n", " ") .. "] door=[" .. two_out:gsub("\n", " ") .. "] " .. two_err:sub(1, 200))
end

if #failed > 0 then
    verdict.emit("violation:worktree-add-cleanup-fixture:" .. #failed .. "-failed", 1)
end
verdict.ok("worktree-add-cleanup-fixture", "10 arms")
