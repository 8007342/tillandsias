-- @trace order:2017-wtbr, spec:default-image
-- @env PATH
--
-- test-forge-subagent-worktree-starts-on-session-head.lua: a Claude sub-agent
-- worktree in a forge starts on the session's HEAD, not on the remote default.
--
-- THE DEFECT (2017-wtbr, kumbia forge). Claude Code's worktree.baseRef
-- defaults to "fresh": new worktrees (--worktree, isolation: worktree
-- sub-agents) branch from origin/HEAD. A forge clone's origin/HEAD names the
-- mirror's default branch (usually main), so sub-agents started on main while
-- the session worked on another branch. Proven on lenovinha 2026-11-07: from
-- a checkout at e97cd5a65 (work/2017-flwt) with origin/HEAD -> origin/main
-- (7ac4ceace), an isolation=worktree sub-agent reported HEAD 7ac4ceace.
-- The documented fix is worktree.baseRef = "head"; it changes nothing else.
--
--   1 EMPTY    a forge with no settings.json gets {"worktree":{"baseRef":"head"}}
--   2 MERGE    an existing settings.json (the PreToolUse hook) keeps its hooks
--              and gains worktree.baseRef = "head"
--   3 KEEP     an explicit worktree.baseRef already present is left as it is
--   4 GATED    off a forge (TILLANDSIAS_HOST_KIND unset) nothing is written
--   5 REFUSE   a settings.json that is not a JSON object is refused, unchanged
--   6 WIRED    entrypoint-forge-claude.sh runs the seed after the hook seed
--   7 PRE-FIX  at PRE_REV the forge's settings seeding leaves no baseRef, so
--              sub-agents take the "fresh" default (red before the fix)
--
-- Usage: tillandsias-plan script run scripts/lua/test-forge-subagent-worktree-starts-on-session-head.lua

local PRE_REV = "ce7aade37"
local LIB = "images/default/lib-common.sh"
local ENTRY = "images/default/entrypoint-forge-claude.sh"
local OVERLAY = "images/default/config-overlay/claude/settings.json"

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("forge-subagent-worktree-base", "git rev-parse --show-toplevel did not answer")
end
if proc.run({ argv = { "jq", "--version" }, timeout_ms = 10000 }).code ~= 0 then
    verdict.could_not_run("forge-subagent-worktree-base", "jq is not on PATH")
end

