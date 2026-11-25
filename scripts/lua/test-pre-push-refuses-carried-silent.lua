-- @trace order:2194-cspr, order:1577-g96z, order:2348-psb6
-- @env PATH HOME
--
-- test-pre-push-refuses-carried-silent.lua — a work/<order> push whose change is
-- carried-silent (it owes a carried obligation and neither pays an item nor carries a
-- Carried-Waiver) is REFUSED by the pre-push hook, not warned and pushed only to be
-- evicted by the land queue an hour later. Ported from the .sh of the same name
-- (2348-psb6); same five arms.
--
-- The hook's own carried-obligations block is cut out and run in a bash child against a
-- STUB plan binary (TILLANDSIAS_PLAN_BIN, which resolve_plan_binary honours first), so
-- each arm chooses exactly what the guard answers:
--   A REFUSED  `carried:<backlog>:due:<item>` -> exit 1, the refusal names it, and the
--              waiver line is printed as the remedy
--   B WAIVED   `carried:<backlog>:waived:<reason>` -> the block falls through
--   C NOT DUE  `carried:<backlog>:not-due` -> the block falls through
--   D OFF LANE WORK_REF_LANE != 1 -> the guard never runs, even on due
--   E MERGED   merge-then-push: the frozen base is the merge base with the merged trunk,
--              so trunk's own changes are never counted as this push's
-- PRE-FIX: arm A fails (the block called `refuse`, which only warns on the work lane).
--
-- GRAMMAR ok:pre-push-refuses-carried-silent:5 arms | violation:pre-push-refuses-carried-silent:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("pre-push-refuses-carried-silent")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local HOOK = fs.read("scripts/hooks/pre-push-local-gate.sh")

