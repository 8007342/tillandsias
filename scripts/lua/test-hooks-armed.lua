-- @trace order:1255-s4im
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-hooks-armed.lua — scripts/lua/check-hooks-armed.lua on scratch repos:
--   1 ABSENT   no pre-push: degraded:hooks:absent, exit 1, remedy ensure-hooks.sh
--   2 CURRENT  the installer's marker: ok:hooks-armed:<marker>, exit 0
--   3 STALE    an older marker: degraded:hooks:stale:<have>-><want>, exit 1
--   4 FOREIGN  a hook with no marker: refused:hooks:foreign-pre-push, exit 3
--   (no GLOBAL arm: the runner scrubs a child's environment, so a fixture
--   cannot point the checker's own git at a scratch global config. That
--   branch copies ensure-hooks.sh's, which test-ensure-hooks.sh covers, 1442-wyf9.)
--   6 NOREPO   not a checkout: blocked, exit 2
--   7 READONLY the ABSENT run installed nothing: still no pre-push after it
--   8 LIVE     this checkout answers in the grammar
--
-- Usage: tillandsias-plan script run scripts/lua/test-hooks-armed.lua

local SUBJECT = "scripts/lua/check-hooks-armed.lua"
local PLAN = env.get("TILLANDSIAS_PLAN_BIN")
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("hooks-armed-fixture", "no plan binary named (TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("hooks-armed-fixture", "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/hooks-armed-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name .. (got and (" — " .. got) or "")) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

local WANT = "tillandsias-pre-push-v8"
-- A scratch checkout with an installer naming WANT, and an optional hook body.
local function repo(name, hook)
    local d = REL .. "/" .. name
    fs.mkdir(d .. "/scripts")
    fs.write(d .. "/scripts/install-hooks.sh", 'PREPUSH_MARKER="# ' .. WANT .. '"\n')
    proc.run({ argv = { "git", "init", "-q", "." }, cwd = ROOT .. "/" .. d, timeout_ms = 30000 })
    if hook then fs.write(d .. "/.git/hooks/pre-push", hook) end
    return ROOT .. "/" .. d
end
local function check(dir, extra)
    local e = { TILLANDSIAS_HOOKS_CHECK_ROOT = dir }
    for k, v in pairs(extra or {}) do e[k] = v end
    local r = proc.run({ argv = { PLAN, "script", "run", ROOT .. "/" .. SUBJECT }, cwd = ROOT, timeout_ms = 60000, env = e })
    return r.code or -1, text.trim(r.stdout or ""), text.trim(r.stderr or "")
end

local d = repo("absent", nil)
local rc, o, e = check(d)
arm("1 ABSENT no pre-push is due, with the ensure-hooks remedy",
    rc == 1 and o == "degraded:hooks:absent" and e:find("bash scripts/ensure-hooks.sh", 1, true) ~= nil, rc .. " " .. o)
local still = proc.run({ argv = { "test", "-e", d .. "/.git/hooks/pre-push" }, timeout_ms = 10000 })
arm("7 READONLY the absent run installed nothing", still.code ~= 0, "pre-push exists=" .. tostring(still.code == 0))

rc, o = check(repo("current", "#!/bin/bash\n# " .. WANT .. "\n"))
arm("2 CURRENT the installer's marker is ok", rc == 0 and o == "ok:hooks-armed:" .. WANT, rc .. " " .. o)

rc, o = check(repo("stale", "#!/bin/bash\n# tillandsias-pre-push-v7\n"))
arm("3 STALE an older marker is due", rc == 1 and o == "degraded:hooks:stale:tillandsias-pre-push-v7->" .. WANT, rc .. " " .. o)

rc, o = check(repo("foreign", "#!/bin/bash\nexit 0\n"))
arm("4 FOREIGN a hook with no marker is refused", rc == 3 and o:find("^refused:hooks:foreign%-pre%-push:") ~= nil, rc .. " " .. o)

fs.mkdir(REL .. "/norepo")
local nr = proc.run({ argv = { "mktemp", "-d", "/tmp/hooks-armed-norepo.XXXXXX" }, timeout_ms = 10000 })
local nrd = text.trim(nr.stdout or "")
rc, o = check(nrd)
arm("6 NOREPO a non-checkout is blocked", rc == 2 and o == "blocked:hooks:not-a-checkout", rc .. " " .. o)
if nrd ~= "" then proc.run({ argv = { "rmdir", nrd }, timeout_ms = 10000 }) end

local live = proc.run({ argv = { PLAN, "script", "run", SUBJECT }, cwd = ROOT, timeout_ms = 60000 })
local lo = text.trim(live.stdout or "")
arm("8 LIVE this checkout answers in the grammar",
    lo:find("^ok:hooks%-armed:") ~= nil or lo:find("^degraded:hooks:") ~= nil or lo:find("^refused:hooks:") ~= nil, lo)

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:hooks-armed-fixture:" .. #failed .. "-failed", 1)
end
verdict.ok("hooks-armed-fixture", "7 arms")