local REL = "target/plan-scratch/forge-worktree-base-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL
fs.mkdir(REL)

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. (got and ("  got: " .. got) or ""))
        failed[#failed + 1] = name
    end
end

-- Run one seed function, extracted from a lib-common.sh copy, against a
-- settings file. host_kind "" leaves TILLANDSIAS_HOST_KIND unset.
-- The driver is a script FILE (argv-only execution refuses shell strings).
fs.write(REL .. "/seed.sh", 'trace_lifecycle() { :; }\n'
    .. 'eval "$(sed -n "/^$2()/,/^}/p" "$1")"\n'
    .. '"$2"\n')
local DRIVER = W .. "/seed.sh"
local function seed(lib, fn, settings, host_kind, overlay_root)
    local e = { PATH = env.get("PATH"), HOME = W, CLAUDE_SETTINGS_FILE = settings }
    if host_kind ~= "" then e.TILLANDSIAS_HOST_KIND = host_kind end
    if overlay_root then e.TILLANDSIAS_CONFIG_OVERLAY_ROOT = overlay_root end
    local r = proc.run({ argv = { "bash", DRIVER, lib, fn }, env = e, timeout_ms = 30000 })
    if r.code == nil then
        proc.run({ argv = { "rm", "-rf", W }, timeout_ms = 30000 })
        verdict.could_not_run("forge-subagent-worktree-base", "the seed driver did not run: " .. tostring(r.status or r.decision))
    end
    return r
end

local function jq(file, filter)
    local r = proc.run({ argv = { "jq", "-r", filter, file }, timeout_ms = 10000 })
    return text.trim(r.stdout or "")
end

local LIBP = ROOT .. "/" .. LIB
local FN = "seed_claude_worktree_base_head"

-- 1 EMPTY
local s1 = W .. "/one/settings.json"
local r1 = seed(LIBP, FN, s1, "forge")
arm("1 EMPTY a forge with no settings.json gets worktree.baseRef=head",
    r1.code == 0 and fs.exists(REL .. "/one/settings.json") and jq(s1, ".worktree.baseRef") == "head",
    r1.code .. " " .. (r1.stderr or ""))

-- 2 MERGE
fs.mkdir(REL .. "/two")
fs.write(REL .. "/two/settings.json", fs.read(OVERLAY))
local s2 = W .. "/two/settings.json"
local r2 = seed(LIBP, FN, s2, "forge")
arm("2 MERGE the PreToolUse hook is kept and worktree.baseRef=head is added",
    r2.code == 0 and jq(s2, ".worktree.baseRef") == "head"
    and jq(s2, ".hooks.PreToolUse[0].hooks[0].command") == "/usr/local/lib/tillandsias/bash-policy-hook",
    r2.code .. " " .. jq(s2, "."))

-- 3 KEEP
fs.mkdir(REL .. "/three")
fs.write(REL .. "/three/settings.json", '{"worktree":{"baseRef":"fresh"}}\n')
local s3 = W .. "/three/settings.json"
local r3 = seed(LIBP, FN, s3, "forge")
arm("3 KEEP an explicit worktree.baseRef is left as it is",
    r3.code == 0 and jq(s3, ".worktree.baseRef") == "fresh", r3.code .. " " .. jq(s3, "."))

-- 4 GATED
local s4 = W .. "/four/settings.json"
local r4 = seed(LIBP, FN, s4, "")
arm("4 GATED off a forge nothing is written", r4.code == 0 and not fs.exists(REL .. "/four/settings.json"), r4.code)

-- 5 REFUSE
fs.mkdir(REL .. "/five")
fs.write(REL .. "/five/settings.json", '["not", "an", "object"]\n')
local r5 = seed(LIBP, FN, W .. "/five/settings.json", "forge")
arm("5 REFUSE a settings.json that is not an object is refused and unchanged",
    r5.code ~= 0 and fs.read(REL .. "/five/settings.json") == '["not", "an", "object"]\n', r5.code)

-- 6 WIRED: a code line runs the seed, after the hook seed.
local hook_at, base_at = nil, nil
for i, l in ipairs(text.lines(fs.read(ENTRY))) do
    if not l:match("^%s*#") then
        if not hook_at and l:find("seed_claude_pretooluse_hook", 1, true) then hook_at = i end
        if not base_at and l:find(FN, 1, true) then base_at = i end
    end
end
arm("6 WIRED entrypoint-forge-claude.sh runs the seed after the hook seed",
    hook_at ~= nil and base_at ~= nil and base_at > hook_at, tostring(hook_at) .. " " .. tostring(base_at))

-- 7 PRE-FIX: the forge's settings seeding at PRE_REV, on an empty HOME.
local pre_lib = proc.run({ argv = { "git", "show", PRE_REV .. ":" .. LIB }, cwd = ROOT, timeout_ms = 30000 })
local pre_ov = proc.run({ argv = { "git", "show", PRE_REV .. ":" .. OVERLAY }, cwd = ROOT, timeout_ms = 30000 })
if pre_lib.code ~= 0 or pre_ov.code ~= 0 then
    proc.run({ argv = { "rm", "-rf", W }, timeout_ms = 30000 })
    verdict.could_not_run("forge-subagent-worktree-base", "git show " .. PRE_REV .. " did not answer")
end
fs.mkdir(REL .. "/pre/overlay/claude")
fs.write(REL .. "/pre/lib-common.sh", pre_lib.stdout)
fs.write(REL .. "/pre/overlay/claude/settings.json", pre_ov.stdout)
local s7 = W .. "/pre/settings.json"
local r7 = seed(W .. "/pre/lib-common.sh", "seed_claude_pretooluse_hook", s7, "forge", W .. "/pre/overlay")
local pre_has_fn = pre_lib.stdout:find("\n" .. FN .. "()", 1, true) ~= nil
arm("7 PRE-FIX at " .. PRE_REV .. " the seeded settings carry no worktree.baseRef (the fresh default)",
    r7.code == 0 and fs.exists(REL .. "/pre/settings.json") and jq(s7, ".worktree.baseRef // \"absent\"") == "absent"
    and not pre_has_fn,
    r7.code .. " " .. tostring(pre_has_fn))

proc.run({ argv = { "rm", "-rf", W }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("refused:forge-subagent-worktree-base:" .. #failed .. "-of-7", 1)
end
verdict.emit("ok:forge-subagent-worktree-base:7", 0)
