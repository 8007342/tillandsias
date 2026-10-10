-- @trace order:1580-8hra, order:1384-bxhk
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-shell-ratchet.lua — scripts/lua/check-shell-ratchet.lua counts the
-- shell corpus on every --check, refuses what would grow it back, and its
-- floors only descend (1384-bxhk verifiable_closure, arms in its order). The
-- Lua port of scripts/test-shell-ratchet.sh (1580-8hra), which nothing ran and
-- which scored 5/8 on a clean linux-next; this one runs in ./build.sh --check.
--
--   1 COUNTS     the one-line grammar; sh= equals an independent `find` of
--                scripts/{check,test,verify,guard}-*.sh at maxdepth 1
--   2 DECIDER    adding scripts/check-zzz.sh: violation:shell-ratchet:new-decider,
--                exit 1, and the remedy names `tillandsias-plan script run`
--   3 LITMUS     once a steps: litmus exists, a new command: with `a | b` outside
--                quotes is refused; the same pipe inside a single-quoted literal
--                is accepted
--   4 FLOORS     a commit RAISING a floor is refused; a commit LOWERING one (with
--                the pipe really removed) is accepted
--   5 EMPTY      an empty scan population is could-not-run (exit 3), never ok
--   6 STRINGS    an allow_shell_strings declaration set true in scripts/lua is
--                counted (the token is ASSEMBLED below: this file is itself in
--                scripts/lua, and spelled whole it would be counted too)
--   7 FIXTURE    a NEW test-*.sh is counted and warned, not refused (coordinator
--                scope 2026-10-01: fixtures stay shell until scripts/lua can spawn)
--   8 PIPES      a NEW pipe site in a script is counted and warned, not refused
--
-- WHY ARMS 3, 4 AND 6 WERE RED ON TRUNK (1580-8hra, measured): one real tree
-- file. openspec/litmus-tests/litmus-reset-state-contract.yaml piped a
-- `command:` (`bash scripts/test-install-macos-setup-is-quiet.sh | tail -1`)
-- with no `litmus` floor line, so once an arm adds a steps: litmus the dormant
-- piped-command refusal fired on it, in every arm sharing that scratch repo.
-- The pipe was dropped rather than floored: a floor line is a raise, and the
-- litmus runner's expected_behavior is a containment match, so `| tail -1`
-- bought nothing and hid the fixture's exit code.
--
-- HERMETIC, AND IT ENCODES NO MOMENT: every arm runs in a FRESH scratch git repo
-- under target/plan-scratch seeded from this tree's scripts/ and litmus files,
-- with TILLANDSIAS_REPO_ROOT pinned to it, so the floor-history commits never
-- touch the real repo and no arm compares against a ref that moves.
--
-- Usage: tillandsias-plan script run scripts/lua/test-shell-ratchet.lua [-- --plan <bin>]

local RATCHET_REL = "scripts/lua/check-shell-ratchet.lua"
if not fs.exists(RATCHET_REL) then
    verdict.emit("violation:shell-ratchet-fixture:no-ratchet", 1,
        "scripts/lua/check-shell-ratchet.lua does not exist — nothing counts the shell corpus (1384-bxhk)")
end

local PLAN
for i = 1, #arg do if arg[i] == "--plan" then PLAN = arg[i + 1] end end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("shell-ratchet-fixture", "no plan binary named (--plan, TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 120000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local function must(r, what)
    if not (r.status == "exited" and r.code == 0) then
        verdict.could_not_run("shell-ratchet-fixture", what .. " failed: " .. (r.stderr or ""))
    end
    return r
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
local RATCHET = ROOT .. "/" .. RATCHET_REL

-- A per-run scratch dir under target/plan-scratch, named from the clock.
local REL = "target/plan-scratch/shell-ratchet-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL
fs.mkdir(REL)

