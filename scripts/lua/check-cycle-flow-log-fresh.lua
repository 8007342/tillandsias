-- @env PWD
-- @env TILLANDSIAS_CYCLE_FLOW_LOG
-- @trace order:943-7dn5, order:2167-cbyw
--
-- check-cycle-flow-log-fresh.lua — the cycle-flow log must be FRESH, not merely
-- well-formed. (Ported from scripts/check-cycle-flow-log-fresh.sh, the
-- shell-to-lua item carried by order 2167-cbyw; the full rationale — the
-- emitter-without-a-call substitution, why the horizon is ACTIVITY and not a
-- clock, why there is a grace window, why this is litmus-bound and NOT wired
-- into ./build.sh --check — is told in
-- `git log -p -- scripts/check-cycle-flow-log-fresh.sh`.)
--
-- THE RULE: commits settled past the grace window (default 2 h) and newer than
-- the newest record's "ts" are cycles that ran without emitting. No settled
-- commits at all means no cycle owes a record: a NAMED SKIP, never a violation
-- (1024-c3h3). Date comparison is handed to git (--since/--until), never done
-- here, for the same dialect reason the .sh gave (761-g36m).
--
-- ONE CHANGE FROM THE .sh, AND IT IS A FIX. The .sh began with
-- `cd "$(dirname "$0")/.."`, so git always judged the checkout the SCRIPT lived
-- in, never the caller's: the litmus arm "no settled commits means a named
-- SKIP" ran it from an empty scratch repo and got
-- violation:cycle-flow-log-stale:absent:commits_since=21346 (this checkout's
-- history). git now runs in the caller's PWD (2166-zvst's rule for deciders).
--
-- Grammar (one line on stdout):
--   ok:cycle-flow-log-fresh:newest=<iso> commits_since=0
--   violation:cycle-flow-log-stale:<absent|newest=<iso>|no-parsable-ts>:commits_since=<n>
--   skip:cycle-flow-log-fresh:<reason>
--
-- Usage: tillandsias-plan script run scripts/lua/check-cycle-flow-log-fresh.lua
--          [-- --grace-hours N] [--log PATH]

local function caller_dir()
    local d = env.get("PWD")
    if d ~= nil and d ~= "" and (d:sub(1, 1) == "/" or d:match("^%a:[/\\]")) then return d end
    return nil
end
local CALLER = caller_dir()
local function run(argv)
    return proc.run({ argv = argv, cwd = CALLER, timeout_ms = 60000 })
end
local function ok(r) return r.status == "exited" and r.code == 0 end
local function count_lines(s)
    local n = 0
    for _ in (s or ""):gmatch("[^\n]+") do n = n + 1 end
    return n
end

local USAGE = "usage: check-cycle-flow-log-fresh.lua [--grace-hours N] [--log PATH]"
local GRACE_H, LOG = "2", nil
local i = 1
while arg[i] ~= nil do
    local a = arg[i]
    if a == "--grace-hours" then GRACE_H = arg[i + 1] or ""; i = i + 2
    elseif a == "--log" then LOG = arg[i + 1] or ""; i = i + 2
    else verdict.emit("blocked:cycle-flow-log-fresh:usage", 2, USAGE) end
end
if not GRACE_H:match("^%d+$") then
    verdict.emit("blocked:cycle-flow-log-fresh:bad-grace-hours", 2,
        "error: --grace-hours needs a non-negative integer")
end

-- The default log path: metrics-log-path.sh's metrics_default_log resolves a
-- checkout root to <root>/.cache/metrics/<base> (1268-m2ir; a worktree's .git
-- is a file and still counts). The runner refuses a bash child, so the rule is
-- restated here for the one case a READER needs: the caller's checkout, found
-- by git itself (which already accepts worktrees). Its /tmp fallback is a
-- WRITER's escape hatch — a checkout git cannot name has no settled commits to
-- owe a record for, so this skips by name instead.
if LOG == nil then
    LOG = env.get("TILLANDSIAS_CYCLE_FLOW_LOG")
    if LOG == nil or LOG == "" then
        local top = run({ "git", "rev-parse", "--show-toplevel" })
        local root = ok(top) and (top.stdout or ""):gsub("%s+$", "") or ""
        LOG = root ~= "" and (root .. "/.cache/metrics/tillandsias-cycle-flow.jsonl") or ""
    end
end
if LOG == "" then
    verdict.emit("skip:cycle-flow-log-fresh:cannot-resolve-log-path", 0)
end

local GRACE = GRACE_H .. " hours ago"

-- EVIDENCE THE HOST RUNS CYCLES AT ALL. If git cannot answer, skip, not accuse.
local settled = run({ "git", "log", "--until=" .. GRACE, "--oneline", "-1" })
if settled.status ~= "exited" then
    verdict.emit("skip:cycle-flow-log-fresh:git-log-unavailable", 0)
end
if count_lines(settled.stdout) == 0 then
    verdict.emit("skip:cycle-flow-log-fresh:no-settled-commits-so-no-cycle-owes-a-record", 0)
end

-- The log may lie outside the repository (the litmus passes a mktemp file), so
-- it is read through a child, not fs.* (confined to the runner's root).
local content = ""
if ok(run({ "test", "-s", LOG })) then
    local c = run({ "cat", LOG })
    content = c.stdout or ""
end

if content == "" then
    local all = run({ "git", "log", "--until=" .. GRACE, "--oneline" })
    local n = count_lines(all.stdout)
    verdict.emit("violation:cycle-flow-log-stale:absent:commits_since=" .. n, 1, table.concat({
        "  " .. n .. " settled commit(s) and NO flow record at all:",
        "    " .. LOG,
        "  Cycles ran and none emitted. overhead_ratio cannot be computed",
        "  from an empty log, and a metric that is structurally absent is a",
        "  RED gate, never a pass (943-7dn5, 689-zwzm G1).",
        "  Fix: emit once per cycle — skills/advance-work-from-plan 7.0b.",
    }, "\n"))
end

-- Newest ts: the MAXIMUM, not the last line (an interrupted-and-resumed cycle
-- appends out of order). ISO-8601 UTC sorts lexicographically.
local newest = nil
for ts in content:gmatch('"ts"%s*:%s*"([^"]*)"') do
    if newest == nil or ts > newest then newest = ts end
end
if newest == nil or newest == "" then
    verdict.emit("violation:cycle-flow-log-stale:no-parsable-ts:commits_since=-", 1,
        "  " .. LOG .. ' has content but no record carries a "ts" field.')
end

local s = run({ "git", "log", "--since=" .. newest, "--until=" .. GRACE, "--oneline" })
local since = ok(s) and count_lines(s.stdout) or 0

if since > 0 then
    verdict.emit("violation:cycle-flow-log-stale:newest=" .. newest .. ":commits_since=" .. since, 1,
        table.concat({
            "  " .. since .. " settled commit(s) landed AFTER the newest flow record:",
            "    " .. LOG,
            "    newest record: " .. newest,
            "  Cycles have run since and none appended a record. This is the",
            "  substitution shape 943-7dn5 names: the emitter works, its fixture",
            "  proves it, the call is missing, and every row already in the log",
            "  is perfectly well-formed — so a shape check stays green over it.",
        }, "\n"))
end

verdict.emit("ok:cycle-flow-log-fresh:newest=" .. newest .. " commits_since=0", 0)
