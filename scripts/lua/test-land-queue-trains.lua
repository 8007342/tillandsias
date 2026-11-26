-- @trace order:1316-bnzt, order:2152-lqrf, order:2153-trn1, order:2174-dail, order:2398-zvug, spec:ci-release
-- @env PATH HOME TMPDIR
--
-- test-land-queue-trains.lua — scripts/land-queue.sh, arms 40-63 of the former
-- scripts/test-land-queue.sh (split by arm group, 2398-zvug): the plan-refresh
-- key, batch trains, the daily-full proof and the real class selector and
-- pre-push hook, a held lock said aloud, trains over a moving trunk, --status,
-- bundles.log, the heavy cap, shadow intake, red-train diagnosis and build.sh's
-- red-script line. Scaffold: lib/lua/common/land_queue_fixture.lua.
--
-- Arms whose subject is a process (a live lock holder, a watcher beside the
-- queue, a stop mid-build) keep that part as a shell block through
-- run_queue's wrap: stock Lua cannot hold a background process (the Rust-phase
-- census, plan/issues/rust-phase-census-2026-11-26.md).
--
-- Usage: tillandsias-plan script run scripts/lua/test-land-queue-trains.lua
-- Verdict: ok:land-queue-trains:<n> arms | violation:land-queue-trains:<n>-failed

local fixture = require "common.fixture"
local LQ = require "common.land_queue_fixture"
local T = fixture.new("land-queue-trains")
for _, t in ipairs({ "git", "jq" }) do
    if not fixture.which(t) then T:skip("no-" .. t .. " — every arm drives the queue with it") end
