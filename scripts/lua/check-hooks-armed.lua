-- @trace order:1255-s4im
-- @env PWD TILLANDSIAS_HOOKS_CHECK_ROOT
--
-- check-hooks-armed.lua — the READ-ONLY verdict on this checkout's push
-- guards, for the Start Of Day gate and the Start Of Cycle guards (1255-s4im
-- criterion 2). Same decisions as scripts/ensure-hooks.sh, which it never
-- runs: it installs nothing, writes nothing and changes no config. A host
-- reads whether its pre-push guards (the release freeze, the local gate, the
-- linux-next merge gate) are armed BEFORE it pushes, rather than learning it
-- from a push that went through.
--
-- WHY READ-ONLY. ensure-hooks.sh --prelude already ARMS the guards from the
-- four plan-lane scripts (push-plan-fragments-to-trunk, claim-ledger-node,
-- salvage-dirty-worktree, drain-queue). A host whose first push is a WORK REF
-- never runs any of them, so it pushes unguarded; this check names that state
-- at the start of the day or cycle, and the remedy is one command.
--
-- Verdict (stdout, one line; why and remedy on stderr otherwise):
--   ok:hooks-armed:<marker>                       exit 0
--   degraded:hooks:absent                         exit 1  (no pre-push)
--   degraded:hooks:stale:<have>-><want>           exit 1  (ours, older)
--   refused:hooks:foreign-pre-push:<path>         exit 3  (not ours)
--   refused:hooks:<scope>-hooks-path:<dir>        exit 3  (global/system)
--   blocked:hooks:not-a-checkout                  exit 2
--   blocked:hooks:no-marker-in-installer          exit 2
--
-- TILLANDSIAS_HOOKS_CHECK_ROOT is a TEST SEAM: the checkout to judge (default:
-- the caller's directory). Every read goes through proc.run (git, sed, grep),
-- because the hooks dir can lie outside the repository (core.hooksPath).

local root = env.get("TILLANDSIAS_HOOKS_CHECK_ROOT")
if root == nil or root == "" then root = env.get("PWD") end
-- Neither named (a caller that passes no PWD): no cwd, which is the runner's
-- repository root. proc.run refuses a relative cwd.
if root == "" then root = nil end

local function run(argv)
    local r = proc.run({ argv = argv, cwd = root, timeout_ms = 30000 })
    return r.status == "exited" and r.code or -1, text.trim(r.stdout or "")
end
local function afford(why, remedy)
    io.stderr:write("  why: " .. why .. "\n  remedy: " .. remedy .. "\n")
end

local rc, top = run({ "git", "rev-parse", "--show-toplevel" })
if rc ~= 0 or top == "" then
    afford(tostring(root or "the repository root") .. " is not a git checkout", "run this from the project checkout")
    verdict.emit("blocked:hooks:not-a-checkout", 2)
end
local _, hooks_dir = run({ "git", "rev-parse", "--path-format=absolute", "--git-path", "hooks" })

-- The current marker is the installer's, read from it so the two cannot drift
-- (the same sed ensure-hooks.sh uses).
local _, want = run({ "sed", "-n",
    's/^PREPUSH_MARKER="# \\(tillandsias-pre-push-v[0-9][0-9]*\\)"$/\\1/p',
    top .. "/scripts/install-hooks.sh" })
if want == "" then
    afford("scripts/install-hooks.sh names no PREPUSH_MARKER, so the current hook version is unknowable",
        "restore scripts/install-hooks.sh from the trunk")
    verdict.emit("blocked:hooks:no-marker-in-installer", 2)
end

local _, scope_line = run({ "git", "config", "--show-scope", "--get", "core.hooksPath" })
local scope = scope_line:match("^(%S+)") or ""
if scope ~= "" and scope ~= "local" and scope ~= "worktree" then
    afford("core.hooksPath comes from " .. scope .. " config, so these guards would be armed in every repository on this machine (1442-wyf9)",
        "give this clone its own hooks dir (see scripts/ensure-hooks.sh), then run bash scripts/ensure-hooks.sh")
    verdict.emit("refused:hooks:" .. scope .. "-hooks-path:" .. hooks_dir, 3)
end

local hook = hooks_dir .. "/pre-push"
local exists = run({ "test", "-f", hook }) == 0
if not exists then
    afford("this checkout has no pre-push hook, so a push here runs none of the push guards (the release freeze among them)",
        "bash scripts/ensure-hooks.sh")
    verdict.emit("degraded:hooks:absent", 1)
end
local _, have = run({ "grep", "-oE", "-m", "1", "tillandsias-pre-push-v[0-9]+", hook })
have = (have:match("^(%S+)") or "")
if have == "" and run({ "grep", "-qF", "# version-guard-hook", hook }) == 0 then
    have = "version-guard-hook"
end
if have == "" then
    afford("a pre-push hook this project did not write is installed; the push guards are not in it",
        "inspect " .. hook .. "; if it is not needed, move it aside and run bash scripts/ensure-hooks.sh")
    verdict.emit("refused:hooks:foreign-pre-push:" .. hook, 3)
end
if have ~= want then
    afford("the installed pre-push is " .. have .. " and the current one is " .. want .. ", so newer guards are not armed",
        "bash scripts/ensure-hooks.sh")
    verdict.emit("degraded:hooks:stale:" .. have .. "->" .. want, 1)
end
verdict.emit("ok:hooks-armed:" .. want, 0)
