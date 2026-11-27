-- @trace order:1316-bnzt, order:1765-q7rg, order:1839-fuvg, order:2398-zvug, spec:ci-release
-- inputs: methodology/convergence.yaml methodology/multi-host-development.yaml scripts/allocate-gate-step-prefix.sh scripts/attest-native-lint.sh scripts/build-sidecar.sh scripts/change-class.sh scripts/check-native-lint-attested.sh scripts/check-plan-binary-current.sh scripts/gate-changed.sh scripts/gate-stamp.sh scripts/land-on-platform-branch.sh scripts/land-queue.sh scripts/lib-freeze-paths.sh scripts/lua/check-carried-obligations.lua scripts/lua/land-queue-host-door.lua scripts/lua/shadow-intake.lua scripts/lua/test-land-queue-eviction-comment.lua scripts/plan-binary-probe.sh scripts/release-freeze.sh lib/lua/common/ crates/tillandsias-plan/
-- @env PATH HOME TMPDIR
--
-- test-land-queue-eviction.lua — scripts/land-queue.sh, arms 14-35 of the
-- former scripts/test-land-queue.sh (split by arm group, 2398-zvug): the
-- pre-gate checks and what an eviction costs. A stale evicted head is not
-- re-gated; a repeat conflict drafts the PR; the preflight door; the bounded
-- flaky retry; an aborted gate is not a verdict; the native-lint attestation;
-- a refused push says why; the plan-only race at push; kept gate logs; the
-- whole queue, not gh's first page; a stale plan binary is the host's state;
-- priority; re-rolled reds; lanes. Scaffold: lib/lua/common/land_queue_fixture.lua.
--
-- Usage: tillandsias-plan script run scripts/lua/test-land-queue-eviction.lua
-- Verdict: ok:land-queue-eviction:<n> arms | violation:land-queue-eviction:<n>-failed

local fixture = require "common.fixture"
local LQ = require "common.land_queue_fixture"
local T = fixture.new("land-queue-eviction")
for _, t in ipairs({ "git", "jq" }) do
    if not fixture.which(t) then T:skip("no-" .. t .. " — every arm drives the queue with it") end
end
if not fs.exists("scripts/land-queue.sh") then T:skip("no-queue-script") end
local L = LQ.new(T)
local q, has, line, caps, joined = LQ.q, LQ.has, LQ.line, LQ.caps, LQ.joined
local function arm(name, cond, got) T:arm(name, cond, got) end
local GREEN = "exit 0\n"
local LOGGED = 'echo "gated $(git rev-parse HEAD)" >> @GATE_LOG@\n'

-- trunk_push(S, file, content) — a commit straight onto the remote trunk, from
-- the lander clone, between queue runs.
local function trunk_push(S, file, content)
    local dir = file:match("^(.*)/[^/]*$")
    L:must("set -e\nW=" .. q(S.WORK) .. "\ngit -C \"$W\" checkout -q linux-next\ngit -C \"$W\" pull -q --ff-only origin linux-next\n"
        .. (dir and ("mkdir -p \"$W\"/" .. q(dir) .. "\n") or "") .. "printf '%s\\n' " .. q(content) .. " > \"$W\"/" .. q(file) .. "\n"
        .. "git -C \"$W\" add -A && git -C \"$W\" commit -q -m " .. q("trunk: " .. file) .. "\ngit -C \"$W\" push -q origin linux-next")
end
local function gates(S) return LQ.nlines(L:read(S.GATE_LOG)) end

-- ── ARM 14 — A HEAD THE QUEUE ALREADY EVICTED IS NOT RE-GATED OVER A
--            PLAN-ONLY TRUNK MOVE; A CODE MOVE OR A NEW HEAD IS.
local S = L:scaffold("stale")
L:candidate(S, "1401-aaaa", "a.txt", "A")
L:prs(S, { { 1, "work/1401-aaaa" } })
L:gate(S, LOGGED .. 'echo "violation:stub-gate:red"\nexit 1\n')
local oa = L:run_queue(S)
trunk_push(S, "plan/index.d/20261017t000000z-probe.yaml", "packets: []")
local ob = L:run_queue(S); local gb = gates(S)
trunk_push(S, "code.txt", "C")
local oc = L:run_queue(S); local gc = gates(S)
L:must("set -e\nW=" .. q(S.WORK) .. "\ngit -C \"$W\" checkout -q work/1401-aaaa\necho A2 > \"$W/a.txt\"; git -C \"$W\" commit -qam 'work(1401): new head'\n"
    .. "git -C \"$W\" push -q origin work/1401-aaaa; git -C \"$W\" checkout -q linux-next")
local od = L:run_queue(S); local gd = gates(S)
arm("ARM 14a: an evicted head over a PLAN-ONLY trunk move is skipped, no gate spent",
    line(oa, "^evict:land%-queue:1:gate%-failed") and L:read(S.GH_COMMENTS):find("land%-queue:evicted pr=1 head=[0-9a-f]* base=[0-9a-f]* reason=gate%-failed") ~= nil
    and line(ob, "^skip:land%-queue:1:stale%-head:.*classes=plan%-ledger") and gb == 1, "gates=" .. gb .. " " .. oa .. "\n---\n" .. ob)
