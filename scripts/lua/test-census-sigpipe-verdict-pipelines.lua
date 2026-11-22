-- @trace spec:ci-release, plan 1354-uv4e, order:2118-knjy
-- @env PATH HOME TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-census-sigpipe-verdict-pipelines.lua — does the census's empty-tree mode
-- DISCRIMINATE? Ported from the .sh of the same name (order 2118-knjy).
--
-- A count from a mode nobody has checked is not a measurement. Arms, over
-- scratch git repos under target/plan-scratch (TILLANDSIAS_SIGPIPE_ROOT):
--   1  of four hand-written cases (a real verdict pipeline, a here-string, a
--      non-verdict context, one carrying `# sigpipe-ok:`) exactly ONE is flagged
--   2  it is the RIGHT one: case 1, the unmarked verdict pipeline
--   3  NEGATIVE CONTROL: a corpus with no violations answers 0
--   4  the census is a REPORT: exit 0 with violations present
--   5  the census verdict matches the pinned grammar, and counts case 1
--
-- Usage: tillandsias-plan script run scripts/lua/test-census-sigpipe-verdict-pipelines.lua

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 300000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
if ROOT == "" then verdict.could_not_run("census-sigpipe-verdict-fixture", "not inside a git checkout") end
local DECIDER = ROOT .. "/scripts/check-sigpipe-verdict-pipelines-added.sh"
if not fs.read("scripts/check-sigpipe-verdict-pipelines-added.sh") then
    verdict.could_not_run("census-sigpipe-verdict-fixture", "decider absent")
end
local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or env.get("TILLANDSIAS_PLAN_BIN") or "tillandsias-plan"
local REL = "target/plan-scratch/knjy-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL

local function repo(name, body)
    fs.mkdir(REL .. "/" .. name .. "/scripts")
    local R = W .. "/" .. name
    run({ "git", "init", "-q", R })
    fs.write(REL .. "/" .. name .. "/scripts/cases.sh", body)
    local g = { "git", "-C", R, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com" }
    local add = { table.unpack(g) }; add[#add + 1] = "add"; add[#add + 1] = "-A"; run(add)
    local ci = { table.unpack(g) }; for _, a in ipairs({ "commit", "-qm", "fixture" }) do ci[#ci + 1] = a end; run(ci)
    return R
end
-- The verdict pipeline is assembled, so this file does not itself carry one.
local GQ = "grep" .. " -q"
local CASES = "set -uo pipefail\n"
    .. "if printf '%s' \"$OUT\" | " .. GQ .. " '^ok:thing$'; then echo yes; fi\n"
    .. "if " .. GQ .. " '^ok:thing$' <<<\"$OUT\"; then echo yes; fi\n"
    .. "printf '%s' \"$OUT\" | " .. GQ .. " '^ok:thing$'\n"
    .. "if printf '%s' \"$OUT\" | " .. GQ .. " '^ok:x$'; then echo y; fi # sigpipe-ok: reviewed\n"
local R = repo("repo", CASES)
local R2 = repo("clean", "set -uo pipefail\nif " .. GQ .. " '^ok:thing$' <<<\"$OUT\"; then echo yes; fi\n")
local EMPTY = text.trim(run({ "git", "-C", R, "hash-object", "-t", "tree", "/dev/null" }).stdout or "")

local passed, failed = 0, 0
local function check(name, cond, why)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else failed = failed + 1; out.line("FAIL: " .. name .. " — " .. why) end
end
local function decide(root)
    local r = run({ "bash", DECIDER }, { env = { PATH = env.get("PATH"), HOME = env.get("HOME"),
        TILLANDSIAS_SIGPIPE_ROOT = root, TILLANDSIAS_SIGPIPE_BASE = EMPTY } })
    return text.lines((r.stdout or "") .. "\n" .. (r.stderr or ""))
end

local lines = decide(R)
local n, flagged = 0, nil
for i, l in ipairs(lines) do
    if l:sub(1, 8) == "REFUSED:" then n = n + 1; flagged = flagged or lines[i + 1] end
end
check("1 exactly one of four cases is flagged", n == 1, "got " .. n .. " — the mode does not discriminate")
check("2 the flagged line is case 1, the unmarked verdict pipeline",
    flagged ~= nil and text.contains(flagged, "ok:thing") and not text.contains(flagged, "sigpipe-ok")
        and not text.contains(flagged, "ok:x"), "flagged: " .. tostring(flagged))

local n2 = 0
for _, l in ipairs(decide(R2)) do if l:sub(1, 8) == "REFUSED:" then n2 = n2 + 1 end end
check("3 (negative control) a clean corpus answers 0", n2 == 0, "got " .. n2)

local c = run({ PLAN, "script", "run", ROOT .. "/scripts/lua/census-sigpipe-verdict-pipelines.lua" },
    { cwd = ROOT, env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_SIGPIPE_ROOT = R } })
check("4 the census is a REPORT: exit 0 with a violation present", c.code == 0, "rc=" .. tostring(c.code))
local v = text.trim(c.stdout or "")
check("5 the census verdict is in the pinned grammar and counts case 1",
    v:match("^ok:sigpipe%-verdict%-standing:%d+ sites in %d+ files$") ~= nil
        and text.starts_with(v, "ok:sigpipe-verdict-standing:1 sites in 1 files"), "verdict: '" .. v .. "'")

run({ "rm", "-rf", W })
if failed > 0 then verdict.emit("violation:census-sigpipe-verdict-fixture:" .. failed .. "-failed", 1) end
verdict.ok("census-sigpipe-verdict-fixture", tostring(passed))