local function G(dir, args)
    local argv = { "git", "-c", "user.email=f@f", "-c", "user.name=f", "-c", "commit.gpgsign=false" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    return must(run(argv, { cwd = W .. "/" .. dir }), "git " .. table.concat(args, " "))
end
local function commit(dir, msg) G(dir, { "add", "-A" }); G(dir, { "commit", "-qm", msg }) end
-- seed <dir>: a fresh repo holding this tree's scripts/ and litmus files
local function seed(dir)
    fs.mkdir(REL .. "/" .. dir .. "/openspec")
    must(run({ "cp", "-R", ROOT .. "/scripts", W .. "/" .. dir .. "/scripts" }), "seeding scripts/")
    must(run({ "cp", "-R", ROOT .. "/openspec/litmus-tests", W .. "/" .. dir .. "/openspec/litmus-tests" }), "seeding litmus-tests/")
    -- proc.run's command-policy audit writes .cache/metrics/ under a repo root
    -- (1443-w9hf); gitignored in the real checkout, so ignored here too.
    fs.write(REL .. "/" .. dir .. "/.gitignore", ".cache/\n")
    G(dir, { "init", "-q" })
    commit(dir, "seed")
end
local function wr(dir, rel, content) fs.write(REL .. "/" .. dir .. "/" .. rel, content) end
local function rd(dir, rel) return fs.read(REL .. "/" .. dir .. "/" .. rel) end
local function rm(dir, rel) must(run({ "rm", "-f", W .. "/" .. dir .. "/" .. rel }), "rm " .. rel) end
local function ratchet(dir, ...)
    local argv = { PLAN, "script", "run", RATCHET }
    local extra = { ... }
    if #extra > 0 then argv[#argv + 1] = "--"; for _, a in ipairs(extra) do argv[#argv + 1] = a end end
    local r = run(argv, { cwd = W .. "/" .. dir, env = { TILLANDSIAS_REPO_ROOT = W .. "/" .. dir } })
    return (r.status == "exited" and r.code or -1), (r.stdout or ""), (r.stderr or "")
end
local function has_line(s, want) for _, l in ipairs(text.lines(s)) do if l == want then return true end end return false end
local function grep(s, re) for _, l in ipairs(text.lines(s)) do if text.is_match(l, re) then return l end end return nil end

local passed, failed = {}, {}
local function check(name, cond, why)
    if cond then passed[#passed + 1] = name; out.line("ok:   " .. name)
    else failed[#failed + 1] = name; out.line("FAIL: " .. name .. " — " .. why) end
end

-- ── ARM 1: COUNTS ──────────────────────────────────────────────────────────
seed("s1")
local rc, o, e = ratchet("s1")
local boot = {}
for _, l in ipairs(text.lines(rd("s1", "scripts/portability/bootstrap-shell-allowlist.txt") or "")) do
    local f = l:match("^%s*([^#%s]%S*)"); if f then boot[f] = true end
end
local found = must(run({ "find", "scripts", "-maxdepth", "1", "(", "-name", "check-*.sh", "-o", "-name", "test-*.sh",
    "-o", "-name", "verify-*.sh", "-o", "-name", "guard-*.sh", ")" }, { cwd = W .. "/s1" }), "find")
local want = 0
for _, l in ipairs(text.lines(found.stdout or "")) do if l ~= "" and not boot[l] then want = want + 1 end end
check("COUNTS: the grammar line, with sh= equal to an independent find (" .. want .. ")",
    rc == 0 and grep(o, [[^ok:shell-ratchet:sh=[0-9]+:floor:[0-9]+ pipes=[0-9]+:floor:[0-9]+ litmus-form:command=[0-9]+:steps=[0-9]+:rust_queries=[0-9]+ gate-steps:sh=[0-9]+:lua=[0-9]+ shell-strings=[0-9]+$]]) ~= nil
        and o:find("ok:shell-ratchet:sh=" .. want .. ":", 1, true) == 1,
    "rc=" .. rc .. " out=[" .. o .. "] want sh=" .. want)

-- ── ARM 2: a NEW .sh decider ───────────────────────────────────────────────
wr("s1", "scripts/check-zzz.sh", "#!/usr/bin/env bash\necho ok:zzz\n")
rc, o, e = ratchet("s1")
check("DECIDER: a new scripts/check-zzz.sh is refused (exit 1), naming script run as the remedy",
    rc == 1 and has_line(o, "violation:shell-ratchet:new-decider:scripts/check-zzz.sh")
        and e:find("tillandsias-plan script run", 1, true) ~= nil,
    "rc=" .. rc .. " out=[" .. o .. "]")
rm("s1", "scripts/check-zzz.sh")

-- ── ARM 3: a NEW piped litmus command, once steps: exists ──────────────────
-- The scratch litmus names are ASSEMBLED, never spelled whole, or
-- check-litmus-pin-claims reads them as claims on litmus tests that do not exist.
local LP = "litmus"
wr("s1", "openspec/litmus-tests/zz-steps.yaml", "name: " .. LP .. ":zz-steps\nsteps:\n  - run: x\n")
commit("s1", "a steps: litmus exists")
wr("s1", "openspec/litmus-tests/zz-quoted.yaml", "name: " .. LP .. ":zz-quoted\ncritical_path:\n  - command: \"echo 'a | b'\"\n")
local q_rc, q_o = ratchet("s1")
wr("s1", "openspec/litmus-tests/zz-piped.yaml", "name: " .. LP .. ":zz-piped\ncritical_path:\n  - command: \"printf x | grep -q x\"\n")
rc, o = ratchet("s1")
check("LITMUS: with steps: present, a new piped command: is refused; a pipe inside a single-quoted literal is accepted",
    q_rc == 0 and rc == 1 and has_line(o, "violation:shell-ratchet:new-piped-command:openspec/litmus-tests/zz-piped.yaml"),
    "quoted rc=" .. q_rc .. " out=[" .. q_o .. "]; piped rc=" .. rc .. " out=[" .. o .. "]")
-- Never committed, so removing them leaves the tree clean (zz-steps stays).
rm("s1", "openspec/litmus-tests/zz-piped.yaml"); rm("s1", "openspec/litmus-tests/zz-quoted.yaml")

-- ── ARM 4: floors only descend, judged over the floor file's own history ───
local F = "scripts/portability/pipe-site-floor.txt"
local function set_floor(path, n)
    local t = {}
    for _, l in ipairs(text.lines(rd("s1", F))) do
        local kind, p = l:match("^(%a+)%s+(%S+)%s+%d+")
        if kind == "scripts" and p == path then l = ("scripts %s %d"):format(p, n) end
        t[#t + 1] = l
    end
    wr("s1", F, table.concat(t, "\n") .. "\n")
end
local victim, vn
for _, l in ipairs(text.lines(rd("s1", F))) do
    local p, n = l:match("^scripts%s+(%S+)%s+(%d+)")
    if p and tonumber(n) > 1 then victim, vn = p, tonumber(n); break end
end
if not victim then verdict.could_not_run("shell-ratchet-fixture", "ARM 4: no scripts floor line above 1 to raise and lower") end
set_floor(victim, vn + 5)
commit("s1", "raise a floor")
local up_rc, up_o = ratchet("s1")
G("s1", { "revert", "--no-edit", "HEAD" })
-- LOWER honestly: remove one real pipe site from the victim (a `|` outside
-- quotes on a non-comment line, as the ratchet counts) and lower its floor.
local vlines, cut = text.lines(rd("s1", victim)), nil
for i, l in ipairs(vlines) do
    local s = l:gsub("'[^']*'", "''"):gsub('"[^"]*"', '""')
    if not s:find("^%s*#") then
        s = s:gsub("%s#.*$", ""):gsub("||", "")
        if s:find("|", 1, true) then cut = i; break end
    end
end
if not cut then verdict.could_not_run("shell-ratchet-fixture", "ARM 4: no pipe line found in " .. victim) end
table.remove(vlines, cut)
wr("s1", victim, table.concat(vlines, "\n") .. "\n")
local _, dump = ratchet("s1", "--dump-floors")
local actual
for _, l in ipairs(text.lines(dump)) do
    local p, n = l:match("^scripts%s+(%S+)%s+(%d+)")
    if p == victim then actual = tonumber(n) end
end
set_floor(victim, actual or 0)
commit("s1", "port a pipe away and lower its floor")
local down_rc, down_o = ratchet("s1")
check("FLOORS: raising " .. victim .. "'s floor is refused; lowering it (" .. vn .. " -> " .. tostring(actual) .. ") with the pipe removed is accepted",
    up_rc == 1 and up_o:find("violation:shell-ratchet:floor-raised:" .. F .. ":scripts " .. victim, 1, true) ~= nil
        and down_rc == 0 and actual ~= nil and actual < vn,
    "up rc=" .. up_rc .. " out=[" .. up_o .. "]; down rc=" .. down_rc .. " out=[" .. down_o .. "] floor " .. vn .. " -> " .. tostring(actual))

-- ── ARM 5: an empty population is could-not-run ────────────────────────────
fs.mkdir(REL .. "/empty/scripts/portability")
G("empty", { "init", "-q" })
rc, o = ratchet("empty")
check("EMPTY: an empty population is could-not-run:shell-ratchet:empty-population (exit 3), never ok",
    rc == 3 and text.trim(o) == "could-not-run:shell-ratchet:empty-population", "rc=" .. rc .. " out=[" .. o .. "]")

-- ── ARM 6: allow_shell_strings is counted ──────────────────────────────────
wr("s1", "scripts/lua/zz-strings.lua", "-- script{allow_shell_strings" .. "=true}\nverdict.ok(\"x\")\n")
rc, o = ratchet("s1")
check("STRINGS: an allow_shell_strings declaration set true in scripts/lua is counted (shell-strings=1)",
    grep(o, [[shell-strings=1$]]) ~= nil, "rc=" .. rc .. " out=[" .. o .. "]")

-- ── ARM 7: a NEW .sh FIXTURE is counted, not refused (coordinator scope) ────
seed("s7")
wr("s7", "scripts/test-zzz.sh", "#!/usr/bin/env bash\necho ok:zzz-fixture\n")
rc, o, e = ratchet("s7")
check("FIXTURE: a new scripts/test-zzz.sh passes with a warn:shell-ratchet:new-shell-fixture line",
    rc == 0 and grep(o, [[^ok:shell-ratchet:]]) ~= nil
        and e:find("warn:shell-ratchet:new-shell-fixture:scripts/test-zzz.sh", 1, true) ~= nil,
    "rc=" .. rc .. " out=[" .. o .. "] err=[" .. e:sub(1, 300) .. "]")

-- ── ARM 8: a NEW pipe site in a script is counted, not refused ─────────────
seed("s8")
wr("s8", "scripts/zzz-helper.sh", "#!/usr/bin/env bash\necho a | cat\n")
rc, o, e = ratchet("s8")
check("PIPES: a new pipe site passes with a warn:shell-ratchet:new-pipes line",
    rc == 0 and grep(o, [[^ok:shell-ratchet:]]) ~= nil
        and e:find("warn:shell-ratchet:new-pipes:scripts/zzz-helper.sh:1>floor:0", 1, true) ~= nil,
    "rc=" .. rc .. " out=[" .. o .. "] err=[" .. e:sub(1, 300) .. "]")

run({ "rm", "-rf", W })

if #failed > 0 then
    verdict.emit("violation:shell-ratchet-fixture:" .. #failed .. ":of:" .. (#passed + #failed), 1,
        "failed arms: " .. table.concat(failed, "; "))
end
verdict.ok("shell-ratchet-fixture", #passed)