-- cut(start, nfi): from the line starting with `start` through the nfi-th `fi` at column 0.
local function cut(start, nfi)
    local out, on, n = {}, false, 0
    for l in (HOOK .. "\n"):gmatch("([^\n]*)\n") do
        if not on and l:sub(1, #start) == start then on = true end
        if on then
            out[#out + 1] = l
            if l == "fi" then n = n + 1; if n == nfi then break end end
        end
    end
    return table.concat(out, "\n") .. "\n"
end
local BLOCK = cut("# ORDER 1577-g96z — A WORK PUSH IS TOLD WHAT IT OWES", 1)
if not text.contains(BLOCK, "check-carried-obligations.lua") then
    T:refuse("block-not-extracted", "could not extract the hook's carried-obligations block: the fixture has drifted from the hook")
end

local W = T:scratch()
fs.mkdir(W.rel .. "/scripts/lua")
fs.write(W.rel .. "/scripts/lua/check-carried-obligations.lua", "")
fs.write(W.rel .. "/scripts/plan-binary-probe.sh", fs.read("scripts/plan-binary-probe.sh"))

-- stub(line): a plan binary that has `script` and prints that verdict line.
local function stub(line)
    fs.write(W.rel .. "/plan", '#!/usr/bin/env bash\ncase "$1" in\n  capabilities) echo script ;;\n'
        .. "  script) printf '%s\\n' '" .. line .. "'; printf '    candidate: scripts/x.sh\\nCarried-Waiver: shell-to-lua <reason>\\n' >&2 ;;\nesac\n")
    T:must{ "chmod", "+x", W.abs .. "/plan" }
end
-- block(lane): the extracted block in the scratch tree; output and rc.
local function block(lane)
    local r = T:run{ SH, "-s", cwd = W.abs, timeout_ms = 60000,
        env = { TILLANDSIAS_PLAN_BIN = W.abs .. "/plan", WORK_REF_LANE = lane, RED = "", RST = "" },
        stdin = 'refuse() { echo "WARNED-NOT-REFUSED: $1" >&2; return 0; }\n' .. BLOCK .. 'echo "fell-through"\n' }
    local o = (r.stdout or "") .. (r.stderr or "")
    return r.code, o, "rc=" .. tostring(r.code) .. " " .. o:gsub("\n", "|")
end

stub("carried:shell-to-lua:due:scripts/check-cheatsheet-tiers.sh (110 lines)")
local rc, o, why = block("1")
T:arm("A a carried-silent work push is REFUSED (exit 1) and the waiver line is shown",
    rc == 1 and text.contains(o, "pre-push refused: carried:shell-to-lua:due:") and text.contains(o, "Carried-Waiver: shell-to-lua")
        and not text.contains(o, "fell-through") and not text.contains(o, "WARNED-NOT-REFUSED"), why)

stub("carried:shell-to-lua:waived:blocked-by #1109")
rc, o, why = block("1")
T:arm("B a waived change passes", rc == 0 and text.contains(o, "fell-through") and not text.contains(o, "refused"), why)

stub("carried:shell-to-lua:not-due")
rc, o, why = block("1")
T:arm("C a change that owes nothing passes", rc == 0 and text.contains(o, "fell-through"), why)

stub("carried:shell-to-lua:due:scripts/x.sh (1 lines)")
rc, o, why = block("0")
T:arm("D outside the work lane the guard is not run at all", rc == 0 and text.contains(o, "fell-through") and not text.contains(o, "refused"), why)

-- E — MERGE-THEN-PUSH. A scratch remote, a work branch with its own commit, trunk moved
-- on and merged in; the hook's base-freezing block must pick the merged trunk.
local BASEBLOCK = cut("# ORDER 1592-idmu: freeze the diff-scoped guards", 2)
local G = W.abs .. "/merge"
fs.mkdir(W.rel .. "/merge")
local setup = T:run{ SH, "-s", cwd = G, timeout_ms = 60000, stdin = [[
gq() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=linux-next "$@"; }
gq init -q --bare remote.git && gq clone -q remote.git c 2>/dev/null && cd c &&
echo a > a && gq add a && gq commit -qm T0 && gq push -q origin HEAD:linux-next &&
gq switch -q -c work/x && echo own > own && gq add own && gq commit -qm own &&
gq switch -q --detach origin/linux-next && echo t1 > trunk && gq add trunk && gq commit -qm T1 &&
gq push -q origin HEAD:linux-next && T1="$(git rev-parse HEAD)" &&
gq switch -q work/x && gq merge -q --no-edit "$T1" &&
echo "T0=$(git rev-list --max-parents=0 HEAD)" && echo "T1=$T1" &&
echo "STALE=$(git rev-parse refs/remotes/origin/linux-next)"
]] }
local so = setup.stdout or ""
local T0, T1, STALE = so:match("T0=(%x+)"), so:match("T1=(%x+)"), so:match("STALE=(%x+)")
local got = T:run{ SH, "-s", "origin", cwd = G .. "/c", timeout_ms = 60000,
    env = { REPO_ROOT = G .. "/c" }, env_unset = { "TILLANDSIAS_GATE_DIFF_BASE", "TILLANDSIAS_GATE_DIFF_BASE_ROOT" },
    stdin = BASEBLOCK .. 'echo "BASE=${TILLANDSIAS_GATE_DIFF_BASE:-}"\n' }
local go = (got.stdout or "") .. (got.stderr or "")
local trunk_in_push = T1 and text.trim(T:run{ "git", "-C", G .. "/c", "diff", "--name-only", T1 .. "...HEAD", "--", "trunk" }.stdout or "x") or "x"
T:arm("E merge-then-push freezes the merged trunk as its base, so trunk's file is not this push's",
    T1 ~= nil and STALE == T1 and T0 ~= T1 and text.contains("\n" .. go, "\nBASE=" .. T1 .. "\n") and trunk_in_push == "",
    "premise stale=" .. tostring(STALE) .. " T0=" .. tostring(T0) .. " T1=" .. tostring(T1) .. "; got: " .. go:gsub("\n", "|"))

T:finish()
