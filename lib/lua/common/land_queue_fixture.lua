-- land_queue_fixture.lua — the scaffold the three land-queue fixtures share
-- (order 2398-zvug; ported from scripts/test-land-queue.sh).
--
-- THE SCAFFOLD IS THE PART NOBODY REVIEWS, so it is described here. Each arm
-- builds a real bare repository as the remote, a real clone as the lander, a
-- fake `gh` that answers `pr list` from a file the arm writes and records
-- `pr comment` to another, and a stub gate whose exit status the arm chooses.
-- Nothing touches the tillandsias repository: every path is under the
-- fixture's scratch dir, which T:finish removes.
--
-- WHY A REAL GIT REMOTE AND NOT A MOCK. The queue's central claim is about
-- ancestry on the remote — "the only proof that counts is asking the remote" —
-- and a mocked remote would let the fixture agree with the queue about a fact
-- neither had checked. The merges, the conflicts and the fast-forwards are real.
--
-- Usage:
--   local L = require("common.land_queue_fixture").new(T)
--   local S = L:scaffold("arm1"); L:candidate(S, "1001-aaaa", "a.txt", "A")
--   L:prs(S, { { 1, "work/1001-aaaa" } }); L:gate(S, "exit 0\n")
--   local out, rc = L:run_queue(S)

local fixture = require("common.fixture")
local M = {}
local L = {}
L.__index = L

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
M.q = q

function M.new(T)
    local self = setmetatable({ T = T, SH = fixture.posix_shell(), ROOT = fixture.repo_root() }, L)
    self.QUEUE = self.ROOT .. "/scripts/land-queue.sh"
    self.TMP = T:scratch("lq")
    return self
end

-- sh(script) -> stdout..stderr, rc. Every value in a script is q()-quoted by the caller.
function L:sh(script, opts)
    opts = opts or {}
    local r = proc.run({ argv = { self.SH, "-s" }, stdin = script .. "\n", env = opts.env, env_unset = opts.env_unset,
        timeout_ms = opts.timeout_ms or 600000 })
    return (r.stdout or "") .. (r.stderr or ""), r.code, r
end
-- must(script): a setup step; a failure refuses the whole fixture, naming the step.
function L:must(script)
    local o, c = self:sh(script)
    if c ~= 0 then self.T:refuse("setup-failed", script:sub(1, 200) .. " -> rc=" .. tostring(c) .. " " .. o:sub(1, 400)) end
    return o
