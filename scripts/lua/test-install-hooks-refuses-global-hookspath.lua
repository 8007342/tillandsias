-- @trace order:1442-wyf9, order:2212-2m8s, spec:forge-environment-discoverability
--
-- test-install-hooks-refuses-global-hookspath.lua — PORTED from
-- test-install-hooks-refuses-global-hookspath.sh (2212-2m8s), same branches,
-- same lines. scripts/install-hooks.sh must never write the repo guards into
-- a GLOBAL core.hooksPath.
--
-- A forge sets `git config --global core.hooksPath ~/.cache/tillandsias/git-hooks`.
-- A second clone inside a forge has no local hooksPath, so `git rev-parse
-- --git-path hooks` answers the global dir, and the installer used to write
-- pre-commit and pre-push there, arming them in every repo on the box
-- (macuahuitl-forge, 2026-09-27).
--
-- Branches:
--   1.  global hooksPath, no local one → refused (exit 3), global dir untouched
--   1b. the printed remedy, EXECUTED verbatim in a fresh clone, clears it
--   2.  local hooksPath set → installs into the LOCAL dir, global untouched
--   3.  no hooksPath anywhere → installs into .git/hooks
--
-- Every git and installer call gets a scratch HOME and GIT_CONFIG_NOSYSTEM=1,
-- so the fixture never reads or writes the real global config. The runner
-- scrubs GIT_CONFIG_GLOBAL and XDG_CONFIG_HOME, as the .sh unset them. The
-- printed remedy is a command STRING, so it runs from a helper FILE (the
-- runtime runs no shell strings).
--
-- Verdict: after `PASS: install-hooks refuses a global core.hooksPath
-- (1442-wyf9)`, ok:install-hooks-refuses-global-hookspath:4 |
-- `FAIL: <why>` then violation:install-hooks-refuses-global-hookspath:<branch>

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local relW = "target/plan-scratch/install-hooks-global-" .. tostring(time.now_ms())
local W = root .. "/" .. relW
local HOME = W .. "/home"
local GLOBAL_HOOKS = W .. "/global-hooks"
proc.run{ argv = { "mkdir", "-p", HOME, GLOBAL_HOOKS } }
local function cleanup() proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 } end
local function fail(msg, slug)
    log.raw("FAIL: " .. msg)
    cleanup()
    verdict.emit("violation:install-hooks-refuses-global-hookspath:" .. slug, 1)
end

local ENV = { HOME = HOME, GIT_CONFIG_NOSYSTEM = "1" }
local function run(argv, cwd)
    local r = proc.run{ argv = argv, cwd = cwd, env = ENV, stdin = "", timeout_ms = 120000 }
    return text.trim((r.stdout or "") .. (r.stderr or "")), r.code
