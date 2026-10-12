-- @trace order:1570-k4fx, spec:cheatsheet-tooling
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-cheatsheet-refs.lua — scripts/lua/check-cheatsheet-refs.lua (ported
-- from the .sh by 1570-k4fx) in scratch repos. A Lua fixture on `script run`,
-- not a .sh: a new shell fixture adds one item to the shell-to-lua counter and
-- cancels the port it accompanies (the carried-obligation guard, 1577-g96z,
-- read the first draft of this change as due for exactly that). Each arm
-- exists because a weaker checker could pass it:
--
--   1 RESOLVES  both reference shapes (`@cheatsheet a, b` and `## See also`
--               bullets, bare and backticked) are counted and resolve.
--   2 SCOPE     a bullet OUTSIDE `## See also` is not a reference.
--   3 DANGLING  NEGATIVE CONTROL: one `@cheatsheet missing/x.md` is refused BY
--               NAME (exit 1) ...
--   4 CONTROL   ... and the same tree with the file present passes.
--   5 NO TOOL   the check passes with a PATH that resolves nothing — no rg, no
--               toolbox. The .sh refused here ~20 min into a Windows gate
--               (esmeraldinha 2026-09-12) and, with rg present-but-broken,
--               passed over nothing (1138-bb5r).
--   6 NO DIR    a tree with no cheatsheets/ is refused (exit 2), never ok.
--
-- Usage: tillandsias-plan script run scripts/lua/test-cheatsheet-refs.lua [-- --plan <bin>]

local GUARD_REL = "scripts/lua/check-cheatsheet-refs.lua"
if not fs.exists(GUARD_REL) then
    verdict.emit("violation:cheatsheet-refs-fixture:no-checker", 1, GUARD_REL .. " does not exist")
end
local PLAN
for i = 1, #arg do if arg[i] == "--plan" then PLAN = arg[i + 1] end end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("cheatsheet-refs-fixture", "no plan binary named (--plan, TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 120000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
local GUARD = ROOT .. "/" .. GUARD_REL
local REL = "target/plan-scratch/cheatsheet-refs-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)

local passed, failed = {}, {}
local function check(name, cond, why)
    if cond then passed[#passed + 1] = name; out.line("ok:   " .. name)
    else failed[#failed + 1] = name; out.line("FAIL: " .. name .. " — " .. why) end
end
local function has(s, line) for _, l in ipairs(text.lines(s)) do if l == line then return true end end return false end

local function git_init(d)
    run({ "git", "init", "-q" }, { cwd = d })
    run({ "git", "-c", "user.email=f@f", "-c", "user.name=f", "add", "-A" }, { cwd = d })
    run({ "git", "-c", "user.email=f@f", "-c", "user.name=f", "-c", "commit.gpgsign=false", "commit", "-qm", "seed" }, { cwd = d })
end
local function scratch(name) -- three cheatsheets citing each other
    local rel = REL .. "/" .. name
    for _, sub in ipairs({ "", "/cheatsheets", "/cheatsheets/runtime", "/cheatsheets/agents" }) do fs.mkdir(rel .. sub) end
    fs.write(rel .. "/cheatsheets/runtime/a.md", table.concat({
        "# a", "", "@cheatsheet runtime/b.md, agents/c.md", "", "## See also", "",
        "- runtime/b.md — bare", "- `agents/c.md` — backticked", "", "## Next", "",
        "- runtime/not-a-ref.md — outside See also", "" }, "\n"))
    fs.write(rel .. "/cheatsheets/runtime/b.md", "# b\n")
    fs.write(rel .. "/cheatsheets/agents/c.md", "# c\n")
    fs.write(rel .. "/.gitignore", ".cache/\n")
    local d = ROOT .. "/" .. rel
    git_init(d)
    return d, rel
end
local function check_in(dir, path_env)
    local env_t = { TILLANDSIAS_REPO_ROOT = dir }
    if path_env then env_t.PATH = path_env end
    local r = run({ PLAN, "script", "run", GUARD }, { cwd = dir, env = env_t })
    return (r.status == "exited" and r.code or -1), (r.stdout or "") .. (r.stderr or "")
end

-- 1 + 2. both shapes resolve; a bullet outside See also is not counted
local ok_dir = scratch("ok")
local rc, o = check_in(ok_dir)
check("RESOLVES: two @cheatsheet paths and two See-also bullets are counted (4) and resolve",
    rc == 0 and has(o, "ok:cheatsheet-refs:4"), "rc=" .. rc .. " out=[" .. o .. "]")
check("SCOPE: the bullet under the next heading is not a reference (else the count would be 5 and it would not resolve)",
    rc == 0 and not o:find("not-a-ref", 1, true), "rc=" .. rc .. " out=[" .. o .. "]")

-- 3 + 4. a dangling reference is refused by name; present, it passes
local dd, drel = scratch("dangling")
fs.write(drel .. "/cheatsheets/agents/c.md", "# c\n\n@cheatsheet missing/x.md\n")
rc, o = check_in(dd)
check("DANGLING: one unresolvable @cheatsheet is refused (exit 1) and named with its file and line",
    rc == 1 and o:find("violation:cheatsheet-refs-broken:1:of:5", 1, true) ~= nil
        and o:find("cheatsheets/agents/c.md:3: missing/x.md", 1, true) ~= nil,
    "rc=" .. rc .. " out=[" .. o .. "]")
fs.mkdir(drel .. "/cheatsheets/missing")
fs.write(drel .. "/cheatsheets/missing/x.md", "# x\n")
rc, o = check_in(dd)
check("CONTROL: the same tree with the file present passes", rc == 0 and has(o, "ok:cheatsheet-refs:5"), "rc=" .. rc .. " out=[" .. o .. "]")

-- 5. no tool at all
rc, o = check_in(ok_dir, "/nonexistent-path-1570-k4fx")
check("NO TOOL: passes with a PATH that resolves nothing (no rg, no toolbox)",
    rc == 0 and has(o, "ok:cheatsheet-refs:4"), "rc=" .. rc .. " out=[" .. o .. "]")

-- 6. no cheatsheets/ is a refusal, never ok
local nrel = REL .. "/nodir"
fs.mkdir(nrel)
fs.write(nrel .. "/README", "x\n")
fs.write(nrel .. "/.gitignore", ".cache/\n")
local nd = ROOT .. "/" .. nrel
git_init(nd)
rc, o = check_in(nd)
check("NO DIR: a tree with no cheatsheets/ is refused (exit 2), never reported ok",
    rc == 2 and has(o, "blocked:cheatsheet-refs:no-cheatsheets-dir"), "rc=" .. rc .. " out=[" .. o .. "]")

run({ "rm", "-rf", ROOT .. "/" .. REL })

if #failed > 0 then
    verdict.emit("violation:cheatsheet-refs-fixture:" .. #failed .. ":of:" .. (#passed + #failed), 1,
        "failed arms: " .. table.concat(failed, "; "))
end
verdict.ok("cheatsheet-refs-fixture", #passed)
