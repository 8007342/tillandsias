-- @env PATH HOME
-- @trace order:2224-gdir
--
-- test-fixtures-ignore-inherited-git-dir.lua — a fixture run from a hook must
-- never write the repository named by an inherited GIT_DIR. Ported from
-- scripts/test-fixtures-ignore-inherited-git-dir.sh (order 2238-vsra pays the
-- carried shell-to-lua item); same three arms.
--
-- Git exports GIT_DIR to every hook. The pre-push hook runs the preflight door,
-- the door runs fixtures, and test-check-credential-channel.sh's
-- `git -C <scratch> remote set-url ...` followed GIT_DIR to the real checkout:
-- on calmecacpilli 2026-11-22 the real origin became $W/does-not-exist.git and
-- credential.helper became manager.
--
--   1 FIXTURE  with GIT_DIR naming a victim repo, test-check-credential-channel.sh
--              leaves the victim's origin and local config unchanged.
--   2 DOOR     build.sh unsets GIT_DIR (and its siblings) before the toolbox
--              re-exec, so no hook-launched guard or fixture inherits it.
--   3 MUTANT   the same run with the fixture's unset removed DOES rewrite the
--              victim (proves arm 1 can fail).
--
-- Usage: tillandsias-plan script run scripts/lua/test-fixtures-ignore-inherited-git-dir.lua
-- Verdict: ok:fixtures-ignore-inherited-git-dir:<n> | violation:fixtures-ignore-inherited-git-dir:<n>-failed

local FX = "scripts/test-check-credential-channel.sh"
local UNSET = "unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE"
local pass, fail = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) out.line("FAIL: " .. m); fail = fail + 1 end

local root = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 }).stdout or "")
local BASE = { PATH = env.get("PATH"), HOME = env.get("HOME") }
local function run(argv, extra, ms)
    local e = {}
    for k, v in pairs(BASE) do e[k] = v end
    for k, v in pairs(extra or {}) do e[k] = v end
    return proc.run({ argv = argv, env = e, timeout_ms = ms or 30000 })
end

local REL = "target/plan-scratch/inherited-git-dir-" .. tostring(time.now_ms())
local W = root .. "/" .. REL
fs.mkdir(REL)

local function victim(name)
    local p = W .. "/" .. name
    run({ "git", "init", "-q", p })
    run({ "git", "-C", p, "remote", "add", "origin", "https://example.invalid/victim.git" })
    return p
end
local function state(p)
    local url = run({ "git", "-C", p, "remote", "get-url", "origin" })
    local cfg = run({ "git", "-C", p, "config", "--local", "--list" })
    local n = 0
    for _, l in ipairs(text.lines(cfg.stdout or "")) do
        if l:find("credential", 1, true) or l:find("hooksPath", 1, true) then n = n + 1 end
    end
    return text.trim((url.stdout or "") .. (url.stderr or "")) .. "|" .. n
end

-- 1
local V = victim("one")
local before = state(V)
run({ "bash", root .. "/" .. FX }, { GIT_DIR = V .. "/.git" }, 300000)
local after = state(V)
if before == after then ok("1 FIXTURE an inherited GIT_DIR's repo is untouched (" .. after .. ")")
else bad("1 FIXTURE the victim changed: before=[" .. before .. "] after=[" .. after .. "]") end

-- 2
local head, found = 0, false
for _, l in ipairs(text.lines(fs.read("build.sh") or "")) do
    head = head + 1
    if head > 80 then break end
    if text.starts_with(l, UNSET) then found = true; break end
end
if found then ok("2 DOOR build.sh clears GIT_DIR and its siblings before the toolbox re-exec")
else bad("2 DOOR build.sh no longer clears GIT_DIR in its first 80 lines") end

-- 3: the mutant sits beside the fixture so its relative sources still resolve
local MUT = "scripts/.mutant-gitdir-2224.sh"
local keep = {}
for _, l in ipairs(text.lines(fs.read(FX) or "")) do
    if not text.starts_with(l, UNSET) then keep[#keep + 1] = l end
end
fs.write(MUT, table.concat(keep, "\n") .. "\n")
V = victim("three")
before = state(V)
run({ "bash", root .. "/" .. MUT }, { GIT_DIR = V .. "/.git" }, 300000)
after = state(V)
proc.run({ argv = { "rm", "-f", root .. "/" .. MUT }, timeout_ms = 10000 })
if before ~= after then ok("3 MUTANT without the unset the victim IS rewritten (" .. after .. ") — arm 1 has teeth")
else bad("3 MUTANT without the unset the victim was still untouched — arm 1 proves nothing") end

proc.run({ argv = { "rm", "-rf", W }, timeout_ms = 60000 })
out.line("fixtures-ignore-inherited-git-dir: " .. pass .. " passed, " .. fail .. " failed")
if fail == 0 then verdict.emit("ok:fixtures-ignore-inherited-git-dir:" .. pass, 0) end
verdict.emit("violation:fixtures-ignore-inherited-git-dir:" .. fail .. "-failed", 1)