end
local function git(args) local a = { "git" } for _, x in ipairs(args) do a[#a + 1] = x end return run(a) end
local function install(clone) return run({ "bash", clone .. "/scripts/install-hooks.sh" }) end
local function is_exec(p) return proc.run{ argv = { "test", "-x", p } }.ok end

fs.write(relW .. "/global-hooks/prepare-commit-msg", "#!/bin/sh\nexit 0\n")

-- A clone holding just what the installer reads.
local function make_clone(d)
    proc.run{ argv = { "mkdir", "-p", d .. "/scripts" } }
    proc.run{ argv = { "cp", "scripts/install-hooks.sh", d .. "/scripts/" } }
    proc.run{ argv = { "cp", "-R", "scripts/hooks", d .. "/scripts/" } }
    git({ "-C", d, "init", "-q", "." })
end
-- `ls -A | sort | tr '\n' ' '`: every name, sorted, each followed by a space.
local function snapshot()
    local names = text.lines(text.trim(proc.run{ argv = { "ls", "-A", GLOBAL_HOOKS } }.stdout or ""))
    table.sort(names)
    local s = ""
    for _, n in ipairs(names) do if n ~= "" then s = s .. n .. " " end end
    return s
end
local function has(s, p) return s:find(p, 1, true) ~= nil end

-- ── 1: global hooksPath only → refused, nothing written ─────────────────────
git({ "config", "--global", "core.hooksPath", GLOBAL_HOOKS })
local before = snapshot()
local C = W .. "/second-clone"; make_clone(C)
local o, rc = install(C)
if rc ~= 3 then fail("branch1: expected exit 3, got " .. tostring(rc) .. ": " .. o, "branch1-rc") end
if not has(o, "refused:install-hooks:global-hooks-path:") then fail("branch1: no refusal verdict: " .. o, "branch1-verdict") end
if not has(o, "config core.hooksPath") then fail("branch1: no affordance: " .. o, "branch1-affordance") end
if snapshot() ~= before then fail("branch1: global hooks dir changed: '" .. before .. "' -> '" .. snapshot() .. "'", "branch1-global") end
out.line("ok: branch1 global hooksPath refused, global dir untouched (" .. before .. ")")

-- ── 1b: THE PRINTED REMEDY CLEARS THE REFUSAL (1247-amcu criterion 5) ───────
local wi = o:find("why:", 1, true)
if not (wi and o:find("remedy:", wi, true)) then fail("branch1b: refusal carries no why:/remedy: lines: " .. o, "branch1b-lines") end
local C1 = W .. "/remedy-clone"; make_clone(C1)
o, rc = install(C1)
if rc ~= 3 then fail("branch1b: expected the refusal first, got " .. tostring(rc) .. ": " .. o, "branch1b-rc") end
local remedy = ""
for _, l in ipairs(text.lines(o)) do
    if remedy == "" and l:find("config core.hooksPath", 1, true) then remedy = (l:gsub("^ *", "")) end
end
if remedy == "" then fail("branch1b: no remedy command in: " .. o, "branch1b-none") end
fs.write(relW .. "/remedy.sh", remedy .. "\n")
if select(2, run({ "bash", W .. "/remedy.sh" })) ~= 0 then
    fail("branch1b: the printed remedy itself failed: " .. remedy, "branch1b-remedy")
end
o, rc = install(C1)
if rc ~= 0 then fail("branch1b: still refused after the printed remedy: " .. o, "branch1b-still") end
if not is_exec(C1 .. "/.git/hooks/pre-push") then fail("branch1b: remedy ran but the guards did not install locally", "branch1b-install") end
if snapshot() ~= before then fail("branch1b: global hooks dir changed", "branch1b-global") end
out.line("ok: branch1b the printed remedy, executed, clears the refusal")

-- ── 2: local hooksPath → installs locally, global untouched ─────────────────
git({ "-C", C, "config", "core.hooksPath", C .. "/.git/hooks" })
o, rc = install(C)
if rc ~= 0 then fail("branch2: installer failed: " .. o, "branch2-rc") end
if not (is_exec(C .. "/.git/hooks/pre-push") and is_exec(C .. "/.git/hooks/pre-commit")) then
    fail("branch2: guards not installed locally", "branch2-install")
end
if snapshot() ~= before then fail("branch2: global hooks dir changed", "branch2-global") end
out.line("ok: branch2 local hooksPath installs locally")

-- ── 3: no hooksPath anywhere → .git/hooks, as before ────────────────────────
git({ "config", "--global", "--unset", "core.hooksPath" })
local C3 = W .. "/plain-clone"; make_clone(C3)
o, rc = install(C3)
if rc ~= 0 then fail("branch3: installer failed: " .. o, "branch3-rc") end
if not is_exec(C3 .. "/.git/hooks/pre-push") then fail("branch3: guards not installed into .git/hooks", "branch3-install") end
out.line("ok: branch3 no hooksPath installs into .git/hooks")

cleanup()
out.line("PASS: install-hooks refuses a global core.hooksPath (1442-wyf9)")
verdict.ok("install-hooks-refuses-global-hookspath:4")