end
if not fs.exists("scripts/land-queue.sh") then T:skip("no-queue-script") end
local L = LQ.new(T)
local q, has, line, caps = LQ.q, LQ.has, LQ.line, LQ.caps
local function arm(name, cond, got) T:arm(name, cond, got) end
local function gates(S) return LQ.nlines(L:read(S.GATE_LOG)) end
local function prs_n(S, list) local t = {}; for _, p in ipairs(list) do t[#t + 1] = { p[1], p[2] } end; L:prs(S, t) end
local TMP = L.TMP.abs
local GATED = "echo gated >> @GATE_LOG@\nexit 0\n"
local function landed(o, pat) local n = 0; for l in o:gmatch("[^\n]+") do if l:match(pat) then n = n + 1 end end return n end
local function now() return tonumber(text.trim((L:sh("date -u +%s")))) end

-- ──────────────────────────────────────────────────────────── ARM 40
-- ORDER 2152-lqrf: THE PLAN-BINARY REFRESH IS SKIPPED WHEN ITS INPUTS ARE
-- UNCHANGED. #40/#41 leave base.txt alone: ONE refresh, #41 prints the skip;
-- #42 edits it: the refresh runs again. Premise: the dep-info names base.txt.
local S = L:scaffold("arm40")
L:candidate(S, "1040-aaaa", "a40.txt", "A")
L:candidate(S, "1041-bbbb", "b40.txt", "B")
L:candidate(S, "1042-cccc", "base.txt", "changed")
prs_n(S, { { 40, "work/1040-aaaa" }, { 41, "work/1041-bbbb" }, { 42, "work/1042-cccc" } })
L:gate(S, GATED)
local D40 = S.dir .. "/tgt"
L:must("mkdir -p " .. q(D40) .. "; : > " .. q(S.dir .. "/refresh.count"))
L:write(S.dir .. "/refresh.sh", "#!/usr/bin/env bash\necho run >> " .. q(S.dir .. "/refresh.count") .. "\nprintf '%s: %s\\n' "
    .. q(D40 .. "/plan") .. " " .. q(S.WORK .. "/base.txt") .. " > " .. q(D40 .. "/plan.d") .. "\necho built >> " .. q(D40 .. "/plan") .. "\n")
local out, rc = L:run_queue(S, { PLAN_DEPINFO = D40 .. "/plan.d", PLAN_REFRESH_STAMP = D40 .. "/stamp",
    PLAN_REFRESH_CMD = "bash '" .. S.dir .. "/refresh.sh'" })
local n40 = LQ.nlines(L:read(S.dir .. "/refresh.count"))
if not has(L:read(D40 .. "/plan.d"), "base.txt") then
    arm("ARM 40 premise: the refresh stub wrote a dep-info naming base.txt", false, out)
else
    arm("ARM 40: the plan refresh runs once for two candidates that leave its inputs alone, and again for one that edits an input (2152-lqrf)",
        line(out, "^plan%-refresh:skipped:inputs%-unchanged:#41:") and not line(out, "^plan%-refresh:skipped:inputs%-unchanged:#42:")
        and n40 == 2 and rc == 0 and landed(out, "^land:") == 3, "refreshes=" .. n40 .. " rc=" .. tostring(rc) .. " " .. out)
end
-- ARM 40b, NEGATIVE CONTROL: no dep-info means no key, so EVERY candidate refreshes.
S = L:scaffold("arm40b")
L:candidate(S, "1043-dddd", "d40.txt", "D")
L:candidate(S, "1044-eeee", "e40.txt", "E")
prs_n(S, { { 43, "work/1043-dddd" }, { 44, "work/1044-eeee" } })
L:gate(S, "exit 0\n")
L:write(S.dir .. "/refresh.count", "")
out = L:run_queue(S, { PLAN_DEPINFO = S.dir .. "/none.d", PLAN_REFRESH_STAMP = S.dir .. "/stamp",
    PLAN_REFRESH_CMD = "echo run >> '" .. S.dir .. "/refresh.count'" })
arm("ARM 40b (control): with no dep-info every candidate refreshes",
    LQ.nlines(L:read(S.dir .. "/refresh.count")) == 2 and not line(out, "^plan%-refresh:skipped"), out)

-- ──────────────────────────────────────────────────────────── ARM 41
-- ORDER 2153-trn1: A BATCH TRAIN GATES THE UNION ONCE AND LANDS ONE COMMIT
-- whose parents are the old trunk plus the three heads.
S = L:scaffold("arm41")
L:candidate(S, "1051-aaaa", "a41.txt", "A")
L:candidate(S, "1052-bbbb", "b41.txt", "B")
L:candidate(S, "1053-cccc", "c41.txt", "C")
prs_n(S, { { 51, "work/1051-aaaa" }, { 52, "work/1052-bbbb" }, { 53, "work/1053-cccc" } })
L:gate(S, GATED)
local base = L:rev(S.REMOTE, "linux-next")
local heads = text.trim((L:sh("git -C " .. q(S.REMOTE) .. " for-each-ref --format='%(objectname)' 'refs/heads/work/*' | sort -u | grep -c .")))
if heads ~= "3" then
    arm("ARM 41 premise: three distinct work heads were pushed", false, heads)
else
    -- HEAVY_MAX=4: the scratch tree's empty fixture population probes every member heavy.
    out, rc = L:run_queue(S, { BATCH_K = "4", HEAVY_MAX = "4", TRAIN_LOG = S.dir .. "/trains.log" })
    local h = L:rev(S.REMOTE, "linux-next")
    local words = #caps(text.trim((L:sh("git -C " .. q(S.REMOTE) .. " rev-list --parents -n 1 " .. h))):gsub(" ", "\n") .. "\n", "^(%x+)$")
    local fp = text.trim((L:sh("git -C " .. q(S.REMOTE) .. " rev-list --first-parent --count " .. base .. ".." .. h)))
    local files = landed(L:sh("git -C " .. q(S.REMOTE) .. " ls-tree --name-only " .. h), "^[abc]41%.txt$")
    arm("ARM 41: a train of 3 gates the union ONCE and lands ONE first-parent commit with 4 parents carrying all three trees (2153-trn1)",
        rc == 0 and gates(S) == 1 and words == 5 and fp == "1" and files == 3 and landed(out, "^land:5[123] .*train=") == 3
        and has(L:read(S.dir .. "/trains.log"), "result=landed:"),
        "rc=" .. tostring(rc) .. " gates=" .. gates(S) .. " words=" .. words .. " fp=" .. fp .. " files=" .. files .. " " .. out)
end
-- ARM 41b: a RED train evicts nobody; the members go one at a time and land.
S = L:scaffold("arm41b")
L:candidate(S, "1054-dddd", "d41.txt", "D")
L:candidate(S, "1055-eeee", "e41.txt", "E")
prs_n(S, { { 54, "work/1054-dddd" }, { 55, "work/1055-eeee" } })
local m41 = S.dir .. "/red-once"
L:gate(S, "echo gated >> @GATE_LOG@\nif [ ! -e " .. q(m41) .. " ]; then : > " .. q(m41) .. "; echo \"FAIL: scripts/test-flaky-train.sh\"; exit 1; fi\nexit 0\n")
out = L:run_queue(S, { BATCH_K = "4", TRAIN_LOG = S.dir .. "/trains.log" })
arm("ARM 41b: a red train evicts nobody; its members land one at a time (1 train gate + 2 member gates)",
    line(out, "^train:red:") and not line(out, "^evict") and landed(out, "^land:5[45] ") == 2 and landed(out, "^land:.*train=") == 0
    and gates(S) == 3 and has(L:read(S.dir .. "/trains.log"), "result=red:"), "gates=" .. gates(S) .. " " .. out)
-- ARM 41c, NEGATIVE CONTROL: K unset (the default) runs no train at all.
S = L:scaffold("arm41c")
L:candidate(S, "1056-ffff", "f41.txt", "F")
L:candidate(S, "1057-gggg", "g41.txt", "G")
prs_n(S, { { 56, "work/1056-ffff" }, { 57, "work/1057-gggg" } })
L:gate(S, GATED)
out = L:run_queue(S)
arm("ARM 41c (control): with BATCH_K unset there is no train; one gate per candidate",
    not line(out, "^train") and gates(S) == 2 and landed(out, "^land:5[67] ") == 2, "gates=" .. gates(S) .. " " .. out)

-- ──────────────────────────────────────────────────────────── ARM 50
-- ORDER 2174-dail: small gates piggyback on a daily run. The gate stub records
-- the selector env the queue hands it, and plays a class selector that skipped
-- one step when (and only when) a proof is given.
local function dail_gate(S0)
    L:gate(S0, "echo gated >> @GATE_LOG@\nprintf 'base=%s marker=%s\\n' \"${TILLANDSIAS_CLASS_BASE:-none}\" "
        .. "\"$(cat \"${TILLANDSIAS_FULL_GATE_MARKER:-/nonexistent}\" 2>/dev/null || echo absent)\" >> " .. q(S0.GATE_LOG .. ".env") .. "\n"
        .. "[ -n \"${TILLANDSIAS_CLASS_BASE:-}\" ] && echo \"skip:class-selector:gate-step:999-zzzz — declared-inputs=path:x.txt\"\nexit 0\n")
end
local function upd(S0, ref, sha) L:must("git -C " .. q(S0.REMOTE) .. " update-ref " .. q(ref) .. " " .. q(sha)) end
-- 50a FRESH GREEN PROOF: the gate gets the proved commit and its epoch.
S = L:scaffold("arm50a")
L:candidate(S, "1060-aaaa", "a50.txt", "A")
prs_n(S, { { 60, "work/1060-aaaa" } })
dail_gate(S)
local p50, e50 = L:rev(S.REMOTE, "linux-next"), now()
upd(S, "refs/attest/daily-full/" .. e50, p50)
out = L:run_queue(S)
local envl = L:read(S.GATE_LOG .. ".env")
arm("ARM 50a: a fresh green daily proof reaches the gate (class base + epoch) and the land names the skipped step (2174-dail)",
    line(envl, "^base=" .. p50 .. " marker=" .. e50 .. "$") and line(out, "^land:60 ") and out:find("not%-run: gate%-step:999%-zzzz .*daily proof") ~= nil,
    "env=" .. envl .. " " .. out)
-- 50b STALE PROOF (> 24 h): no class base, no marker; the land runs full.
S = L:scaffold("arm50b")
L:candidate(S, "1061-bbbb", "b50.txt", "B")
prs_n(S, { { 61, "work/1061-bbbb" } })
dail_gate(S)
upd(S, "refs/attest/daily-full/" .. (now() - 90000), L:rev(S.REMOTE, "linux-next"))
out = L:run_queue(S)
envl = L:read(S.GATE_LOG .. ".env")
arm("ARM 50b: a daily proof older than 24 h freezes the land back to full (no class base, no marker)",
    line(envl, "^base=none marker=absent$") and out:find("not%-run: nothing .*daily%-run%-stale") ~= nil, "env=" .. envl .. " " .. out)
-- 50c RED NEWER THAN GREEN: full, naming the red.
S = L:scaffold("arm50c")
L:candidate(S, "1062-cccc", "c50.txt", "C")
prs_n(S, { { 62, "work/1062-cccc" } })
dail_gate(S)
local t50, e50c = L:rev(S.REMOTE, "linux-next"), now()
upd(S, "refs/attest/daily-full/" .. (e50c - 60), t50)
upd(S, "refs/attest/daily-red/" .. e50c, t50)
out = L:run_queue(S)
envl = L:read(S.GATE_LOG .. ".env")
arm("ARM 50c: a red daily run newer than the last green freezes lands back to full",
    line(envl, "^base=none marker=absent$") and out:find("not%-run: nothing .*daily%-run%-red") ~= nil, "env=" .. envl .. " " .. out)
-- 50d --daily-full publishes the proof: green -> daily-full ref, red -> daily-red.
S = L:scaffold("arm50d")
L:prs(S, "[]\n")
L:gate(S, 'echo "${TILLANDSIAS_CLASS_SELECTOR:-on}" >> @GATE_LOG@\nexit 0\n')
local od, rd = L:run_queue(S, nil, "--daily-full")
local tip = L:rev(S.REMOTE, "linux-next")
local green = text.trim((L:sh("git -C " .. q(S.REMOTE) .. " for-each-ref --format='%(objectname)' refs/attest/daily-full/")))
L:gate(S, "exit 1\n")
local oe, re = L:run_queue(S, nil, "--daily-full")
local red = text.trim((L:sh("git -C " .. q(S.REMOTE) .. " for-each-ref --format='%(objectname)' refs/attest/daily-red/")))
arm("ARM 50d: --daily-full gates the trunk tip with the selector OFF and publishes daily-full (green) or daily-red (red)",
    rd == 0 and green == tip and line(L:read(S.GATE_LOG), "^off$") and re == 1 and red == tip
    and line(od, "^ok:land%-queue:daily%-full:") and line(oe, "^red:land%-queue:daily%-full:"),
    "rc=" .. tostring(rd) .. "/" .. tostring(re) .. " green='" .. green .. "' red='" .. red .. "' tip=" .. tip .. " " .. od .. oe)

-- ARM 52 (coordinator 2026-11-22): A GATE NEVER SEES THE QUEUE'S KNOBS, even
-- with BATCH_K exported by the host. The gate records every such name it sees.
S = L:scaffold("arm52")
L:candidate(S, "1070-aaaa", "a52.txt", "A")
prs_n(S, { { 70, "work/1070-aaaa" } })
L:gate(S, "echo gated >> @GATE_LOG@\ncompgen -v TILLANDSIAS_LAND_QUEUE_ >> " .. q(S.GATE_LOG .. ".knobs") .. " 2>/dev/null\n: >> "
    .. q(S.GATE_LOG .. ".knobs") .. "\nexit 0\n")
out = L:run_queue(S, { prefix = "export TILLANDSIAS_LAND_QUEUE_BATCH_K=4; " })
arm("ARM 52: the gate inherits no TILLANDSIAS_LAND_QUEUE_* knob, even with BATCH_K exported by the host (2174-dail)",
    gates(S) == 1 and L:read(S.GATE_LOG .. ".knobs") == "" and line(out, "^land:70 "),
    "gates=" .. gates(S) .. " knobs=" .. L:read(S.GATE_LOG .. ".knobs") .. " " .. out)

-- ARM 51: THE REAL SELECTOR against a proof (scripts/change-class.sh may-skip,
-- its own repo): a changed declared input RUNS, a docs-only change SKIPS, a
-- stale proof RUNS. The selector knobs are the CALLER's: unset them all.
local C51 = TMP .. "/arm51"
L:must("set -e\nC=" .. q(C51) .. "\nmkdir -p \"$C/scripts\"\ncp " .. q(L.ROOT .. "/scripts/change-class.sh") .. " " .. q(L.ROOT .. "/scripts/gate-stamp.sh")
    .. " \"$C/scripts/\"\ngit -C \"$C\" init -q; git -C \"$C\" config user.email t@l; git -C \"$C\" config user.name t; git -C \"$C\" config commit.gpgsign false\n"
    .. "echo a > \"$C/x.txt\"; echo r > \"$C/README.md\"\ngit -C \"$C\" add -A; git -C \"$C\" commit -qm proved\ndate -u +%s > \"$C.marker\"")
local b51 = L:rev(C51, "HEAD")
local function ms51()
    return text.trim((L:sh("cd " .. q(C51) .. " && unset TILLANDSIAS_CLASS_SELECTOR TILLANDSIAS_TRUNK_BRANCH TILLANDSIAS_CHANGE_CLASS_REMOTE TILLANDSIAS_FULL_GATE_MAX_AGE_S"
        .. " && TILLANDSIAS_CLASS_BASE=" .. q(b51) .. " TILLANDSIAS_FULL_GATE_MARKER=" .. q(C51 .. ".marker")
        .. " bash scripts/change-class.sh may-skip gate-step:t path:x.txt 2>/dev/null")))
end
L:must("echo b >> " .. q(C51 .. "/x.txt") .. "; git -C " .. q(C51) .. " commit -qam x")
local va = ms51()
L:must("git -C " .. q(C51) .. " reset -q --hard " .. b51 .. "; echo more >> " .. q(C51 .. "/README.md") .. "; git -C " .. q(C51) .. " commit -qam doc")
local vb = ms51()
L:write(C51 .. ".marker", "1\n")
local vc = ms51()
arm("ARM 51: against a proof, a changed declared input RUNS, a docs-only change SKIPS, a stale proof RUNS (real change-class.sh)",
    va == "run" and vb == "skip" and vc == "run", va .. "/" .. vb .. "/" .. vc)

-- ARM 53 (2209-dfix): the publish goes through the REAL pre-push hook. A daily
-- verdict ref is exempt; a non-epoch name under the same namespace and an
-- ordinary branch are not (premise: this repo has no gate stamp).
local C53 = TMP .. "/arm53"
L:must("set -e\nC=" .. q(C53) .. "\nmkdir -p \"$C/w/scripts/hooks\"\ngit init -q --bare \"$C/r.git\"\ncp " .. q(L.ROOT .. "/scripts/hooks/pre-push-local-gate.sh")
    .. " \"$C/w/scripts/hooks/\"; cp " .. q(L.ROOT .. "/scripts/gate-stamp.sh") .. " \"$C/w/scripts/\"\n"
    .. "git -C \"$C/w\" init -q; git -C \"$C/w\" config user.email t@l; git -C \"$C/w\" config user.name t; git -C \"$C/w\" config commit.gpgsign false\n"
    .. "git -C \"$C/w\" add -A; git -C \"$C/w\" commit -qm base\ngit -C \"$C/w\" push -q \"$C/r.git\" HEAD:refs/heads/linux-next 2>/dev/null\n"
    .. "printf '#!/bin/sh\\nexec bash scripts/hooks/pre-push-local-gate.sh \"$@\"\\n' > \"$C/w/.git/hooks/pre-push\"; chmod +x \"$C/w/.git/hooks/pre-push\"")
local function p53(ref)
    local _, c = L:sh("cd " .. q(C53 .. "/w") .. " && git push -q " .. q(C53 .. "/r.git") .. " " .. q("HEAD:" .. ref) .. " </dev/null >/dev/null 2>&1")
    return c
end
local a, b, c, d = p53("refs/attest/daily-full/1795348746"), p53("refs/attest/daily-red/1795348747"),
    p53("refs/attest/daily-red/not-an-epoch"), p53("refs/heads/not-exempt")
arm("ARM 53: the real pre-push hook lets daily-full/daily-red <epoch> refs through and still refuses a non-epoch attest name and a branch (2209-dfix)",
    d ~= 0 and c ~= 0 and a == 0 and b == 0, a .. "/" .. b .. "/" .. c .. "/" .. d)

-- ARM 54 (2209-dfix): a held lock is SAID. With a live holder, --daily-full
-- waits (bounded) and then names the holder; a plain run names it too; no gate
-- runs. The holder is a process, so it lives in the shell block.
L:write(S.GATE_LOG, "")
local OUTA, OUTB = S.dir .. "/o54a", S.dir .. "/o54b"
local qa = L:run_queue(S, { extra = { TILLANDSIAS_LAND_QUEUE_DAILY_LOCK_WAIT_S = "0" }, wrap = function(cmd) return "LOCK=\"$(cd " .. q(S.WORK) .. " && git rev-parse --show-toplevel)/.git/tillandsias-land-queue.lock\"\n"
    .. "sleep 300 & H=$!\nmkdir -p \"$LOCK\"; echo $H > \"$LOCK/pid\"\n"
    .. cmd:gsub("bash " .. q(L.QUEUE):gsub("%p", "%%%0"), "bash " .. q(L.QUEUE) .. " --daily-full", 1)
    .. " > " .. q(OUTA) .. "; RA=$?\n" .. cmd .. " > " .. q(OUTB) .. "; RB=$?\n"
    .. "kill $H 2>/dev/null; wait $H 2>/dev/null; rm -rf \"$LOCK\"\necho \"h=$H ra=$RA rb=$RB\"" end })
local h54, ra, rb = qa:match("h=(%d+) ra=(%d+) rb=(%d+)")
local o54a, o54b = L:read(OUTA), L:read(OUTB)
arm("ARM 54: a live lock holder is named by --daily-full (after its bounded wait) and by a plain run; neither gates (2209-dfix)",
    h54 and ra == "3" and rb == "3" and line(o54a, "^land%-queue:daily%-full:waiting%-for%-lock:" .. h54 .. " ")
    and line(o54a, "^skip:land%-queue:daily%-full:lock%-held:" .. h54 .. " ") and line(o54b, "^skip:land%-queue:in%-flight:" .. h54 .. " ")
    and gates(S) == 0, qa .. " gates=" .. gates(S) .. " " .. o54a .. o54b)

-- ARM 55 (2215-trad): a train survives a PLAN-ONLY move of the trunk mid-gate.
-- The gate moves the trunk ONCE, from a side clone: 55 by a plan/index.d
-- fragment (adopt, one gate, lands on the new tip); 55b by a code file.
local function arm55(name, moved)
    local S0 = L:scaffold(name)
    L:candidate(S0, "1061-aaaa", "a55.txt", "A")
    L:candidate(S0, "1062-bbbb", "b55.txt", "B")
    prs_n(S0, { { 61, "work/1061-aaaa" }, { 62, "work/1062-bbbb" } })
    local side, once = S0.dir .. "/side", S0.dir .. "/moved"
    L:must("git clone -q " .. q(S0.REMOTE) .. " " .. q(side) .. "; git -C " .. q(side) .. " config user.email t@l; git -C " .. q(side)
        .. " config user.name t; git -C " .. q(side) .. " config commit.gpgsign false")
    L:gate(S0, "echo gated >> @GATE_LOG@\nif [ ! -e " .. q(once) .. " ]; then\n    : > " .. q(once) .. "; mkdir -p \"$(dirname " .. q(side .. "/" .. moved) .. ")\"; echo moved > "
        .. q(side .. "/" .. moved) .. "\n    git -C " .. q(side) .. " add -A && git -C " .. q(side) .. " commit -qm move && git -C " .. q(side) .. " push -q origin HEAD:linux-next\nfi\nexit 0\n")
    return S0, L:run_queue(S0, { BATCH_K = "4", TRAIN_LOG = S0.dir .. "/trains.log" }), side
end
local S55, o55, side55 = arm55("arm55", "plan/index.d/20261122t000000z-arm55.yaml")
local h55, mv55 = L:rev(S55.REMOTE, "linux-next"), L:rev(side55, "HEAD")
local _, anc = L:sh("git -C " .. q(S55.REMOTE) .. " merge-base --is-ancestor " .. mv55 .. " " .. h55)
arm("ARM 55: a train whose trunk moved by plan fragments only is adopted onto the new tip and lands on its one gate (2215-trad)",
    line(o55, "^train:adopt:plan%-only%-move:") and landed(o55, "^land:6[12] .*train=") == 2 and gates(S55) == 1 and anc == 0
    and landed(L:sh("git -C " .. q(S55.REMOTE) .. " ls-tree --name-only " .. h55), "^[ab]55%.txt$") == 2, "gates=" .. gates(S55) .. " " .. o55)
local S55b, o55b = arm55("arm55b", "src55.rs")
arm("ARM 55b: a code move mid-gate is not adopted; the train pushes nothing and its members go one at a time",
    line(o55b, "^train:target%-moved:") and not line(o55b, "^train:adopt") and landed(o55b, "^land:.*train=") == 0, o55b)

-- ARM 56 (2248-jihs): `--status` answers without the lock. (a) no holder: the
-- idle line naming the newest land; (b) a live holder: the running phase from
-- the run dir's `current`, elapsed rendered; neither gates nor locks; (c) a real
-- run published its last word to refs/tillandsias/queue/status.
S = S55b
L:write(S.GATE_LOG, "")
local o56a, r56a = L:run_queue(S, nil, "--status")
local LQ56 = TMP .. "/lq56"
local o56 = L:run_queue(S, { LOGDIR = LQ56, wrap = function(cmd)
    return "LOCK=\"$(cd " .. q(S.WORK) .. " && git rev-parse --show-toplevel)/.git/tillandsias-land-queue.lock\"\nsleep 300 & H=$!\n"
        .. "mkdir -p \"$LOCK\" " .. q(LQ56 .. "/run1") .. "; echo $H > \"$LOCK/pid\"\necho " .. q(LQ56 .. "/run1") .. " > " .. q(LQ56 .. "/current-run") .. "\n"
        .. "echo \"queue:gating:#7 work/0001-abcd phase=gate started=$(( $(date +%s) - 5 )) train=- waiting=2\" > " .. q(LQ56 .. "/run1/current") .. "\n"
        .. cmd:gsub("bash " .. q(L.QUEUE):gsub("%p", "%%%0"), "bash " .. q(L.QUEUE) .. " --status", 1) .. "; RB=$?\n"
        .. "kill $H 2>/dev/null; wait $H 2>/dev/null\n[ -d \"$LOCK\" ] && echo lock=held; rm -rf \"$LOCK\"\necho rb=$RB" end })
local pub = L:sh("git -C " .. q(S.REMOTE) .. " log -1 --format=%s refs/tillandsias/queue/status 2>/dev/null")
arm("ARM 56: --status says idle/last-land or the live phase with elapsed, takes no lock, gates nothing; a run publishes refs/tillandsias/queue/status (2248-jihs)",
    r56a == 0 and line(o56a, "^queue:idle last%-land=" .. string.rep("%x", 40) .. " %d+s$") and line(o56, "^rb=0$")
    and line(o56, "^queue:gating:#7 work/0001%-abcd phase=gate elapsed=[5-9] train=%- waiting=2$") and line(o56, "^lock=held$")
    and gates(S) == 0 and line(pub, "^queue:idle last%-land="), "rc=" .. tostring(r56a) .. " published='" .. pub .. "' " .. o56a .. "\n" .. o56)

-- ARM 57 (bundle landing phase 1): every train writes ONE bundles.log line
-- beside trains.log, and heavy= counts members by gate-changed's own answer.
-- (a) landed, one of two members probed heavy; (b) red, promoted=-; (c) a gate
-- rc=137 is the host's, aborted and never red; (d) a probe that does not answer
-- reads `-`, never 0; (e) the REAL default probe answers in the scratch tree.
local P57 = TMP .. "/heavy57.sh"
L:write(P57, 'if grep -q heavy <<<"$(git diff --name-only "$1")"; then echo "heavy:guard:x"; else echo "select:intake fixtures=1/9"; fi\n')
local all57 = ""
local function arm57(name, grc, probe)
    local S0 = L:scaffold(name)
    L:candidate(S0, "1071-aaaa", "light57.txt", "A")
    L:candidate(S0, "1072-bbbb", "heavy57.txt", "B")
    prs_n(S0, { { 71, "work/1071-aaaa" }, { 72, "work/1072-bbbb" } })
    local once = S0.dir .. "/once"
    L:gate(S0, "[ -e " .. q(once) .. " ] && exit 0\n: > " .. q(once) .. "\nexit " .. grc .. "\n")
    all57 = all57 .. "\n" .. L:run_queue(S0, { BATCH_K = "4", HEAVY_PROBE = probe, TRAIN_LOG = S0.dir .. "/trains.log" })
    return text.trim(L:read(S0.dir .. "/bundles.log")), S0
end
local X9 = string.rep("%x", 9)
local la, S57 = arm57("arm57a", "0", "bash " .. P57)
local h57, t57 = L:rev(S57.REMOTE, "linux-next"), L:rev(S57.REMOTE, "linux-next^{tree}")
local lb = arm57("arm57b", "1", "bash " .. P57)
local lc = arm57("arm57c", "137", "bash " .. P57)
local ld = arm57("arm57d", "0", "false")
local le = arm57("arm57e", "0", "")
local bad57 = {}
local function want(l, pat, tag) if not line(l, pat) then bad57[#bad57 + 1] = tag end end
want(la, "^bundle:green:train%-%d+ members=2 heavy=1 base=" .. X9 .. " tree=" .. t57:sub(1, 9) .. " gate_s=%d+ reason=train promoted=" .. h57:sub(1, 9)
    .. " cause=landed:" .. h57:sub(1, 9) .. " ids=#71,#72 ts=[%dTZ:%-]+$", "a")
want(lb, "^bundle:red:train%-%d+ members=2 heavy=1 .* promoted=%- cause=red:rc=1:unjudged:no%-step%-named ", "b")
want(lc, "^bundle:aborted:train%-%d+ .* promoted=%- cause=red:rc=137 ", "c")
want(ld, "^bundle:green:train%-%d+ members=2 heavy=%- ", "d")
want(le, "^bundle:green:train%-%d+ members=2 heavy=2 ", "e")
for _, l in ipairs({ la, lb, lc, ld, le }) do if LQ.nlines(l) ~= 1 then bad57[#bad57 + 1] = "not-one-line" end end
arm("ARM 57: one bundles.log line per train (green/red/aborted) with members, heavy, base, tree, gate seconds, promoted; an unanswered heavy probe reads '-'",
    #bad57 == 0, table.concat(bad57, " ") .. "\na=" .. la .. "\nb=" .. lb .. "\nc=" .. lc .. "\nd=" .. ld .. "\ne=" .. le .. all57)

-- ARM 58 (2281-xx62): TILLANDSIAS_BUNDLE_HEAVY_MAX caps a train's non-light
-- members. Queue order heavy, heavy, light. (a) max=1: #71,#73 ride, #72 alone;
-- (b) max=2: all three; (c) an unanswered probe counts toward the cap; (d)
-- max=0 takes no heavy member; (e) an unreadable max is said aloud, read as 2.
local function arm58(name, max, probe)
    local S0 = L:scaffold(name)
    L:candidate(S0, "1081-aaaa", "heavy58a.txt", "A")
    L:candidate(S0, "1082-bbbb", "heavy58b.txt", "B")
    L:candidate(S0, "1083-cccc", "light58.txt", "C")
    prs_n(S0, { { 71, "work/1081-aaaa" }, { 72, "work/1082-bbbb" }, { 73, "work/1083-cccc" } })
    L:gate(S0, "exit 0\n")
    local o = L:run_queue(S0, { BATCH_K = "4", HEAVY_MAX = max, HEAVY_PROBE = probe, TRAIN_LOG = S0.dir .. "/trains.log" })
    return o, text.trim(L:read(S0.dir .. "/bundles.log")), landed(o, "^land:7[123] .*gate=green")
end
local bad58, all58 = {}, ""
local o, l, n = arm58("arm58a", "1", "bash " .. P57); all58 = all58 .. o
if not (line(l, "members=2 heavy=1 .* ids=#71,#73 ") and has(o, "train:accept:#71 tier=heavy") and has(o, "train:accept:#73 tier=light")
    and has(o, "train:heavy-deferred:#72 tier=heavy max=1") and n == 3) then bad58[#bad58 + 1] = "a" end
o, l, n = arm58("arm58b", "2", "bash " .. P57); all58 = all58 .. o
if not (line(l, "members=3 heavy=2 .* ids=#71,#72,#73 ") and n == 3) then bad58[#bad58 + 1] = "b" end
o, l, n = arm58("arm58c", "1", "false"); all58 = all58 .. o
if not (l == "" and has(o, "train:heavy-deferred:#72 tier=unknown max=1") and n == 3) then bad58[#bad58 + 1] = "c" end
o, l, n = arm58("arm58d", "0", "bash " .. P57); all58 = all58 .. o
if not (l == "" and has(o, "train:heavy-deferred:#71 tier=heavy max=0") and n == 3) then bad58[#bad58 + 1] = "d" end
o, l, n = arm58("arm58e", "two", "bash " .. P57); all58 = all58 .. o
if not (has(o, "train:heavy-max-unreadable:'two'") and has(l, "members=3 heavy=2 ")) then bad58[#bad58 + 1] = "e" end
arm("ARM 58: HEAVY_MAX caps a train's heavy and unmeasured members; the rest go one at a time", #bad58 == 0, table.concat(bad58, " ") .. "\n" .. all58)

-- ARM 60 (bundle landing phase 0): SHADOW INTAKE records intake's verdict beside
-- the gate's and changes nothing. (a) #81 green + intake ok, #82 red + red, #83
-- green + heavy (rc 10); (b) the stub writes into its own tree and the queue's
-- checkout stays clean; every shadow ran after the last gate; (c) OFF by default;
-- (d) a train's members log via=train; (e) the run bound names what it drops;
-- (f) a per-PR timeout is timeout, never red; (g) a false red keeps its log;
-- (h) --status names the log; (i) a stop request ends it at the next PR; (j) a
-- land run that starts while a shadow holds its lock asks it to stop; (k) a
-- stop MID-BUILD ends the build's whole process tree; (l) the same through the
-- builder wrapper (a named skip where there is no builder).
local STUB60 = [[
[ -e dirt-from-shadow ] && dirty=dirty || dirty=clean
echo "shadow gates=$(grep -c . "@GATES@") nice=$(nice) $dirty shared=${TILLANDSIAS_SHARED_TARGET:-on}" >> "@SEEN@"
echo dirt > dirt-from-shadow; echo dirt >> seed-dirt
if [ -e c83.txt ]; then echo "heavy:guard:x fixtures=9 crates=28 changed=1"; exit 10; fi
if [ -e c82.txt ]; then echo "select:intake fixtures=6/9 deferred=1 crates=0/28 changed=1 base=x"; exit 1; fi
if [ -e c84.txt ]; then : > "@LOCK@/stop"; exit 0; fi
if [ -e c81.txt ]; then echo "select:intake fixtures=5/9 deferred=1 crates=2/28 changed=1 base=x"; exit 0; fi
if [ -e slow.txt ]; then sleep 30; fi
exit 1
]]
local b60 = {}
local function arm60(name, k, files, o60)
    o60 = o60 or {}
    local S0 = L:scaffold(name)
    local js = {}
    for i, f in ipairs(files) do
        local num = 80 + i
        L:candidate(S0, "10" .. num .. "-aaaa", f, "A")
        js[#js + 1] = { num, "work/10" .. num .. "-aaaa" }
    end
    prs_n(S0, js)
    L:gate(S0, "echo gated >> @GATE_LOG@\n[ -e c82.txt ] && exit 1\nexit 0\n")
    L:write(S0.dir .. "/seen", "")
    local stub = STUB60:gsub("@GATES@", S0.GATE_LOG):gsub("@SEEN@", S0.dir .. "/seen"):gsub("@LOCK@", S0.dir .. "/lock")
    L:write(S0.dir .. "/stub.sh", stub)
    local cmd = o60.cmd
    if cmd == nil then cmd = "bash " .. S0.dir .. "/stub.sh" end
    local out0 = L:run_queue(S0, { BATCH_K = tostring(k), SHADOW = cmd, SHADOW_LOCK = S0.dir .. "/lock", SHADOW_TREE = S0.dir .. "/shtree",
        SHADOW_LOG = S0.dir .. "/shadow.log", SHADOW_PR_S = o60.pr_s or "60", SHADOW_RUN_S = o60.run_s or "60", LOGDIR = S0.dir .. "/logs", wrap = o60.wrap })
    if L:sh("[ -d " .. q(S0.WORK .. "/.git/tillandsias-land-queue.lock") .. " ] && echo held") ~= "" then b60[#b60 + 1] = name .. "-land-lock-held" end
    if not o60.j then
        L:sh("for w in $(seq 1 600); do n=$(grep -cE '^(shadow:accept|unmeasured):' " .. q(S0.dir .. "/shadow.log") .. " 2>/dev/null); "
            .. "[ \"${n:-0}\" -ge " .. (o60.lines or 1) .. " ] && [ ! -d " .. q(S0.dir .. "/lock") .. " ] && break; sleep 0.1; done")
    end
    return out0, L:read(S0.dir .. "/shadow.log"), S0
end
local o60, l60, S60 = arm60("arm60a", 1, { "c81.txt", "c82.txt", "c83.txt" }, { lines = 3 })
if not line(l60, "^shadow:accept:81 tier=intake selected=5/9 crates=2 intake_s=%d+ intake=ok gate=green via=single base=" .. X9 .. " head=" .. X9 .. " rc=0 ts=") then b60[#b60 + 1] = "a81" end
if not line(l60, "^shadow:accept:82 tier=intake selected=6/9 crates=0 .* intake=red gate=red ") then b60[#b60 + 1] = "a82" end
if not line(l60, "^shadow:accept:83 tier=heavy selected=%-/9 crates=%- .* intake=%- gate=green ") then b60[#b60 + 1] = "a83" end
local tree_pat = "^shadow:tree " .. (S60.dir .. "/shtree"):gsub("%p", "%%%0") .. " size_mb=%d+$"
if not (landed(l60, "^shadow:accept:") == 3 and line(l60, tree_pat) and line(o60, "^land:81 ") and line(o60, "^land:83 ")
    and line(o60, "^evict:land%-queue:82")) then b60[#b60 + 1] = "a-landing" end
-- nice -n 10 adds to the caller's own niceness: an agent session at 5 gives 15.
local nice60 = math.min(19, (tonumber(text.trim((L:sh("nice")))) or 0) + 10)
if landed(L:read(S60.dir .. "/seen"), "gates=3 nice=" .. nice60 .. " clean shared=off$") ~= 3 then b60[#b60 + 1] = "b-order" end
if not (text.trim((L:sh("git -C " .. q(S60.WORK) .. " status --porcelain --untracked-files=no"))) == ""
    and L:sh("[ -e " .. q(S60.WORK .. "/dirt-from-shadow") .. " ] || [ -e " .. q(S60.WORK .. "/target/shadow-intake") .. " ] || echo clean") ~= ""
    and L:sh("[ -e " .. q(S60.dir .. "/shtree/.git") .. " ] && echo y") ~= "") then b60[#b60 + 1] = "b-isolation" end
local st60 = L:run_queue(S60, { SHADOW = "x", SHADOW_LOG = S60.dir .. "/shadow.log" }, "--status")
if not line(st60, "^queue:shadow [a-z]+ pr=[%-#%d]+ log=" .. (S60.dir .. "/shadow.log"):gsub("%p", "%%%0") .. " lines=3$")
    or not (line(st60, "^queue:shadow idle ") or line(st60, "^queue:shadow running ")) then b60[#b60 + 1] = "h-status" end
local oc60, _, Sc = arm60("arm60c", 1, { "c81.txt" }, { cmd = "", lines = 0 })
if not (L:sh("[ -e " .. q(Sc.dir .. "/shadow.log") .. " ] || echo none") ~= "" and L:read(Sc.dir .. "/seen") == "" and line(oc60, "^land:81 ")
    and not has(oc60, "shadow")) then b60[#b60 + 1] = "c-off" end
local _, ld60, Sd = arm60("arm60d", 4, { "c81.txt", "c83.txt" }, { lines = 2 })
if not (landed(ld60, "gate=green via=train") == 2 and gates(Sd) == 1) then b60[#b60 + 1] = "d-train" end
local oe60, le60 = arm60("arm60e", 1, { "c81.txt" }, { run_s = "0" })
if not (line(le60, "^unmeasured:shadow:81:run%-bound gate=green") and line(oe60, "^land:81 ")) then b60[#b60 + 1] = "e-bound" end
local _, lf60 = arm60("arm60f", 1, { "slow.txt" }, { pr_s = "1" })
if not has(lf60, "intake=timeout gate=green") or not lf60:find("intake=timeout gate=green .* rc=124 ") then b60[#b60 + 1] = "f-timeout" end
local _, lg60, Sg = arm60("arm60g", 1, { "other.txt" })
if not (has(lg60, "intake=red gate=green ") and L:sh("ls " .. q(Sg.dir .. "/logs") .. "/*/shadow-81-false-red.log >/dev/null 2>&1 && echo y") ~= "") then b60[#b60 + 1] = "g-false-red" end
local _, li60 = arm60("arm60i", 1, { "c84.txt", "other.txt" }, { lines = 2 })
if not (line(li60, "^shadow:accept:81 .* intake=ok ") and line(li60, "^unmeasured:shadow:82:stopped gate=green")) then b60[#b60 + 1] = "i-stop" end
-- (k)/(l): a watcher beside the queue stops the shadow once the marker is live,
-- and what is left of it is counted. The sleep's duration is its marker.
local m60 = "86" .. tostring(math.random(10000, 99999))
L:write(TMP .. "/mid60.sh", "sleep " .. m60 .. " & sleep " .. m60 .. "\n")
L:write(TMP .. "/mid60tb.sh", "bash " .. q(L.ROOT .. "/scripts/with-tillandsias-builder.sh") .. " sleep 1" .. m60 .. "\n")
local function mid60(name, stub, pat)
    local lockd = TMP .. "/" .. name .. "/lock"
    local _, lm = arm60(name, 1, { "other.txt" }, { cmd = "bash " .. stub, wrap = function(cmd)
        return "( for w in $(seq 1 300); do pgrep -f " .. q(pat) .. " >/dev/null && { sleep 1; : > " .. q(lockd .. "/stop") .. "; break; }; sleep 0.1; done ) &\n"
            .. "SP=$!\nOUT=$(" .. cmd .. "); RC=$?\nwait $SP\nprintf '%s\\n' \"$OUT\"\nexit $RC" end })
    if not line(lm, "^unmeasured:shadow:81:stopped%-mid%-build gate=green") then b60[#b60 + 1] = name .. "-unnamed" end
    local left = L:sh("for w in $(seq 1 100); do pgrep -f " .. q(pat) .. " >/dev/null || break; sleep 0.1; done\n"
        .. "pgrep -f " .. q(pat) .. " >/dev/null && { echo survivor; pkill -f " .. q(pat) .. "; }; true")
    if has(left, "survivor") then b60[#b60 + 1] = name .. "-survivor" end
end
mid60("arm60k", TMP .. "/mid60.sh", "^sleep " .. m60 .. "$")
if L:sh("command -v toolbox >/dev/null 2>&1 && toolbox list -c 2>/dev/null | grep -q tillandsias-builder && echo y") ~= "" then
    mid60("arm60l", TMP .. "/mid60tb.sh", "^sleep 1" .. m60 .. "$")
else LQ.skip("ARM 60l", "no tillandsias-builder toolbox here") end
-- (j): a live shadow holds the lock; the land run asks it to stop and still lands.
local lockj = TMP .. "/arm60j/lock"
local oj60 = arm60("arm60j", 1, { "c81.txt" }, { cmd = "", lines = 0, j = true, wrap = function(cmd)
    return "sleep 300 & H=$!\nmkdir -p " .. q(lockj) .. "; echo $H > " .. q(lockj .. "/pid") .. "\nOUT=$(" .. cmd .. "); RC=$?\n"
        .. "kill $H 2>/dev/null; wait $H 2>/dev/null\nprintf '%s\\n' \"$OUT\"\nexit $RC" end })
if not (L:sh("[ -e " .. q(lockj .. "/stop") .. " ] && echo y") ~= "" and line(oj60, "^land:81 ")) then b60[#b60 + 1] = "j-signal" end
arm("ARM 60: shadow intake logs intake beside the gate after the last gate, in its own tree; off by default, bounded by name, and lands exactly what it would have",
    #b60 == 0, table.concat(b60, " ") .. "\n" .. l60 .. "\n" .. o60 .. "\n" .. L:read(S60.dir .. "/seen"))

-- ARM 61 (bundle landing phase 2 prep): `--status` also says what is next, the
-- open train and the shadow, and `--status --pr N` answers "is my PR gating?".
-- Asked from INSIDE a real gate, so it reads what a run really wrote.
S = L:scaffold("arm61")
for i = 1, 3 do L:candidate(S, "109" .. i .. "-aaaa", "s61" .. i .. ".txt", "A") end
prs_n(S, { { 91, "work/1091-aaaa" }, { 92, "work/1092-aaaa" }, { 93, "work/1093-aaaa" } })
local ST, SK = S.dir .. "/st", S.dir .. "/sk"
L:must("mkdir -p " .. q(ST) .. " " .. q(SK))
L:gate(S, "n=\"$(grep -c . @GATE_LOG@)\"; echo gated >> @GATE_LOG@\n"
    .. "s() { ( cd @WORK@ && TILLANDSIAS_LAND_QUEUE_GH=@GH_BIN@ TILLANDSIAS_LAND_QUEUE_REMOTE=origin TILLANDSIAS_TRUNK_BRANCH=linux-next TILLANDSIAS_LAND_QUEUE_LOGDIR="
    .. q(S.dir .. "/logs") .. " TILLANDSIAS_LAND_QUEUE_TRAIN_LOG=" .. q(S.dir .. "/trains.log") .. " TILLANDSIAS_LAND_QUEUE_SHADOW_LOCK=" .. q(SK)
    .. " TILLANDSIAS_LAND_QUEUE_SHADOW_LOG=" .. q(S.dir .. "/shadow.log") .. " bash " .. q(L.QUEUE) .. " \"$@\" 2>&1 ); }\n"
    .. "s --status > " .. q(ST) .. "/status.$n; for p in 91 93 99; do s --status --pr \"#$p\" > " .. q(ST) .. "/pr$p.$n; done\n"
    .. "git -C @REMOTE@ log -1 --format=%B refs/tillandsias/queue/status > " .. q(ST) .. "/pub.$n\nexit 0\n")
L:write(SK .. "/current", "88")
L:run_queue(S, { BATCH_K = "2", HEAVY_PROBE = "bash " .. P57, TRAIN_LOG = S.dir .. "/trains.log", SHADOW_LOCK = SK, SHADOW_LOG = S.dir .. "/shadow.log",
    LOGDIR = S.dir .. "/logs", wrap = function(cmd)
        return "sleep 300 & H=$!\necho $H > " .. q(SK .. "/pid") .. "\nOUT=$(" .. cmd .. "); RC=$?\nkill $H 2>/dev/null; wait $H 2>/dev/null\nprintf '%s\\n' \"$OUT\"\nexit $RC" end })
local b61 = {}
local s0, s1 = L:read(ST .. "/status.0"), L:read(ST .. "/status.1")
local function w61(cond, tag) if not cond then b61[#b61 + 1] = tag end end
w61(line(s0, "^queue:gating:#91 train phase=train%-gate elapsed=%d+ train=#91,#92 waiting=%d+$"), "f-first-line")
w61(line(s0, "^queue:bundle open=train%-%d+ members=#91,#92 heavy=0 base=" .. X9 .. " phase=train%-gate elapsed=%d+$"), "a-bundle")
w61(line(s0, "^queue:next #93$"), "a-next")
w61(line(L:read(ST .. "/pr91.0"), "^queue:pr:#91 gating "), "a-pr91")
w61(line(L:read(ST .. "/pr93.0"), "^queue:pr:#93 waiting position=1 of=1$"), "a-pr93")
w61(line(L:read(ST .. "/pr99.0"), "^queue:pr:#99 not%-in%-this%-run "), "a-pr99")
w61(line(s1, "^queue:gating:#93 work/1093%-aaaa phase=gate ") and line(s1, "^queue:bundle open=%- last=bundle:green:train%-%d+ members=2 ")
    and line(s1, "^queue:next %-$"), "b-single")
w61(line(L:read(ST .. "/pr93.1"), "^queue:pr:#93 gating "), "b-pr93")
-- the run asked this live shadow to stop at its start (2285-haa6), so it reads stopping
w61(line(s0, "^queue:shadow stopping pr=#88 log=" .. (S.dir .. "/shadow.log"):gsub("%p", "%%%0") .. " lines=0$"), "c-shadow")
local pub0 = L:read(ST .. "/pub.0")
w61(line(pub0, "^queue:bundle open=train%-") and not has(pub0, TMP), "e-published")
local si = L:run_queue(S, { SHADOW_LOCK = SK, TRAIN_LOG = S.dir .. "/trains.log", LOGDIR = S.dir .. "/logs" }, "--status")
w61(line(si, "^queue:idle last%-land=") and line(si, "^queue:bundle open=%- last=bundle:green:") and line(si, "^queue:shadow idle pr=%- ")
    and not line(si, "^queue:next"), "b-idle")
local g61 = gates(S)
local p1 = L:run_queue(S, { LOGDIR = S.dir .. "/logs" }, "--pr", "91")
local p3, r3 = L:run_queue(S, { LOGDIR = S.dir .. "/logs" }, "--status", "--pr")
w61(gates(S) == g61 and line(p1, "^queue:pr:#91 idle "), "d-pr-alone")
w61(r3 ~= 0 and has(p3, "fail:land-queue:pr-needs-a-number"), "d-no-number")
arm("ARM 61: --status names the open train, what is next and the shadow from inside a real gate, --pr answers for one PR, and neither runs the queue",
    #b61 == 0, table.concat(b61, " ") .. "\n" .. s0 .. "\n--\n" .. s1 .. "\n--\n" .. si .. "\n" .. p1 .. "\n" .. p3)

-- ARM 62 (bundle landing phase 1): A RED TRAIN IS DIAGNOSED BY ITS FAILING STEP.
-- One gate-run step (scripts/test-s62.sh, red iff bad.txt exists) runs through a
-- stub build.sh exactly as the gate would. (a) culprit leaves, the rest land on
-- ONE more gate; (b) a flake rides again; (c) trunk red holds; (d) a script the
-- log names but no gate step runs is NEVER executed; (e) red alone on the trunk
-- while its gate is green is not judged; (f) a member that ADDS the red step is
-- the culprit; (g) diagnosis off is the old fallback; (h) two members each
-- bring their own red: the second train is red too, no third train.
local function arm62(name, body, files, o62)
    o62 = o62 or {}
    local S0 = L:scaffold(name)
    L:git(S0, "checkout", "-q", "linux-next")
    local W = S0.WORK
    L:must("mkdir -p " .. q(W .. "/scripts/gate-steps.d"))
    L:write(W .. "/scripts/test-s62.sh", "echo ran-s62 >> " .. q(S0.dir .. "/step-runs") .. "\n[ ! -e bad.txt ]\n")
    L:write(W .. "/scripts/test-actor62.sh", "echo actor >> " .. q(S0.dir .. "/actor-ran") .. "\n")
    L:write(W .. "/scripts/gate-steps.d/100-s62.step", 'STEP_DESC="s62"\nSTEP_SCRIPT="scripts/test-s62.sh"\n')
    L:write(W .. "/build.sh", '#!/usr/bin/env bash\n[ "$1 $2 $3" = "--gate-steps . --gate-step" ] || exit 2\n'
        .. 'bash "$(sed -n \'s/^STEP_SCRIPT="\\(.*\\)"$/\\1/p\' scripts/gate-steps.d/"$4"-*.step)"\n', true)
    if o62.trunk then L:write(W .. "/" .. o62.trunk, "x\n") end
    L:must("git -C " .. q(W) .. " add -A; git -C " .. q(W) .. " commit -q -m base62; git -C " .. q(W) .. " push -q origin linux-next")
    local js = {}
    for i, f in ipairs(files) do
        local ord = "109" .. i .. "-aaaa"
        if f == "addstep" then
            L:must("set -e\nW=" .. q(W) .. "\ngit -C \"$W\" checkout -q -B " .. q("work/" .. ord) .. " origin/linux-next\nprintf 'exit 1\\n' > \"$W/scripts/test-new62.sh\"\n"
                .. "printf 'STEP_SCRIPT=\"scripts/test-new62.sh\"\\n' > \"$W/scripts/gate-steps.d/200-new.step\"\n"
                .. "git -C \"$W\" add -A; git -C \"$W\" commit -q -m add; git -C \"$W\" push -q origin " .. q("work/" .. ord) .. "; git -C \"$W\" checkout -q linux-next")
        else L:candidate(S0, ord, f, f) end
        js[#js + 1] = { 90 + i, "work/" .. ord }
    end
    prs_n(S0, js)
    L:gate(S0, 'echo "gated" >> @GATE_LOG@\nn="$(grep -c . @GATE_LOG@)"\n' .. body .. "\n")
    local o0, rc0 = L:run_queue(S0, { BATCH_K = "4", HEAVY_MAX = "4", TRAIN_LOG = S0.dir .. "/trains.log", extra = o62.extra })
    return o0, rc0, L:read(S0.dir .. "/bundles.log"), gates(S0), S0
end
local G62 = '[ ! -e bad.txt ] || { echo "red-script:scripts/test-s62.sh"; exit 1; }'
local b62, all62 = {}, ""
local function chk(tag, cond, o0, l0) all62 = all62 .. "\n== " .. tag .. "\n" .. l0 .. "\n" .. o0; if not cond then b62[#b62 + 1] = tag end end
local o2, r2, l2, g2, S2x = arm62("arm62a", G62, { "ok1.txt", "bad.txt", "ok3.txt" })
chk("a-culprit", line(o2, "^train:red:culprit=#92 ") and landed(o2, "^land:9[13] .*train=") == 2 and g2 == 3 and line(o2, "^evict:land%-queue:92:")
    and line(l2, "^bundle:red:.* cause=red:rc=1:culprit=#92 "), o2, l2)
o2, r2, l2, g2 = arm62("arm62b", 'if [ "$n" -eq 1 ]; then echo "red-script:scripts/test-s62.sh"; exit 1; fi', { "ok1.txt", "ok2.txt" })
chk("b-flaky", line(o2, "^train:red:flaky ") and landed(o2, "^land:9[12] .*train=") == 2 and g2 == 2 and has(l2, "cause=red:rc=1:flaky "), o2, l2)
o2, r2, l2, g2 = arm62("arm62c", G62, { "ok1.txt", "ok2.txt" }, { trunk = "bad.txt" })
chk("c-trunk", line(o2, "^hold:trunk%-red:scripts/test%-s62%.sh ") and not line(o2, "^evict") and not line(o2, "^land:") and g2 == 2 and r2 == 4, o2, l2)
o2, r2, l2, g2, S2x = arm62("arm62d", 'if [ "$n" -eq 1 ]; then echo "red-script:scripts/test-actor62.sh"; exit 1; fi', { "ok1.txt", "ok2.txt" })
chk("d-actor", L:sh("[ -e " .. q(S2x.dir .. "/actor-ran") .. " ] || echo none") ~= "" and line(o2, "^train:red:rc=1:unjudged:")
    and landed(o2, "^land:9[12] ") == 2 and g2 == 3, o2, l2)
o2, r2, l2, g2 = arm62("arm62e", 'if [ "$n" -eq 1 ]; then echo "red-script:scripts/test-s62.sh"; exit 1; fi', { "ok1.txt", "ok2.txt" }, { trunk = "bad.txt" })
chk("e-not-confirmed", line(o2, "^train:red:rc=1:unjudged:scripts/test%-s62%.sh:red%-alone%-on%-trunk") and not line(o2, "^hold")
    and landed(o2, "^land:9[12] ") == 2, o2, l2)
o2, r2, l2, g2 = arm62("arm62f", '[ ! -e scripts/test-new62.sh ] || { echo "red-script:scripts/test-new62.sh"; exit 1; }', { "ok1.txt", "addstep", "ok3.txt" })
chk("f-adds-step", line(o2, "^train:red:culprit=#92 ") and landed(o2, "^land:9[13] .*train=") == 2, o2, l2)
o2, r2, l2, g2, S2x = arm62("arm62g", G62, { "ok1.txt", "bad.txt", "ok3.txt" }, { extra = { TILLANDSIAS_LAND_QUEUE_TRAIN_DIAGNOSE = "0" } })
chk("g-off", line(o2, "^train:red:rc=1 — ") and not has(o2, "culprit") and L:sh("[ -e " .. q(S2x.dir .. "/step-runs") .. " ] || echo none") ~= "" and g2 == 4, o2, l2)
o2, r2, l2, g2 = arm62("arm62h", G62 .. '; [ ! -e worse.txt ] || { echo "FAIL: something unnamed"; exit 1; }', { "bad.txt", "worse.txt", "ok3.txt" })
chk("h-second-red", landed(o2, "^train: ") == 2 and line(o2, "^train:red:culprit=#91 ") and line(o2, "^train:red:rc=1 — ") and line(o2, "^land:93 ")
    and landed(o2, "^evict:land%-queue:9[12]:") == 2, o2, l2)
arm("ARM 62: a red train is judged by its failing step: culprit leaves and the rest land, flake rides again, trunk red holds, and only a gate-run step is ever executed",
    #b62 == 0, table.concat(b62, " ") .. all62)

-- ARM 63: the REAL build.sh _run and _error print red-script:<path> once for a
-- script that exited 1 and was refused, and nothing for an advisory red, a
-- could-not-run (3) or a green.
local A63 = TMP .. "/arm63"
L:must("mkdir -p " .. q(A63 .. "/scripts"))
L:write(A63 .. "/scripts/test-s63.sh", 'exit "$1"\n')
L:must("{ printf 'SCRIPT_DIR=\"%s\"; RED=; NC=; _PHASE_WORK_MS=0\\n_require_host_build_tools() { :; }; _now_ms() { echo 0; }; _info() { :; }\\n' " .. q(A63) .. "\n"
    .. "  sed -n -e '/^_RED_SCRIPT=\"\"$/,/^}$/p' -e '/^_run() {$/,/^}$/p' " .. q(L.ROOT .. "/build.sh") .. "\n"
    .. "  printf '%s\\n' 't() { _run bash \"$SCRIPT_DIR/scripts/test-s63.sh\" \"$1\"; }' 't 1; _error refused; _error second' 'echo --; t 1; t 0; _error after-green'"
    .. " 'echo --; t 3; _error could-not-run' 'echo --; t 1; _info advisory'\n} > " .. q(A63 .. "/drv.sh"))
local o63 = L:sh("bash " .. q(A63 .. "/drv.sh") .. " 2>&1 | tr '\\n' '|'")
arm("ARM 63: build.sh names a refused script once as red-script:<path>, never an advisory, a could-not-run or a green one",
    o63 == "red-script:scripts/test-s63.sh|[build] refused|[build] second|--|[build] after-green|--|[build] could-not-run|--|", o63)

T:finish()
