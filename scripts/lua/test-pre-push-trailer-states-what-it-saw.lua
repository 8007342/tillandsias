-- @env PATH HOME
-- @trace order:1352-qbrd, order:2276-fnhy
--
-- test-pre-push-trailer-states-what-it-saw.lua — the pre-push hook's LAST line
-- never claims `./build.sh --check current for this tree` when the hook has
-- just seen otherwise. MEASURED PRE-FIX (macneo 2026-09-22, work/1302-7j8p):
--   line 5:    warn:pre-push:pre-push: the tree changed since ./build.sh --check last passed
--   last line: local gate: preflight clean, ./build.sh --check current for this tree
-- Ported from the .sh of the same name (order 2276-fnhy); same three arms.
--
--   A  THE OUTPUT, on a deliberately STALED tree (a partial scratch worktree of
--      HEAD: its stamp is necessarily stale:never-run, and the real checkout is
--      never touched): a work/<order> push exits 0, and the last line names the
--      warned deciders and the stamp verdict and does NOT claim a current gate
--   B  THE INSTRUMENT AGREES: the stamp verdict the trailer names is exactly
--      what `bash scripts/gate-stamp.sh verify` prints in that tree
--   C  CONTROL, on the trailer block itself: the green claim is printed when,
--      and only when, no decider warned AND the stamp is ok:gate-fresh; a
--      non-fresh stamp with no warnings is reported, not claimed
--
-- Usage: tillandsias-plan script run scripts/lua/test-pre-push-trailer-states-what-it-saw.lua
-- Verdict: ok:pre-push-trailer-states-what-it-saw:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("pre-push-trailer-states-what-it-saw")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local HOOK = "scripts/hooks/pre-push-local-gate.sh"
local CLAIM = "--check current for this tree"
local S = T:scratch()
local WT = S.abs .. "/wt"
local function has(s, x) return s:find(x, 1, true) ~= nil end

T:must{ "git", "-C", ROOT, "worktree", "add", "--no-checkout", "--detach", "-q", WT, "HEAD", timeout_ms = 120000 }
T:must{ "git", "-C", WT, "checkout", "-q", "HEAD", "--", "scripts", timeout_ms = 120000 }
for _, f in ipairs{ HOOK, "scripts/gate-stamp.sh" } do
    T:must{ "cp", ROOT .. "/" .. f, WT .. "/" .. f }
end

-- A
local sha = text.trim(T:must{ "git", "-C", WT, "rev-parse", "HEAD" }.stdout)
local p = proc.run{ argv = { SH, HOOK, "origin", "file:///nonexistent" }, cwd = WT, timeout_ms = 600000,
    stdin = "refs/heads/x " .. sha .. " refs/heads/work/1352-qbrd " .. ("0"):rep(40) .. "\n" }
local o = ((p.stdout or "") .. (p.stderr or "")):gsub("\27%[[0-9;]*m", "")
local last, warned = "", false
for _, src in ipairs{ p.stdout or "", p.stderr or "" } do
    for _, l in ipairs(text.lines((src:gsub("\27%[[0-9;]*m", "")))) do
        if l:sub(1, 14) == "warn:pre-push:" then warned = true end
        -- the hook prints its trailer on stderr, read second: the last non-blank line
        if text.trim(l) ~= "" then last = l end
    end
end
local stamp = proc.run{ argv = { SH, "scripts/gate-stamp.sh", "verify" }, cwd = WT, timeout_ms = 60000 }
local now = text.trim(stamp.stdout or "")
proc.run{ argv = { "git", "-C", ROOT, "worktree", "remove", "--force", WT }, timeout_ms = 60000 }

T:arm("A on a staled tree the last line reports the warnings and does not claim a current gate",
    p.code == 0 and warned and not has(last, CLAIM) and last:find("decider%(s%) warned .*NOT a clean gate") ~= nil,
    "rc=" .. tostring(p.code) .. " last=[" .. last .. "]\n" .. o)

-- B
T:arm("B the trailer names the stamp verdict gate-stamp.sh prints",
    now ~= "" and now:sub(1, 3) ~= "ok:" and has(last, "gate-stamp " .. now .. " "), "stamp=[" .. now .. "] last=[" .. last .. "]")

-- C: the trailer block alone, over its three inputs
local block, on = {}, false
for _, l in ipairs(text.lines(fs.read(HOOK))) do
    if not on and l:sub(1, 15) == "_trailer_stamp=" then on = true end
    if on then
        block[#block + 1] = l
        if l == "fi" then break end
    end
end
local function trailer(n, names, st)
    local r = proc.run{ argv = { SH, "-s", "--", n, names, st }, timeout_ms = 30000,
        stdin = "GRN= YLW= RST=; _PREPUSH_WARNED=$1; _PREPUSH_WARNED_NAMES=$2; stamp=$3\n" .. table.concat(block, "\n") .. "\n" }
    return (r.stdout or "") .. (r.stderr or "")
end
local c1, c2, c3 = trailer("0", "", "ok:gate-fresh"), trailer("0", "", "stale:tree-changed-since-gate"), trailer("2", "a,b", "ok:gate-fresh")
T:arm("C the green claim appears only for no warnings + ok:gate-fresh; a stale stamp or any warning is reported",
    #block > 0 and has(c1, CLAIM) and not has(c2, CLAIM) and has(c2, "stale:tree-changed-since-gate")
    and not has(c3, CLAIM) and has(c3, "2 decider(s) warned (a,b)"), "[" .. c1 .. "] [" .. c2 .. "] [" .. c3 .. "]")
T:finish()
