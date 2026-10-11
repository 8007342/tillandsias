-- @trace order:1619-7i9r
-- @env PATH TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-bare-mktemp.lua — both exit criteria of 1619-7i9r.
--
-- THE COUNTER (scripts/lua/check-bare-mktemp.lua) on CONSTRUCTED roots:
--   1 COUNT   six bare forms are sites (-d, a file, -t x, -d -t x, -d 2>/dev/null,
--             -d || exit), two templated calls are counted apart, and a comment,
--             a regex string, `command -v mktemp` and a longer word are not
--             calls: sites=6, templated=2
--   2 NEW     the same file over its floor (5) is refused, named
--   3 STALE   a floor above the count (7) is refused, so the floor only falls
--   4 ABSENT  a file with sites and no floor line is new at floor 0
--   5 EMPTY   no scripts: could-not-run, exit 3
--   6 DUMP    --dump-floor prints the file at its count
-- THE CONVERSION, on this host, in one run: the mktemp call from
-- scripts/test-capture-helper.sh as it stood at PRE_REV, and as it stands now,
-- each run with TMPDIR set to a fresh directory:
--   7 the converted call lands in TMPDIR. On darwin the bare call lands outside
--     it (the defect, measured on darwin 27.0.1). On GNU the bare call lands
--     there too, which the arm says rather than counting as the defect.
--
-- Usage: tillandsias-plan script run scripts/lua/test-bare-mktemp.lua

local PRE_REV = "699a7d767"
local CONVERTED = "scripts/test-capture-helper.sh"
local SUBJECT_REL = "scripts/lua/check-bare-mktemp.lua"
if not fs.exists(SUBJECT_REL) then
    verdict.emit("violation:bare-mktemp-fixture:no-subject", 1, SUBJECT_REL .. " does not exist (1619-7i9r)")
end
local PLAN = env.get("TILLANDSIAS_PLAN_BIN")
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("bare-mktemp-fixture", "no plan binary named (TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("bare-mktemp-fixture", "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/bare-mktemp-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)

local failed = {}
local function arm(name, cond, got)
    if cond then out.line("ok:   " .. name .. (got and (" — " .. got) or "")) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

-- ── the counter ────────────────────────────────────────────────────────────
local SAMPLE = table.concat({
    'a="$(mktemp -d)"',
    'b=$(mktemp)',
    'c="$(mktemp -t x)"',
    'd="$(mktemp -d -t x)"',
    'e="$(mktemp -d 2>/dev/null)"',
    'f="$(mktemp -d)" || exit 1',
    'g="$(mktemp -d "${TMPDIR:-/tmp}/g.XXXXXX")"',
    'h=$(mktemp "$d/h.XXXXXX")',
    '# i="$(mktemp -d)" was the old way',
    "simple='(tee|cp|mktemp|truncate)'",
    'command -v mktemp >/dev/null',
    'mktemp-wrapper -d',
    '' }, "\n")
local function root_with(name, files, floor)
    local d = REL .. "/" .. name
    fs.mkdir(d .. "/scripts")
    for f, body in pairs(files) do fs.write(d .. "/scripts/" .. f, body) end
    fs.write(d .. "/floor.txt", floor or "")
    return d
