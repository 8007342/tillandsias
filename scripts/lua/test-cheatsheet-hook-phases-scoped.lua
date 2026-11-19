-- @trace order:2083-6k44
-- @env PATH
-- test-cheatsheet-hook-phases-scoped.lua — the pre-commit hook's two cheatsheet
-- phases (whose checkers each `cargo build -p tillandsias-policy` first) run
-- only when the commit stages a cheatsheet or policy input.
--   1 UNRELATED  staging README.md runs neither checker (0 calls; pre-fix: 2)
--   2 CHEATSHEET staging cheatsheets/x.md runs both (2 calls) — the positive control
--   3 POLICY     staging crates/tillandsias-policy/src/lib.rs runs both (2 calls)
-- The hook is the REAL file, run in a scratch repo; only the two checkers are
-- stubs, and each stub appends one line to a counter, so a call is counted
-- whether or not cargo would have succeeded.
local HOOK = "scripts/hooks/pre-commit-openspec.sh"
if not fs.exists(HOOK) then
    verdict.emit("violation:cheatsheet-hook-scope-fixture:no-subject", 1, HOOK .. " does not exist (2083-6k44)")
end

-- git, not pwd -P: under MSYS pwd prints /c/..., which a native runner calls
-- relative; git prints C:/... there and /... on Linux, absolute on both.
local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 10000 }).stdout or "")
if ROOT == "" then verdict.could_not_run("cheatsheet-hook-scope-fixture", "git rev-parse gave no root") end
local failed = {}
local function arm(name, cond, got)
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

local S = "target/plan-scratch/cheatsheet-hook-scope-" .. time.iso_utc():gsub("%W", "") .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(S .. "/scripts/hooks")
fs.mkdir(S .. "/cheatsheets")
fs.mkdir(S .. "/openspec/specs/fixture")
-- the hook exits 0 at once without openspec/specs, before any phase runs
fs.write(S .. "/openspec/specs/fixture/spec.md", "# fixture\n")
fs.mkdir(S .. "/cheatsheet-sources")
fs.mkdir(S .. "/crates/tillandsias-policy/src")
fs.write(S .. "/" .. HOOK, fs.read(HOOK))
local COUNTER = "calls.log"
fs.write(S .. "/scripts/check-cheatsheet-tiers.sh", "#!/usr/bin/env bash\necho check-cheatsheet-tiers.sh >> \"$(git rev-parse --show-toplevel)/" .. COUNTER .. "\"\nexit 0\n")
-- The sources checker is Lua on trunk, run through the plan binary the hook
-- resolves with scripts/plan-binary-probe.sh. Stub the probe to hand back a stub
-- runner that counts a `script run scripts/lua/check-cheatsheet-sources.lua`,
-- so the hook's scoping stays real and no real plan binary is needed.
fs.mkdir(S .. "/scripts/lua")
fs.write(S .. "/scripts/lua/check-cheatsheet-sources.lua", "-- stub\n")
fs.write(S .. "/scripts/stub-plan", "#!/usr/bin/env bash\n"
    .. "[ \"$1 $2 $3\" = \"script run scripts/lua/check-cheatsheet-sources.lua\" ] || exit 9\n"
    .. "echo check-cheatsheet-sources.lua >> \"$(git rev-parse --show-toplevel)/" .. COUNTER .. "\"\nexit 0\n")
fs.write(S .. "/scripts/plan-binary-probe.sh", "resolve_plan_binary() { printf '%s\\n' ./scripts/stub-plan; }\n")
proc.run({ argv = { "chmod", "+x", S .. "/scripts/stub-plan" } })
fs.write(S .. "/cheatsheet-sources/INDEX.json", "{}\n")
fs.write(S .. "/README.md", "seed\n")
fs.write(S .. "/.gitignore", COUNTER .. "\n")

local function git(...)
    local argv = { "git", "-C", S, "-c", "user.name=fixture", "-c", "user.email=fixture@invalid", ... }
    return proc.run({ argv = argv, timeout_ms = 60000 })
end
git("init", "-q")
git("add", "-A")
git("commit", "-qm", "seed", "--no-verify")

local function calls_after_staging(path, body)
    fs.write(S .. "/" .. COUNTER, "")
    fs.write(S .. "/" .. path, body)
    git("add", "--", path)
    -- cwd, not `bash -c "cd …"`: under a native Windows runner a relative
    -- path handed to a bash -c string can reach a bash that resolves it
    -- elsewhere, and the arm then counts zero calls for the wrong reason.
    proc.run({ argv = { "bash", HOOK }, cwd = ROOT .. "/" .. S, timeout_ms = 120000 })
    git("commit", "-qm", "step", "--no-verify")
    local _, n = (fs.read(S .. "/" .. COUNTER) or ""):gsub("\n", "")
    return n
end

local n = calls_after_staging("README.md", "changed\n")
arm("1 UNRELATED staging README.md runs no cheatsheet checker", n == 0, n)
n = calls_after_staging("cheatsheets/x.md", "---\ntier: bundled\n---\n")
arm("2 CHEATSHEET staging a cheatsheet runs both checkers", n == 2, n)
n = calls_after_staging("crates/tillandsias-policy/src/lib.rs", "// x\n")
arm("3 POLICY staging a policy source runs both checkers", n == 2, n)

proc.run({ argv = { "rm", "-rf", S }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:cheatsheet-hook-scope-fixture:" .. #failed .. "-failed", 1)
end
verdict.ok("cheatsheet-hook-scope-fixture", "3 arms")
