-- @trace order:1581-d9ig
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-fixture-prunes-checkout.lua — scripts/lua/check-fixture-prunes-checkout.lua
-- on constructed fixtures in a scratch tree under target/plan-scratch.
--
--   1 ROOT       `git -C "$ROOT" worktree prune` in a single-quoted trap body
--                is refused, naming the file, line and worktree-prune
--   2 DERIVED    `git -C "$TOP" gc` where TOP is assigned from
--                `git rev-parse --show-toplevel` is refused as gc
--   3 BARE       `git worktree prune` with no -C (the cwd) is refused
--   4 SCRATCH    NEGATIVE CONTROL: `git -C "$WORK/copy" gc --prune=now` is
--                allowed and counted as a scratch site
--   5 COMMENT    NEGATIVE CONTROL: the same root prune in a comment is not read
--   6 EMPTY      no scripts/**/*.sh is could-not-run (exit 3), never ok
--   7 LITMUS     a litmus `command:` running `git worktree prune` with no -C
--                (a litmus step runs in the checkout) is refused
--   8 TOOL       a non-fixture script pruning "$PROJECT_ROOT" is refused
--
-- Usage: tillandsias-plan script run scripts/lua/test-fixture-prunes-checkout.lua [-- --plan <bin>]

local GUARD_REL = "scripts/lua/check-fixture-prunes-checkout.lua"
if not fs.exists(GUARD_REL) then
    verdict.emit("violation:fixture-prunes-checkout-fixture:no-guard", 1,
        "scripts/lua/check-fixture-prunes-checkout.lua does not exist — nothing stops a fixture pruning the operator checkout (1581-d9ig)")
end

local PLAN
for i = 1, #arg do if arg[i] == "--plan" then PLAN = arg[i + 1] end end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("fixture-prunes-checkout-fixture", "no plan binary named (--plan, TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 120000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
local GUARD = ROOT .. "/" .. GUARD_REL
local REL = "target/plan-scratch/fixture-prunes-checkout-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL

-- One fresh tree per arm, holding exactly the fixtures named.
local n_tree = 0
local function tree(files, litmus)
    n_tree = n_tree + 1
    local d = REL .. "/t" .. n_tree
    fs.mkdir(d .. "/scripts")
    fs.mkdir(d .. "/openspec/litmus-tests")
    for name, body in pairs(files) do fs.write(d .. "/scripts/" .. name, body) end
    for name, body in pairs(litmus or {}) do fs.write(d .. "/openspec/litmus-tests/" .. name, body) end
    return W .. "/t" .. n_tree
end
local function guard(dir)
    local r = run({ PLAN, "script", "run", GUARD }, { cwd = dir, env = { TILLANDSIAS_REPO_ROOT = dir } })
    return (r.status == "exited" and r.code or -1), (r.stdout or ""), (r.stderr or "")
end
local function has_line(s, want) for _, l in ipairs(text.lines(s)) do if l == want then return true end end return false end

local passed, failed = {}, {}
local function check(name, cond, why)
    if cond then passed[#passed + 1] = name; out.line("ok:   " .. name)
    else failed[#failed + 1] = name; out.line("FAIL: " .. name .. " — " .. why) end
end
local HEAD = '#!/usr/bin/env bash\nROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"\n'

-- 1. ROOT, inside a single-quoted trap body
local rc, o = guard(tree({ ["test-a.sh"] = HEAD ..
    "trap 'rm -rf \"$WT\"; git -C \"$ROOT\" worktree prune >/dev/null 2>&1' EXIT\n" }))
check("ROOT: a root prune inside a single-quoted trap is refused by file, line and kind",
    rc == 1 and has_line(o, "violation:fixture-prunes-checkout:scripts/test-a.sh:3:worktree-prune"), "rc=" .. rc .. " out=[" .. o .. "]")

-- 2. DERIVED root variable, gc
rc, o = guard(tree({ ["test-b.sh"] = '#!/usr/bin/env bash\nTOP="$(git rev-parse --show-toplevel)"\ngit -C "$TOP" gc --quiet\n' }))
check("DERIVED: gc on a variable assigned from rev-parse --show-toplevel is refused",
    rc == 1 and has_line(o, "violation:fixture-prunes-checkout:scripts/test-b.sh:3:gc"), "rc=" .. rc .. " out=[" .. o .. "]")

-- 3. BARE, no -C
rc, o = guard(tree({ ["test-c.sh"] = HEAD .. "echo x && git worktree prune\n" }))
check("BARE: a prune with no -C (the cwd, i.e. the checkout) is refused",
    rc == 1 and has_line(o, "violation:fixture-prunes-checkout:scripts/test-c.sh:3:worktree-prune"), "rc=" .. rc .. " out=[" .. o .. "]")

-- 4. SCRATCH (negative control)
rc, o = guard(tree({ ["test-d.sh"] = HEAD .. 'WORK="$(mktemp -d)"\ngit -C "$WORK/copy" gc --quiet --prune=now\ngit -C "$WORK/copy" worktree prune\n' }))
check("SCRATCH: gc and prune on the fixture's own scratch repo are allowed and counted",
    rc == 0 and has_line(o, "ok:fixture-prunes-checkout:scripts=1 litmus=0 scratch-sites=2"), "rc=" .. rc .. " out=[" .. o .. "]")

-- 5. COMMENT (negative control)
rc, o = guard(tree({ ["test-e.sh"] = HEAD .. '# git -C "$ROOT" worktree prune\necho done  # then git -C "$ROOT" gc\n' }))
check("COMMENT: a root prune or gc in a comment is not read",
    rc == 0 and has_line(o, "ok:fixture-prunes-checkout:scripts=1 litmus=0 scratch-sites=0"), "rc=" .. rc .. " out=[" .. o .. "]")

-- 6. EMPTY
rc, o = guard(tree({ ["notes.txt"] = "not a script\n" }))
check("EMPTY: no scripts is could-not-run (exit 3), never ok",
    rc == 3 and has_line(o, "could-not-run:fixture-prunes-checkout:empty-population"), "rc=" .. rc .. " out=[" .. o .. "]")

-- 7. LITMUS, bare prune in a command: value
rc, o = guard(tree({ ["helper.sh"] = "#!/usr/bin/env bash\necho ok\n" },
    { ["zz.yaml"] = 'critical_path:\n  - step: "x"\n    command: "echo \\"t\\" && git worktree prune"\n' }))
check("LITMUS: a litmus command: running git worktree prune with no -C is refused",
    rc == 1 and has_line(o, "violation:fixture-prunes-checkout:openspec/litmus-tests/zz.yaml:3:worktree-prune"), "rc=" .. rc .. " out=[" .. o .. "]")

-- 8. TOOL, a non-fixture script on PROJECT_ROOT
rc, o = guard(tree({ ["cleanup-helper.sh"] = '#!/usr/bin/env bash\ngit -C "${PROJECT_ROOT}" worktree prune\n' }))
check("TOOL: a non-fixture script pruning ${PROJECT_ROOT} is refused",
    rc == 1 and has_line(o, "violation:fixture-prunes-checkout:scripts/cleanup-helper.sh:2:worktree-prune"), "rc=" .. rc .. " out=[" .. o .. "]")

run({ "rm", "-rf", W })

if #failed > 0 then
    verdict.emit("violation:fixture-prunes-checkout-fixture:" .. #failed .. ":of:" .. (#passed + #failed), 1,
        "failed arms: " .. table.concat(failed, "; "))
end
verdict.ok("fixture-prunes-checkout-fixture", #passed)