end
local function count(d, extra)
    local argv = { PLAN, "script", "run", SUBJECT_REL }
    if extra then argv[#argv + 1] = "--"; argv[#argv + 1] = extra end
    local r = proc.run({ argv = argv, cwd = ROOT, timeout_ms = 60000,
        env = { TILLANDSIAS_BARE_MKTEMP_SCAN_DIR = d .. "/scripts",
                TILLANDSIAS_BARE_MKTEMP_FLOOR = d .. "/floor.txt" } })
    return r.code or -1, text.trim(r.stdout or "")
end

local d = REL .. "/count"
root_with("count", { ["test-a.sh"] = SAMPLE }, d .. "/scripts/test-a.sh 6\n")
local rc, o = count(d)
arm("1 COUNT six bare forms are sites, two templated calls apart, four non-calls ignored",
    rc == 0 and o == "ok:bare-mktemp:sites=6:floor=6:files=1:templated=2", rc .. " " .. o)

d = REL .. "/new"
root_with("new", { ["test-a.sh"] = SAMPLE }, d .. "/scripts/test-a.sh 5\n")
rc, o = count(d)
arm("2 NEW a file over its floor is refused, named",
    rc == 1 and o:find("violation:bare-mktemp:new-site:" .. d .. "/scripts/test-a.sh:6>floor:5", 1, true) ~= nil, rc .. " " .. o)

d = REL .. "/stale"
root_with("stale", { ["test-a.sh"] = SAMPLE }, d .. "/scripts/test-a.sh 7\n")
rc, o = count(d)
arm("3 STALE a floor above the count is refused, so the floor only falls",
    rc == 1 and o:find("violation:bare-mktemp:stale-floor:" .. d .. "/scripts/test-a.sh:6<floor:7", 1, true) ~= nil, rc .. " " .. o)

d = root_with("absent", { ["test-b.sh"] = 'x="$(mktemp -d)"\n' }, "")
rc, o = count(d)
arm("4 ABSENT a file with sites and no floor line is new at floor 0",
    rc == 1 and o:find("new-site:" .. d .. "/scripts/test-b.sh:1>floor:0", 1, true) ~= nil, rc .. " " .. o)

fs.mkdir(REL .. "/empty/x")
fs.write(REL .. "/empty/floor.txt", "")
rc, o = count(REL .. "/empty")
arm("5 EMPTY no scripts is could-not-run", rc == 3 and o:find("could-not-run:bare-mktemp:empty-population", 1, true) ~= nil, rc .. " " .. o)

d = REL .. "/count"
rc, o = count(d, "--dump-floor")
arm("6 DUMP --dump-floor prints the file at its count",
    rc == 0 and o:find("\n" .. d .. "/scripts/test-a.sh 6\n", 1, true) ~= nil, rc .. " " .. o:sub(-200))

-- ── the conversion, measured on this host ──────────────────────────────────
local function call_in(body)
    return body and body:match('%$%((mktemp[^)]*)%)') or nil
end
local pre_src = proc.run({ argv = { "git", "show", PRE_REV .. ":" .. CONVERTED }, cwd = ROOT, timeout_ms = 30000 })
local bare, conv = call_in(pre_src.stdout), call_in(fs.read(CONVERTED))
if pre_src.code ~= 0 or not bare or not conv or bare == conv then
    arm("7 premise: the bare call at " .. PRE_REV .. " and the converted call in " .. CONVERTED .. " both found, and different",
        false, "bare=" .. tostring(bare) .. " converted=" .. tostring(conv))
else
    fs.mkdir(REL .. "/tmpd")
    local TMPD = ROOT .. "/" .. REL .. "/tmpd"
    local function where(call, name)
        fs.write(REL .. "/" .. name .. ".sh", 'p=$(' .. call .. ') || exit 3\necho "$p"\nrm -rf "$p"\n')
        local r = proc.run({ argv = { "bash", ROOT .. "/" .. REL .. "/" .. name .. ".sh" }, cwd = ROOT,
            env = { TMPDIR = TMPD }, timeout_ms = 30000 })
        local p = text.trim(r.stdout or "")
        return p, p:sub(1, #TMPD + 1) == TMPD .. "/"
    end
    local bp, b_in = where(bare, "bare")
    local cp, c_in = where(conv, "converted")
    local os_ = text.trim(proc.run({ argv = { "uname", "-s" }, timeout_ms = 10000 }).stdout or "")
    local got = "host=" .. os_ .. " bare[" .. bare .. "] -> " .. bp .. (b_in and " (in TMPDIR)" or " (OUTSIDE TMPDIR)") ..
        "; converted -> " .. cp .. (c_in and " (in TMPDIR)" or " (OUTSIDE TMPDIR)")
    if os_ == "Darwin" then
        arm("7 CONVERSION on darwin: the converted call lands in TMPDIR, the bare one outside it", c_in and not b_in, got)
    else
        arm("7 CONVERSION the converted call lands in TMPDIR (GNU: the bare one does too; the defect is darwin's)", c_in, got)
    end
end

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:bare-mktemp-fixture:" .. #failed .. "-failed", 1)
end
verdict.ok("bare-mktemp-fixture", "7 arms")