arm("ARM 14b: the same head over a CODE trunk move is re-gated (NEGATIVE CONTROL)", gc == 2 and not has(oc, "stale-head"), "gates=" .. gc .. " " .. oc)
arm("ARM 14c: a CHANGED head is re-gated (NEGATIVE CONTROL)", gd == 3 and not has(od, "stale-head"), "gates=" .. gd .. " " .. od)

-- ── ARM 15 — THE SECOND IDENTICAL CONFLICT AT AN UNCHANGED HEAD DRAFTS THE PR.
S = L:scaffold("draft")
L:candidate(S, "1501-aaaa", "base.txt", "candidate-side")
L:prs(S, { { 1, "work/1501-aaaa" } })
L:gate(S, GREEN)
trunk_push(S, "base.txt", "trunk-side")
oa = L:run_queue(S); local da = LQ.nlines(L:read(S.GH_DRAFTS))
ob = L:run_queue(S); local db = LQ.nlines(L:read(S.GH_DRAFTS))
arm("ARM 15: the first conflict evicts, the second identical one at the same head drafts the PR and says so",
    line(oa, "^evict:land%-queue:1:conflict:base%.txt") and da == 0 and line(ob, "^draft:land%-queue:1:repeat%-conflict") and db == 1
    and line(L:read(S.GH_DRAFTS), "^1 %-%-undo$") and has(L:read(S.GH_COMMENTS), "converted this PR to a **draft**"),
    "drafts=" .. da .. "/" .. db .. " " .. oa .. "\n---\n" .. ob)

-- ── ARM 16 — THE PREFLIGHT DOOR EVICTS A DECIDER RED BEFORE THE GATE; A STALE
--            PLAN BINARY ON THE LANDER DOES NOT.
S = L:scaffold("door")
L:candidate(S, "1601-aaaa", "a.txt", "A")
L:prs(S, { { 1, "work/1601-aaaa" } })
L:gate(S, "echo gated >> @GATE_LOG@\nexit 0\n")
L:write(S.dir .. "/pf.sh", '#!/usr/bin/env bash\necho "violation:stub-decider:red"\nexit 1\n')
oa = L:run_queue(S, { PREFLIGHT_CMD = "bash " .. S.dir .. "/pf.sh" }); local ga = gates(S); local ca = L:read(S.GH_COMMENTS)
-- A fresh scaffold: the same head over an unchanged trunk would now (rightly)
-- be stale-skipped by arm 14's rule, and this arm is about the door.
local S2 = L:scaffold("door2")
L:candidate(S2, "1602-aaaa", "a.txt", "A")
L:prs(S2, { { 1, "work/1602-aaaa" } })
L:gate(S2, "echo gated >> @GATE_LOG@\nexit 0\n")
L:write(S2.dir .. "/pf.sh", '#!/usr/bin/env bash\necho "refused:preflight:stale-plan-binary — stub"\nexit 1\n')
ob = L:run_queue(S2, { PREFLIGHT_CMD = "bash " .. S2.dir .. "/pf.sh" }); gb = gates(S2)
arm("ARM 16a: a decider-level preflight red evicts with no full gate spent",
    line(oa, "^evict:land%-queue:1:preflight%-failed") and ga == 0 and has(ca, "violation:stub-decider:red") and has(ca, "reason=preflight-failed"),
    "gates=" .. ga .. " " .. oa)
arm("ARM 16b: a stale plan binary on the lander is not the candidate's red — the full gate decides (NEGATIVE CONTROL)",
    gb == 1 and line(ob, "^land:1 "), "gates=" .. gb .. " " .. ob)

-- ── ARM 17 — flaky: RE-QUEUES ONCE AT THE BACK; A SECOND flaky: EVICTS.
local function flaky_gate(S0, n)
    L:write(S0.dir .. "/flakes", n .. "\n")
    L:gate(S0, "echo gated >> @GATE_LOG@\nleft=\"$(cat " .. q(S0.dir .. "/flakes") .. ")\"\n"
        .. "if [ -f a.txt ] && [ \"$left\" -gt 0 ]; then\n    echo $((left - 1)) > " .. q(S0.dir .. "/flakes") .. "\n"
        .. "    echo \"flaky:240-900-z3kv.step:violation:x,violation:y\"\n    exit 1\nfi\nexit 0\n")
end
S = L:scaffold("flaky")
L:candidate(S, "1701-aaaa", "a.txt", "A")
L:candidate(S, "1702-bbbb", "b.txt", "B")
L:prs(S, { { 1, "work/1701-aaaa" }, { 2, "work/1702-bbbb" } })
flaky_gate(S, 1)
oa = L:run_queue(S)
arm("ARM 17a: a flaky: red re-queues ONCE at the back and then lands (order 2,1)",
    line(oa, "^requeue:land%-queue:1:flaky:240%-900%-z3kv%.step") and joined(oa, "^land:(%d+) ") == "2,1,", oa)