end
function L:git(S, ...)
    local a = { "git", "-C", q(S.WORK) }
    for _, v in ipairs({ ... }) do a[#a + 1] = q(v) end
    return (self:sh(table.concat(a, " ")))
end
function L:rev(dir, ref)
    return text.trim((self:sh("git -C " .. q(dir) .. " rev-parse " .. q(ref) .. " 2>/dev/null")))
end
-- write(S, name, content[, exec]): a file under the arm's dir (or an absolute path inside the scratch).
function L:write(path_abs, content, exec)
    local rel = path_abs:gsub("^" .. self.TMP.abs:gsub("%p", "%%%0"), self.TMP.rel)
    fs.write(rel, content)
    if exec then self:must("chmod +x " .. q(path_abs)) end
end
function L:read(path_abs)
    local o = self:sh("cat " .. q(path_abs) .. " 2>/dev/null")
    return o
end

-- scaffold(name) — a bare remote with a trunk, plus a clone to land from.
function L:scaffold(name)
    local d = self.TMP.abs .. "/" .. name
    local S = { name = name, dir = d, REMOTE = d .. "/remote.git", WORK = d .. "/work", GH_PRS = d .. "/prs.json",
        GH_COMMENTS = d .. "/comments.log", GH_DRAFTS = d .. "/drafts.log", GATE_LOG = d .. "/gate.log",
        GH_BIN = d .. "/gh", GATE_BIN = d .. "/gate.sh" }
    fs.mkdir(self.TMP.rel .. "/" .. name)
    -- A bare repo initialised before this branch existed still has HEAD pointing
    -- at its init default, so `git clone` of it checks NOTHING out and every
    -- command in the clone fails on an unborn HEAD (the .sh's arm 5 lesson).
    self:must(table.concat({
        "set -e", "R=" .. q(S.REMOTE) .. "; W=" .. q(S.WORK),
        'git init -q --bare "$R"', 'git init -q "$W"',
        'git -C "$W" config user.email t@l; git -C "$W" config user.name t',
        'git -C "$W" config commit.gpgsign false',
        'echo base > "$W/base.txt"', 'git -C "$W" add -A && git -C "$W" commit -q -m base',
        'git -C "$W" branch -M linux-next', 'git -C "$W" remote add origin "$R"',
        'git -C "$W" push -q origin linux-next', 'git -C "$R" symbolic-ref HEAD refs/heads/linux-next',
        'git -C "$W" fetch -q origin',
        ": > " .. q(S.GH_COMMENTS) .. "; : > " .. q(S.GATE_LOG) .. "; : > " .. q(S.GH_DRAFTS) }, "\n"))
    self:fake_gh(S)
    return S
end

function L:fake_gh(S, prefix)
    self:write(S.GH_BIN, "#!/usr/bin/env bash\n" .. (prefix or "") ..
        "# Fake gh. Answers 'pr list' from a file and records 'pr comment' to a log.\n" ..
        'case "$1 $2" in\n' ..
        '    "pr list")    cat ' .. q(S.GH_PRS) .. ' ;;\n' ..
        '    "pr comment") shift 2; printf \'%s\\n\' "$*" >> ' .. q(S.GH_COMMENTS) .. ' ;;\n' ..
        '    # 1765-q7rg: the PR\'s comments as gh\'s JSON, carrying only the queue\'s own\n' ..
        '    # eviction markers for that PR (the part the queue reads back).\n' ..
        '    "pr view")\n' ..
        "        printf '{\"comments\":['\n" ..
        '        grep -o "<!-- land-queue:evicted pr=$3 [^>]*-->" ' .. q(S.GH_COMMENTS) .. ' \\\n' ..
        "            | sed 's/.*/{\"body\":\"&\"}/' | paste -sd, -\n" ..
        "        printf ']}\\n' ;;\n" ..
        '    "pr ready")   shift 2; printf \'%s\\n\' "$*" >> ' .. q(S.GH_DRAFTS) .. ' ;;\n' ..
        '    *) exit 1 ;;\n' ..
        'esac\n', true)
end

-- candidate(S, order, file, content) — a work ref on the remote.
function L:candidate(S, order, file, content, msg_extra)
    local dir = file:match("^(.*)/[^/]*$")
    self:must(table.concat({ "set -e", "W=" .. q(S.WORK),
        'git -C "$W" checkout -q -B ' .. q("work/" .. order) .. " origin/linux-next",
        dir and ('mkdir -p "$W"/' .. q(dir)) or ":",
        "printf '%s\\n' " .. q(content) .. ' > "$W"/' .. q(file),
        'git -C "$W" add -A',
        'git -C "$W" commit -q -m ' .. q("work(" .. order .. ")") .. (msg_extra and (" -m " .. q(msg_extra)) or ""),
        'git -C "$W" push -q origin ' .. q("work/" .. order),
        'git -C "$W" checkout -q linux-next' }, "\n"))
end

-- prs(S, { {number, head[, draft]} ... }) — what the fake gh lists. A string is written verbatim.
function L:prs(S, list)
    if type(list) == "string" then self:write(S.GH_PRS, list); return end
    local rows = {}
    for _, p in ipairs(list) do
        rows[#rows + 1] = string.format('{"number":%d,"headRefName":"%s","isDraft":%s}', p[1], p[2], p[3] and "true" or "false")
    end
    self:write(S.GH_PRS, "[" .. table.concat(rows, ",\n ") .. "]\n")
end

-- gate(S, body) — the stub gate. @NAME@ is replaced by S.NAME, q()-quoted.
function L:gate(S, body)
    body = body:gsub("@([%w_]+)@", function(k) return S[k] and q(S[k]) or ("@" .. k .. "@") end)
    self:write(S.GATE_BIN, "#!/usr/bin/env bash\n" .. body)
end

-- other(S, tag) — a second clone that moves the target from "another host".
function L:other(S, tag)
    local o = S.dir .. "/" .. (tag or "other")
    self:must("set -e\ngit clone -q " .. q(S.REMOTE) .. " " .. q(o) .. "\ngit -C " .. q(o) .. " config user.email o@o; git -C "
        .. q(o) .. " config user.name o\ngit -C " .. q(o) .. " config commit.gpgsign false")
    return o
end

-- run_queue(S, opts, args...) -> out, rc.
-- 2152-lqrf: the refresh key reads a dep-info and writes a stamp, by default
-- under the GATE's CARGO_TARGET_DIR, i.e. the real shared target. A fixture must
-- never read or write production state, so both are pinned to scratch unless an
-- arm names its own. 2174-dail: the land-queue KNOBS are pinned too (BATCH_K,
-- TRAIN_LOG, DAILY_*): a host that runs its queue with BATCH_K=4 exported reaches
-- this fixture through the gate, and every one-at-a-time arm then ran as a train.
-- Arms set opts.* instead. opts keys mirror the .sh's ARM_* / *_CMD names.
function L:run_queue(S, opts, ...)
    opts = opts or {}
    local T = self.TMP.abs
    local function o(k, d) local v = opts[k]; if v == nil then return d end return v end
    local kv = {
        { "TILLANDSIAS_LAND_QUEUE_SHADOW_INTAKE", o("SHADOW", "") },
        { "TILLANDSIAS_LAND_QUEUE_SHADOW_LOG", o("SHADOW_LOG", T .. "/shadow.log") },
        { "TILLANDSIAS_LAND_QUEUE_SHADOW_LOCK", o("SHADOW_LOCK", T .. "/shadow.lock") },
        { "TILLANDSIAS_LAND_QUEUE_SHADOW_TREE", o("SHADOW_TREE", T .. "/shadow.tree") },
        { "TILLANDSIAS_LAND_QUEUE_SHADOW_PR_S", o("SHADOW_PR_S", "60") },
        { "TILLANDSIAS_LAND_QUEUE_SHADOW_RUN_S", o("SHADOW_RUN_S", "60") },
        { "TILLANDSIAS_BUNDLE_HEAVY_MAX", o("HEAVY_MAX", "2") },
        { "TILLANDSIAS_LAND_QUEUE_GH", S.GH_BIN },
        { "TILLANDSIAS_LAND_QUEUE_GATE", "bash " .. S.GATE_BIN },
        { "TILLANDSIAS_LAND_QUEUE_PREFLIGHT", o("PREFLIGHT_CMD", "") },
        { "TILLANDSIAS_LAND_QUEUE_PLAN_REFRESH", o("PLAN_REFRESH_CMD", "") },
        { "TILLANDSIAS_LAND_QUEUE_BATCH_K", o("BATCH_K", "1") },
        { "TILLANDSIAS_LAND_QUEUE_TRAIN_LOG", o("TRAIN_LOG", T .. "/trains.log") },
        { "TILLANDSIAS_LAND_QUEUE_DAILY_SKIP", o("DAILY_SKIP", "1") },
        { "TILLANDSIAS_LAND_QUEUE_DAILY_MAX_AGE_S", o("DAILY_MAX_AGE_S", "86400") },
        -- 2432-ik2d: an empty queue cuts a stale proof by default; arms that are not about
        -- that must not see an extra gate run and an attest push (test-land-queue-daily-autocut.lua is).
        { "TILLANDSIAS_LAND_QUEUE_DAILY_AUTO", o("DAILY_AUTO", "0") },
        { "TILLANDSIAS_LAND_QUEUE_PLAN_DEPINFO", o("PLAN_DEPINFO", T .. "/no-plan-depinfo.d") },
        { "TILLANDSIAS_LAND_QUEUE_PLAN_REFRESH_STAMP", o("PLAN_REFRESH_STAMP", T .. "/plan-refresh-stamp") },
        { "TILLANDSIAS_LAND_QUEUE_HOST_DOOR", o("HOST_DOOR_CMD", "") },
        { "TILLANDSIAS_LAND_QUEUE_SIDECAR_STAGE", "" },
        { "TILLANDSIAS_LAND_QUEUE_PLAN_LANE_CHECK", o("PLAN_LANE_CMD", "echo plan-lane >> " .. S.GATE_LOG .. ".plan-lane") },
        { "TILLANDSIAS_LAND_QUEUE_REMOTE", "origin" },
        { "TILLANDSIAS_LAND_QUEUE_LOGDIR", o("LOGDIR", T .. "/logs") },
        { "TILLANDSIAS_TRUNK_BRANCH", "linux-next" },
    }
    if opts.HEAVY_PROBE == "" then opts.HEAVY_PROBE = nil end  -- the .sh: ${ARM_HEAVY_PROBE:+...}, empty is unset
    if opts.HEAVY_PROBE then kv[#kv + 1] = { "TILLANDSIAS_LAND_QUEUE_HEAVY_PROBE", opts.HEAVY_PROBE } end
    for k, v in pairs(opts.extra or {}) do kv[#kv + 1] = { k, v } end
    local parts = { "cd " .. q(S.WORK) .. " && env -u TILLANDSIAS_LAND_QUEUE_BUNDLE_LOG" }
    if not opts.HEAVY_PROBE then parts[#parts + 1] = "-u TILLANDSIAS_LAND_QUEUE_HEAVY_PROBE" end
    for _, p in ipairs(opts.unset or {}) do parts[#parts + 1] = "-u " .. p end
    for _, p in ipairs(kv) do parts[#parts + 1] = p[1] .. "=" .. q(p[2]) end
    parts[#parts + 1] = "bash " .. q(self.QUEUE)
    for _, a in ipairs({ ... }) do parts[#parts + 1] = q(a) end
    local cmd = table.concat(parts, " ") .. " 2>&1" .. (opts.stdin or " </dev/null")
    -- opts.wrap(cmd) -> a whole script, for the arms whose subject needs a process
    -- this runtime cannot hold: a live lock holder, a watcher running beside the queue.
    local script = opts.wrap and opts.wrap(cmd) or ((opts.prefix or "") .. cmd)
    local out, rc = self:sh(script, { env = opts.env, env_unset = opts.env_unset, timeout_ms = opts.timeout_ms })
    return out, rc
end

-- caps(out, pat): the first capture of pat on each line, in order.
function M.caps(out, pat)
    local r = {}
    for line in (out .. "\n"):gmatch("([^\n]*)\n") do
        local c = line:match(pat)
        if c then r[#r + 1] = c end
    end
    return r
end
-- joined(out, pat): caps joined the way `tr '\n' ','` joined them in the .sh ("1,2,3,").
function M.joined(out, pat)
    local r = M.caps(out, pat)
    return #r > 0 and (table.concat(r, ",") .. ",") or ""
end
function M.has(s, sub) return (s or ""):find(sub, 1, true) ~= nil end
-- line(out, pat): true when some line matches the Lua pattern pat.
function M.line(out, pat)
    for line in (out .. "\n"):gmatch("([^\n]*)\n") do if line:match(pat) then return true end end
    return false
end
function M.nlines(s) local n = 0; for l in (s or ""):gmatch("[^\n]+") do if l ~= "" then n = n + 1 end end return n end
function M.tail(s, n)
    local all = {}
    for l in (s or ""):gmatch("[^\n]*") do all[#all + 1] = l end
    local from = math.max(1, #all - n + 1)
    return table.concat(all, "\n", from)
end
-- skip(name, why): an arm that could not run says so and counts neither way.
function M.skip(name, why) out.line("skip: " .. name .. ": " .. why) end

return M
