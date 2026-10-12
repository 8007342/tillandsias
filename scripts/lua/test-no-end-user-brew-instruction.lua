-- @trace order:956-llei, order:1593-t8xx
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-no-end-user-brew-instruction.lua — PORTED from
-- test-no-end-user-brew-instruction.sh (1593-t8xx). ORDER 956-llei: the
-- mutation pair for scripts/lua/check-no-end-user-brew-instruction.lua. A
-- guard that cannot fail on the thing it forbids is not a guard.
--
--   1 the CURRENT tree passes (the removal comment in tray-diagnose.sh is not
--     an instruction; the old guard failed on exactly that comment)
--   2 a copy with a LIVE instruction fails, naming file and line
--   3 a copy whose only mention is a trailing comment still passes
--   4 READERS: the .sh's retired terminal lines (PASS:/FAIL: ... guard ...)
--     have no reader in scripts/, the gate steps or the litmus specs; the
--     count of files searched is printed
--
-- The Lua runtime's fs.read is confined to the repository root, so the guard
-- reads the scratch copies with TILLANDSIAS_REPO_ROOT pointed at the scratch
-- directory (under target/plan-scratch), as the .sh did with its mktemp dir.
--
-- Terminal line: ok:no-end-user-brew-instruction-fixture:<n> or
-- refused:no-end-user-brew-instruction-fixture:<failed>.
--
-- Usage: TILLANDSIAS_PLAN_BIN=<bin> tillandsias-plan script run scripts/lua/test-no-end-user-brew-instruction.lua

local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or env.get("TILLANDSIAS_PLAN_BIN") or ""
if PLAN == "" then
    verdict.emit("skip:no-end-user-brew-instruction-fixture:no-script-runner — set TILLANDSIAS_PLAN_BIN to a tillandsias-plan with `script run`", 0)
end
local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" } }).stdout or "")
local GUARD = "scripts/lua/check-no-end-user-brew-instruction.lua"
local REL = "target/plan-scratch/brew-guard-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL
fs.mkdir(REL)
local passed, failed = 0, 0
local function ok(m) out.line("ok   " .. m); passed = passed + 1 end
local function bad(m) out.line("FAIL " .. m); failed = failed + 1 end

-- The guard's verdict line and exit code on the named files.
local function guard(files, repo_root)
    local argv = { PLAN, "script", "run", ROOT .. "/" .. GUARD, "--" }
    for _, f in ipairs(files) do argv[#argv + 1] = f end
    local r = proc.run({ argv = argv, cwd = ROOT, env = repo_root and { TILLANDSIAS_REPO_ROOT = repo_root } or nil, timeout_ms = 60000 })
    return text.trim(r.stdout or ""), (r.status == "exited" and r.code or -1)
end

local o, rc = guard({ "scripts/tray-diagnose.sh", "scripts/diagnose-macos-provision.sh" })
if rc == 0 and o == "ok:no-end-user-brew-instruction:2" then ok("current tree passes: " .. o)
else bad("current tree passes (rc=" .. rc .. ": " .. o .. ")") end

local base = fs.read("scripts/tray-diagnose.sh")
fs.write(REL .. "/live.sh", base .. '\necho "install it: brew install jq" >&2\nexit 1\n')
o, rc = guard({ W .. "/live.sh" }, W)
if o:match("^violation:end%-user%-brew%-instruction:.*live%.sh:%d") and rc == 1 then
    ok("live instruction FAILS with file:line (" .. o .. ")")
else bad("live instruction not caught (rc=" .. rc .. ": " .. o .. ")") end

fs.write(REL .. "/comment.sh", base .. '\necho "jq is optional"  # we no longer say brew install jq here\n')
o, rc = guard({ W .. "/comment.sh" }, W)
if rc == 0 then ok("trailing comment mention still passes")
else bad("trailing comment mention failed (rc=" .. rc .. ": " .. o .. ")") end

-- 4: the retired terminal lines, assembled so this file cannot match itself.
local NEEDLES = { "PA" .. "SS: no-end-user-brew-instruction guard", "FA" .. "IL: no-end-user-brew-instruction guard" }
local SELF = "scripts/lua/test-no-end-user-brew-instruction.lua"
local searched, hits = 0, {}
for _, root in ipairs({ "scripts", "openspec/litmus-tests" }) do
    for _, f in ipairs(fs.walk(root)) do
        if f ~= SELF and (f:sub(-3) == ".sh" or f:sub(-4) == ".lua" or f:sub(-5) == ".step" or f:sub(-5) == ".yaml") then
            searched = searched + 1
            local okr, body = pcall(fs.read, f)
            if okr then
                for _, n in ipairs(NEEDLES) do
                    if text.contains(body, n) then hits[#hits + 1] = f; break end
                end
            end
        end
    end
end
if #hits == 0 and searched > 100 then
    ok("the retired PASS:/FAIL: terminal lines have 0 readers (" .. searched .. " files searched: scripts/, gate steps, litmus specs)")
else
    bad("readers of the retired terminal lines: " .. #hits .. " in " .. searched .. " files: " .. table.concat(hits, ", "))
end

proc.run({ argv = { "rm", "-rf", W } })
if failed == 0 then verdict.emit("ok:no-end-user-brew-instruction-fixture:" .. passed, 0) end
verdict.emit("refused:no-end-user-brew-instruction-fixture:" .. failed, 1)