S = L:scaffold("flaky2")
L:candidate(S, "1701-aaaa", "a.txt", "A")
L:prs(S, { { 1, "work/1701-aaaa" } })
flaky_gate(S, 9)
ob = L:run_queue(S); gb = gates(S)
oc = L:run_queue(S); gc = gates(S)
local cm = L:read(S.GH_COMMENTS)
arm("ARM 17b: a second flaky: evicts, the comment names the token, and a flaky eviction is never stale-skipped",
    gb == 2 and line(ob, "^evict:land%-queue:1:gate%-failed:rc=1:flaky:") and has(cm, "reason=flaky") and line(cm, "^flaky:240%-900%-z3kv%.step")
    and gc == 4 and not has(oc, "stale-head"), "gates=" .. gb .. "/" .. gc .. " " .. ob .. "\n---\n" .. oc)

-- ── ARM 18 — A GATE THAT DIES (rc=255, the host going down) IS NOT A VERDICT.
-- ORDER 2234-a964: an aborted gate is could-not-run:host, posts NO eviction
-- comment, and is gated again on the next run, never stale-skipped.
S = L:scaffold("abort")
L:candidate(S, "1801-aaaa", "a.txt", "A")
L:prs(S, { { 1, "work/1801-aaaa" } })
L:gate(S, "echo gated >> @GATE_LOG@\nexit 255\n")
oa = L:run_queue(S)
trunk_push(S, "plan/index.d/20261017t000000z-probe.yaml", "packets: []")
ob = L:run_queue(S)
arm("ARM 18: an aborted gate (rc=255) is could-not-run:host, evicts and comments nobody, and is re-gated on the next run, never stale-skipped",
    not has(L:read(S.GH_COMMENTS), "land-queue:evicted") and has(oa, "could-not-run:host:gate-aborted:rc=255") and gates(S) == 2
    and not has(ob, "stale-head"), "gates=" .. gates(S) .. " " .. oa .. "\n---\n" .. ob)

-- ── ARM 19 — A CFG-GATED macOS CRATE LANDS ONLY WITH A NATIVE LINT (1235-rfub).
--   #1 unattested tray change -> EVICTED, the accountable host named, no gate;
--      an EXPORTED override must not excuse it
--   #2 a change outside the gated crate -> lands (NEGATIVE CONTROL)
--   #3 the same tray change with a Native-Lint trailer bound to its tree -> lands
--   #4 a tray change carrying `Native-Lint-Unattested: <reason>` -> lands as debt
S = L:scaffold("nlint")
local function tray(order, file, content, extra)
    L:must("set -e\nW=" .. q(S.WORK) .. "\ngit -C \"$W\" checkout -q -B " .. q("work/" .. order) .. " origin/linux-next\n"
        .. "mkdir -p \"$W/crates/tillandsias-macos-tray/src\"\nprintf '%s\\n' " .. q(content) .. " > \"$W/crates/tillandsias-macos-tray/src/\"" .. q(file) .. "\n"
        .. "git -C \"$W\" add -A\ngit -C \"$W\" commit -q -m " .. q("work(" .. order .. "): tray") .. (extra or ""))
end
tray("1901-aaaa", "action_host.rs", 'fn f() -> Result<(), String> { std::fs::read("x").map_err(|e| format!("{e}"))?; Ok(()) }')
L:git(S, "push", "-q", "origin", "work/1901-aaaa")
L:candidate(S, "1902-bbbb", "b.txt", "B")
tray("1903-cccc", "g.rs", "fn g() {}")
local t19 = L:rev(S.WORK, "HEAD:crates/tillandsias-macos-tray")
L:git(S, "commit", "-q", "--allow-empty", "-m", "native-lint: darwin ok (mac)", "--trailer",
    "Native-Lint: mac darwin crates/tillandsias-macos-tray=" .. t19 .. " clippy-all-targets-D-warnings")
L:git(S, "push", "-q", "origin", "work/1903-cccc")
tray("1904-dddd", "h.rs", "fn h() {}", " -m " .. q("Native-Lint-Unattested: no mac awake for the fixture"))
L:git(S, "push", "-q", "origin", "work/1904-dddd")
L:git(S, "checkout", "-q", "linux-next")
L:prs(S, { { 1, "work/1901-aaaa" }, { 2, "work/1902-bbbb" } })
L:gate(S, LOGGED .. "exit 0\n")
oa = L:run_queue(S, { extra = { TILLANDSIAS_NATIVE_LINT_UNATTESTED = "leaked from the caller" } }); ga = gates(S)
cm = L:read(S.GH_COMMENTS)
arm("ARM 19a: an unattested macOS-tray change is EVICTED before its gate, naming the accountable host; an exported override does not excuse it; a non-tray candidate lands",
    line(oa, "^evict:land%-queue:1:native%-lint%-unattested:tillandsias%-macos%-tray$") and line(oa, "^land:2 ") and not line(oa, "^land:1 ")
    and ga == 1 and has(cm, "Accountable: the authoring host") and has(cm, "reason=native-lint-unattested:tillandsias-macos-tray"),
    "gates=" .. ga .. " " .. oa .. " comments: " .. cm)
L:prs(S, { { 3, "work/1903-cccc" } })
ob = L:run_queue(S)
arm("ARM 19b: the tray change with a Native-Lint attestation bound to its tree lands (NEGATIVE CONTROL)", line(ob, "^land:3 "), ob)
L:prs(S, { { 4, "work/1904-dddd" } })
oc = L:run_queue(S)
L:git(S, "fetch", "-q", "origin", "linux-next")
local d19 = ""
for l in L:git(S, "log", "--first-parent", "--format=%s|%(trailers:key=Native-Lint-Unattested,valueonly)", "origin/linux-next"):gmatch("[^\n]+") do
    if l:match("^land%(4%)") then d19 = d19 .. l end
end
arm("ARM 19c: a candidate carrying Native-Lint-Unattested lands as named debt, repeated on the land commit",
    line(oc, "^land:4 ") and line(oc, "^debt:land%-queue:4:native%-lint%-unattested:") and has(d19, "no mac awake for the fixture"),
    "land commit: [" .. d19 .. "] " .. oc)

-- ── ARMS 20a-c (order 1839-fuvg)
-- 20a: a refused push says WHY: the remote's pre-receive refuses with a named
-- line; the queue output and the PR comment must carry it.
S = L:scaffold("push20a")
L:candidate(S, "2001-aaaa", "a.txt", "A")
L:prs(S, { { 1, "work/2001-aaaa" } })
L:write(S.REMOTE .. "/hooks/pre-receive", '#!/bin/sh\necho "refused:fixture-hook:named-refusal-line" >&2\nexit 1\n', true)
L:gate(S, GREEN)
oa = L:run_queue(S)
arm("ARM 20a: a refused push prints the push's own refusal line beside push-did-not-land and carries it in the PR comment",
    has(oa, "requeue:land-queue:1:push-did-not-land") and has(oa, "refused:fixture-hook:named-refusal-line")
    and has(L:read(S.GH_COMMENTS), "refused:fixture-hook:named-refusal-line"), oa .. " comments: " .. L:read(S.GH_COMMENTS))
-- 20b: the target gains a ledger fragment AFTER the queue's re-read and BEFORE
-- the push (a client pre-push hook plays the concurrent plan-lane push, once):
-- the queue must re-adopt and land, not re-queue for a full re-gate.
S = L:scaffold("push20b")
L:candidate(S, "2002-bbbb", "b.txt", "B")
L:prs(S, { { 2, "work/2002-bbbb" } })
L:gate(S, GREEN)
local O20 = L:other(S)
L:must("mkdir -p " .. q(S.WORK .. "/.git/hooks"))
L:write(S.WORK .. "/.git/hooks/pre-push", "#!/usr/bin/env bash\n"
    .. 'grep -q " refs/heads/linux-next " || exit 0  # 2248-jihs: race the TRUNK push, not the queue-status publish\n'
    .. "[ -e " .. q(S.dir .. "/raced") .. " ] && exit 0\n: > " .. q(S.dir .. "/raced") .. "\n"
    .. "mkdir -p " .. q(O20 .. "/plan/index.d") .. "\nprintf 'packets: []\\n' > " .. q(O20 .. "/plan/index.d/20261023t000000z-race-fuvg.yaml") .. "\n"
    .. "git -C " .. q(O20) .. " add -A\ngit -C " .. q(O20) .. " commit -q -m 'plan(race): a fragment lands between gate and push'\n"
    .. "git -C " .. q(O20) .. " push -q origin HEAD:linux-next\nexit 0\n", true)
ob = L:run_queue(S)
arm("ARM 20b: a push refused because a ledger fragment landed between gate and push is re-adopted and lands, with no re-gate",
    has(ob, "plan-only-move-at-push") and line(ob, "^land:2 "), ob)
-- 20c: an evicted candidate's gate log is KEPT at the path the evict line and
-- the PR comment name, holds the gate's output, and retention is bounded.
S = L:scaffold("log20c")
L:candidate(S, "2003-cccc", "c.txt", "C")
L:prs(S, { { 3, "work/2003-cccc" } })
L:gate(S, 'echo "FAIL: marker-gate-output-xyz"\nexit 1\n')
local LOGD = S.dir .. "/logs"
oc = L:run_queue(S, { LOGDIR = LOGD })
local kept = caps(oc, "^evict:land%-queue:3:.*kept at (.*)$")[1] or ""
arm("ARM 20c: the evicted candidate's full gate log exists at the path named in the evict line and the PR comment",
    kept ~= "" and has(L:read(kept), "marker-gate-output-xyz") and has(L:read(S.GH_COMMENTS), kept), "path=[" .. kept .. "] " .. oc)
for _ = 1, 4 do
    L:sh("sleep 1")
    L:run_queue(S, { LOGDIR = LOGD, extra = { TILLANDSIAS_LAND_QUEUE_LOG_KEEP = "2" } })
end
local nd = tonumber(text.trim((L:sh("ls -1d " .. q(LOGD) .. "/*/ 2>/dev/null | wc -l")))) or -1
arm("ARM 20c2: log retention is bounded to the newest N run directories (" .. nd .. " kept of 5 runs)", nd >= 1 and nd <= 2, nd)

-- ──────────────────────────────────────────────────────────── ARM 21
-- THE QUEUE READS THE WHOLE QUEUE, NOT gh's FIRST PAGE (1959-tdn5). A fake gh
-- that honours --limit the way the real one does (default 30, newest first)
-- over 31 open PRs where only the OLDEST is ready must still land it.
local function gh_paged(S0)
    L:write(S0.GH_BIN, "#!/usr/bin/env bash\ncase \"$1 $2\" in\n    \"pr list\")\n        lim=30\n"
        .. "        while [ $# -gt 0 ]; do\n            case \"$1\" in --limit) lim=\"$2\"; shift ;; --limit=*) lim=\"${1#*=}\" ;; esac\n            shift\n        done\n"
        .. "        # GH_PRS holds one PR object per line, newest first; gh pages from the top.\n"
        .. "        printf '['; head -n \"$lim\" " .. q(S0.GH_PRS) .. " | paste -sd, -; printf ']\\n' ;;\n"
        .. "    \"pr comment\") shift 2; printf '%s\\n' \"$*\" >> " .. q(S0.GH_COMMENTS) .. " ;;\n"
        .. "    \"pr view\")    printf '{\"comments\":[]}\\n' ;;\n    *) exit 1 ;;\nesac\n", true)
end
S = L:scaffold("arm21")
L:candidate(S, "2100-oldp", "old.txt", "OLD")
local rows = {}
for i = 31, 2, -1 do rows[#rows + 1] = string.format('{"number":%d,"headRefName":"work/%d-drft","isDraft":true}', i, 2100 + i) end
rows[#rows + 1] = '{"number":1,"headRefName":"work/2100-oldp","isDraft":false}'
L:write(S.GH_PRS, table.concat(rows, "\n") .. "\n")
gh_paged(S)
L:gate(S, GREEN)
local rc
oa, rc = L:run_queue(S)
arm("ARM 21: the oldest non-draft PR among 31 open ones lands — the queue asked gh for more than its first page",
    rc == 0 and line(oa, "^land:1 "), "rc=" .. tostring(rc) .. " " .. oa)
-- ARM 21b: a capture exactly as long as the limit may be truncated: REFUSE.
S = L:scaffold("arm21b")
rows = {}
for i = 600, 1, -1 do rows[#rows + 1] = string.format('{"number":%d,"headRefName":"work/%d-drft","isDraft":true}', i, 3000 + i) end
L:write(S.GH_PRS, table.concat(rows, "\n") .. "\n")
gh_paged(S)
L:gate(S, GREEN)
ob, rc = L:run_queue(S)
arm("ARM 21b: a capture as long as the list limit REFUSES instead of landing from a possibly truncated queue",
    has(ob, "fail:land-queue:queue-may-be-truncated") and rc ~= 0, "rc=" .. tostring(rc) .. " " .. ob)

-- ──────────────────────────────────────────────────────────── ARM 22
-- ORDER 1992-lqpb, amended by 2143-z5uj: A STALE PLAN BINARY IS THIS HOST'S
-- STATE, NOT THE CANDIDATE'S: that candidate is skipped (could-not-run:host),
-- evicts nobody, and the run CONTINUES. The refresh fails for the first only.
S = L:scaffold("arm22")
L:candidate(S, "1022-aaaa", "a22.txt", "A")
L:candidate(S, "1024-cccc", "c22.txt", "C")
L:prs(S, { { 22, "work/1022-aaaa" }, { 24, "work/1024-cccc" } })
L:gate(S, "echo gated >> @GATE_LOG@\nexit 0\n")
local m22 = S.dir .. "/refresh-failed-once"
oa, rc = L:run_queue(S, { PLAN_REFRESH_CMD = "if [ -e '" .. m22 .. "' ]; then exit 0; fi; : > '" .. m22 .. "'; echo stale-plan-binary >&2; exit 1" })
arm("ARM 22: a plan binary that cannot be refreshed skips THAT candidate (could-not-run:host:plan-binary-stale), evicts nobody, comments nothing, and the run lands the next (2143-z5uj)",
    line(oa, "^could%-not%-run:host:plan%-binary%-stale:#22:") and not line(oa, "^evict:") and line(oa, "^land:24 ") and not line(oa, "^land:22 ")
    and rc == 0 and gates(S) == 1 and L:read(S.GH_COMMENTS) == "",
    "rc=" .. tostring(rc) .. " gates=" .. gates(S) .. " " .. oa)
S = L:scaffold("arm22b")
L:candidate(S, "1023-bbbb", "b22.txt", "B")
L:prs(S, { { 23, "work/1023-bbbb" } })
L:gate(S, GREEN)
ob = L:run_queue(S, { PLAN_REFRESH_CMD = "true" })
arm("ARM 22b: a refresh that succeeds lets the candidate land", line(ob, "^land:23 "), ob)

-- ──────────────────────────────────────────────────────────── ARM 30
-- ORDER 2143-z5uj: THE QUEUE IS RE-READ BEFORE EVERY CANDIDATE. #3 is labelled
-- land:priority WHILE #1 GATES (the gate rewrites the list on its first call),
-- so #3 is gated next, before #2.
S = L:scaffold("arm30")
L:candidate(S, "1301-aaaa", "a30.txt", "A")
L:candidate(S, "1302-bbbb", "b30.txt", "B")
L:candidate(S, "1303-cccc", "c30.txt", "C")
L:prs(S, '[{"number":1,"headRefName":"work/1301-aaaa","isDraft":false,"labels":[]},\n {"number":2,"headRefName":"work/1302-bbbb","isDraft":false,"labels":[]},\n {"number":3,"headRefName":"work/1303-cccc","isDraft":false,"labels":[]}]\n')
L:write(S.dir .. "/prs-relabelled.json", '[{"number":2,"headRefName":"work/1302-bbbb","isDraft":false,"labels":[]},\n {"number":3,"headRefName":"work/1303-cccc","isDraft":false,"labels":[{"name":"land:priority"}]}]\n')
L:gate(S, "[ -s @GATE_LOG@ ] || cp " .. q(S.dir .. "/prs-relabelled.json") .. " @GH_PRS@\necho gated >> @GATE_LOG@\nexit 0\n")
oa = L:run_queue(S)
arm("ARM 30: a PR labelled land:priority while candidate 1 gated is gated next (1,3,2) — the queue is re-read per candidate (2143-z5uj)",
    joined(oa, "^land:(%d+) ") == "1,3,2,", oa)
S = L:scaffold("arm30b")
L:candidate(S, "1304-aaaa", "a30b.txt", "A")
L:candidate(S, "1305-bbbb", "b30b.txt", "B")
L:prs(S, '[{"number":4,"headRefName":"work/1304-aaaa","isDraft":false},\n {"number":5,"headRefName":"work/1305-bbbb","isDraft":false,"labels":[{"name":"land:priority"}]}]\n')
L:gate(S, GREEN)
ob = L:run_queue(S)
arm("ARM 30b: land:priority lands before a lower PR number", joined(ob, "^land:(%d+) ") == "5,4,", ob)

-- ──────────────────────────────────────────────────────────── ARM 31
-- land:hold replaces draft-as-hold: the held PR is never gated, and is NAMED.
S = L:scaffold("arm31")
L:candidate(S, "1311-aaaa", "a31.txt", "A")
L:candidate(S, "1312-bbbb", "b31.txt", "B")
L:prs(S, '[{"number":11,"headRefName":"work/1311-aaaa","isDraft":false,"labels":[{"name":"land:hold"}]},\n {"number":12,"headRefName":"work/1312-bbbb","isDraft":false,"labels":[]}]\n')
L:gate(S, "echo gated >> @GATE_LOG@\nexit 0\n")
oa = L:run_queue(S)
arm("ARM 31: a land:hold PR is named and never gated; the next PR lands",
    line(oa, "^hold:land%-queue:#11:") and not line(oa, "^land:11 ") and line(oa, "^land:12 ") and gates(S) == 1, "gates=" .. gates(S) .. " " .. oa)

-- ──────────────────────────────────────────────────────────── ARM 32
-- A RED IN A TEST THE CANDIDATE DID NOT TOUCH IS RE-RUN ONCE.
local FIRST = 'if [ "$(grep -c . @GATE_LOG@)" -eq 1 ]; then '
S = L:scaffold("arm32")
L:candidate(S, "1321-aaaa", "a32.txt", "A")
L:prs(S, { { 21, "work/1321-aaaa" } })
L:gate(S, "echo gated >> @GATE_LOG@\n" .. FIRST .. 'echo "FAIL scripts/test-other.sh: flaked"; exit 1; fi\nexit 0\n')
oa = L:run_queue(S)
arm("ARM 32: an untouched test red then green on the identical tree prints flaky:<test> and lands (2 gates)",
    line(oa, "^flaky:scripts/test%-other%.sh ") and line(oa, "^land:21 ") and not line(oa, "^evict") and gates(S) == 2, "gates=" .. gates(S) .. " " .. oa)
-- ARM 32b (2118-tpmy): red TWICE in the untouched test, trunk green: the trunk
-- check gates once more and evicts, naming evicted:<test>.
S = L:scaffold("arm32b")
L:candidate(S, "1322-aaaa", "a32b.txt", "A")
L:prs(S, { { 22, "work/1322-aaaa" } })
L:gate(S, 'echo gated >> @GATE_LOG@\nif [ -e a32b.txt ]; then echo "FAIL scripts/test-other.sh: real"; exit 1; fi\nexit 0\n')
oa = L:run_queue(S)
arm("ARM 32b: an untouched test red twice, trunk green, prints evicted:<test> and evicts (3 gates)",
    line(oa, "^evicted:scripts/test%-other%.sh ") and line(oa, "^evict:land%-queue:22:gate%-failed") and not line(oa, "^land:22 ") and gates(S) == 3,
    "gates=" .. gates(S) .. " " .. oa)
-- ARM 32c, NEGATIVE CONTROL: a red in a test the diff TOUCHES is judged on the
-- first run — a PR cannot re-roll its own red.
S = L:scaffold("arm32c")
L:candidate(S, "1323-aaaa", "scripts-test-mine.txt", "A")
L:must("set -e\nW=" .. q(S.WORK) .. "\ngit -C \"$W\" checkout -q work/1323-aaaa\nmkdir -p \"$W/scripts\"; printf 'x\\n' > \"$W/scripts/test-mine.sh\"\n"
    .. "git -C \"$W\" add -A; git -C \"$W\" commit -q -m mine; git -C \"$W\" push -q origin work/1323-aaaa\ngit -C \"$W\" checkout -q linux-next")
L:prs(S, { { 23, "work/1323-aaaa" } })
L:gate(S, "echo gated >> @GATE_LOG@\n" .. FIRST .. 'echo "FAIL scripts/test-mine.sh: mine"; exit 1; fi\nexit 0\n')
oa = L:run_queue(S)
arm("ARM 32c (control): a red in a test the diff touches evicts on the first run, no re-run",
    line(oa, "^evict:land%-queue:23:gate%-failed") and not line(oa, "^flaky:") and gates(S) == 1, "gates=" .. gates(S) .. " " .. oa)
-- ARM 32d, NEGATIVE CONTROL: a red that names NO test is never re-rolled.
S = L:scaffold("arm32d")
L:candidate(S, "1324-aaaa", "a32d.txt", "A")
L:prs(S, { { 24, "work/1324-aaaa" } })
L:gate(S, "echo gated >> @GATE_LOG@\n" .. FIRST .. 'echo "error: something broke"; exit 1; fi\nexit 0\n')
oa = L:run_queue(S)
arm("ARM 32d (control): a red naming no test evicts on the first run",
    line(oa, "^evict:land%-queue:24:gate%-failed") and gates(S) == 1, "gates=" .. gates(S) .. " " .. oa)
-- ARM 32e-g (2277-7trt): red-twice:<test>: says the step runner already ran
-- that step twice. (e) candidate-only red: no identical-tree re-run, trunk
-- asked once, evicted (2 gates). (f) trunk fails it too: hold, nobody evicted
-- (2 gates). (g) CONTROL: another untouched red beside it still re-runs (3).
local function rt(name, order, num, body)
    local S0 = L:scaffold(name)
    L:must("set -e\nW=" .. q(S0.WORK) .. "\nmkdir -p \"$W/scripts\"; echo " .. q("# " .. name) .. " > \"$W/scripts/test-hs.sh\"\n"
        .. "git -C \"$W\" add -A; git -C \"$W\" commit -q -m hs; git -C \"$W\" push -q origin linux-next")
    L:candidate(S0, order, "rt.txt", "A")
    L:prs(S0, { { num, "work/" .. order } })
    L:gate(S0, "echo gated >> @GATE_LOG@\n" .. body .. "\nexit 0\n")
    return L:run_queue(S0), gates(S0)
end
local RT = "echo 'red-twice:test-hs.sh:rc=1,rc=1'"
local o, g = rt("arm32e", "1325-aaaa", 25, "if [ -e rt.txt ]; then " .. RT .. "; exit 1; fi")
arm("ARM 32e: a red-twice red is not re-run; the trunk is asked once and the candidate is evicted (2 gates)",
    g == 2 and line(o, "^land%-queue: #25 red%-twice in scripts/test%-hs%.sh") and line(o, "^evict:land%-queue:25:gate%-failed")
    and not has(o, "re-running the gate once"), "gates=" .. g .. " " .. o)
o, g = rt("arm32f", "1326-aaaa", 26, RT .. "; exit 1")
arm("ARM 32f: a red-twice red the trunk shares holds the queue and evicts nobody (2 gates)",
    g == 2 and line(o, "^hold:trunk%-red:scripts/test%-hs%.sh ") and not line(o, "^evict"), "gates=" .. g .. " " .. o)
o, g = rt("arm32g", "1327-aaaa", 27, "if [ -e rt.txt ]; then " .. RT .. "; echo 'FAIL scripts/test-other.sh: x'; exit 1; fi")
arm("ARM 32g (control): a red-twice beside another untouched red still re-runs once (3 gates)",
    g == 3 and has(o, "re-running the gate once"), "gates=" .. g .. " " .. o)

-- ──────────────────────────────────────────────────────────── ARM 33
-- Operator ruling 2026-11-20: A PLAN-LEDGER-ONLY PR LANDS ON THE PLAN-LANE
-- CHECKS WITH ZERO BUILD-CHECK INVOCATIONS. 33b: the lane switched OFF.
local function plan_pr(S0, order, frag)
    L:must("set -e\nW=" .. q(S0.WORK) .. "\ngit -C \"$W\" checkout -q -B " .. q("work/" .. order) .. " origin/linux-next\nmkdir -p \"$W/plan/index.d\"\n"
        .. "printf 'packets: []\\n' > \"$W/plan/index.d/\"" .. q(frag) .. "\ngit -C \"$W\" add -A; git -C \"$W\" commit -q -m plan; git -C \"$W\" push -q origin "
        .. q("work/" .. order) .. "\ngit -C \"$W\" checkout -q linux-next")
end
S = L:scaffold("arm33")
plan_pr(S, "1331-aaaa", "20261120t000000z-arm33-yoga.yaml")
L:prs(S, { { 31, "work/1331-aaaa" } })
L:gate(S, "echo gated >> @GATE_LOG@\nexit 0\n")
oa = L:run_queue(S)
local pl = LQ.nlines(L:read(S.GATE_LOG .. ".plan-lane"))
arm("ARM 33: a plan-ledger-only PR lands with zero build-check invocations and one plan-lane check",
    line(oa, "^land:31 ") and has(oa, "lane=plan-only") and gates(S) == 0 and pl == 1, "gates=" .. gates(S) .. " plan-lane=" .. pl .. " " .. oa)
S = L:scaffold("arm33b")
plan_pr(S, "1332-aaaa", "20261120t000000z-arm33b-yoga.yaml")
L:prs(S, { { 32, "work/1332-aaaa" } })
L:gate(S, "echo gated >> @GATE_LOG@\nexit 0\n")
ob = L:run_queue(S, { extra = { TILLANDSIAS_LAND_QUEUE_PLAN_ONLY_LANE = "0" } })
arm("ARM 33b (control): TILLANDSIAS_LAND_QUEUE_PLAN_ONLY_LANE=0 sends the same PR through the full gate",
    line(ob, "^land:32 ") and gates(S) == 1, "gates=" .. gates(S) .. " " .. ob)

-- ──────────────────────────────────────────────────────────── ARM 34
-- 2118-tpmy THE HOST DOOR: could-not-run:host:<cause> evicts NOBODY and the run
-- goes on. The door refuses its first call (disk-low), then answers ok.
S = L:scaffold("arm34")
L:candidate(S, "1341-aaaa", "a34.txt", "A")
L:candidate(S, "1342-aaaa", "b34.txt", "B")
L:prs(S, { { 41, "work/1341-aaaa" }, { 42, "work/1342-aaaa" } })
L:gate(S, "echo gated >> @GATE_LOG@\nexit 0\n")
local DLOG = S.dir .. "/door.log"
L:write(S.dir .. "/door.sh", "#!/usr/bin/env bash\necho asked >> " .. q(DLOG) .. "\nif [ \"$(grep -c . " .. q(DLOG) .. ")\" -eq 1 ]; then\n"
    .. "    echo \"could-not-run:host:disk-low:3.0G free under target, floor 40G\"; exit 3\nfi\necho \"ok:host-door:disk=900G tmp=6.0G swap-free=90%\"\n")
local o34 = L:run_queue(S, { HOST_DOOR_CMD = "bash " .. S.dir .. "/door.sh" })
arm("ARM 34: a host-door refusal is could-not-run:host:<cause>, evicts nobody, and the run continues (#42 lands)",
    line(o34, "^could%-not%-run:host:disk%-low:.* #41 is not evicted") and not line(o34, "^evict") and not line(o34, "^land:41 ")
    and line(o34, "^land:42 ") and gates(S) == 1 and not has(L:read(S.GH_COMMENTS), "land-queue:evicted"), "gates=" .. gates(S) .. " " .. o34)
-- ARM 34b (2238-gpxz) WHERE THE WALL CLOCK GOES: one timing line per stage, in
-- order, for a landed candidate; none for one stopped at the door.
local st = {}
for l in o34:gmatch("[^\n]+") do
    local s = l:match("^timing:land%-queue:#42:([a-z+%-]*)=%d+s$")
    if s then st[#st + 1] = s end
end
arm("ARM 34b: a landed candidate times every stage in order; one stopped at the door times none",
    table.concat(st, " ") == "merge+door plan-refresh preflight gate post-gate+push" and not line(o34, "^timing:land%-queue:#41:"),
    table.concat(st, " ") .. " " .. o34)

-- ──────────────────────────────────────────────────────────── ARM 35
-- 2118-tpmy RED ON TRUNK TOO -> hold:trunk-red:<test>: nobody evicted, the
-- queue holds and #44 is not gated; a second run at the same trunk base reads
-- the memo and spends no trunk gate.
S = L:scaffold("arm35")
L:candidate(S, "1343-aaaa", "a35.txt", "A")
L:candidate(S, "1344-aaaa", "b35.txt", "B")
L:prs(S, { { 43, "work/1343-aaaa" }, { 44, "work/1344-aaaa" } })
L:gate(S, 'echo gated >> @GATE_LOG@\necho "FAIL scripts/test-other.sh: broken on trunk"; exit 1\n')
oa, rc = L:run_queue(S)
arm("ARM 35: red twice on the candidate AND on trunk is hold:trunk-red:<test>; nobody evicted; #44 not gated (3 gates)",
    line(oa, "^hold:trunk%-red:scripts/test%-other%.sh ") and not line(oa, "^evict") and not line(oa, "^evicted:") and line(oa, "^hold:land%-queue:")
    and gates(S) == 3 and not has(L:read(S.GH_COMMENTS), "land-queue:evicted"), "gates=" .. gates(S) .. " rc=" .. tostring(rc) .. " " .. oa)
L:write(S.GATE_LOG, "")
ob = L:run_queue(S)
arm("ARM 35b: at the same trunk base the trunk red is remembered: no trunk gate is spent again (2 gates)",
    line(ob, "^hold:trunk%-red:scripts/test%-other%.sh ") and gates(S) == 2 and not line(ob, "^evict"), "gates=" .. gates(S) .. " " .. ob)

T:finish()
