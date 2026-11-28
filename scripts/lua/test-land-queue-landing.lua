-- @trace order:1316-bnzt, order:2398-zvug, spec:ci-release
-- inputs: build.sh .gitignore methodology/convergence.yaml methodology/multi-host-development.yaml scripts/allocate-gate-step-prefix.sh scripts/attest-native-lint.sh scripts/build-sidecar.sh scripts/change-class.sh scripts/check-native-lint-attested.sh scripts/check-plan-binary-current.sh scripts/gate-changed.sh scripts/gate-stamp.sh scripts/land-on-platform-branch.sh scripts/land-queue.sh scripts/lib-freeze-paths.sh scripts/lua/check-carried-obligations.lua scripts/lua/land-queue-host-door.lua scripts/lua/shadow-intake.lua scripts/lua/test-land-queue-eviction-comment.lua scripts/plan-binary-probe.sh scripts/release-freeze.sh lib/lua/common/ crates/tillandsias-plan/
-- @env PATH HOME TMPDIR
--
-- test-land-queue-landing.lua — scripts/land-queue.sh, arms 1-13 of the former
-- scripts/test-land-queue.sh (split by arm group, 2398-zvug): the landing
-- order, eviction on a red gate and on a conflict, landing by ancestry, the
-- tree-that-gated rule, no local state, an unreadable queue, drafts, restoring
-- the caller's checkout, a stdin-hungry loop body, plan-only adoption, the
-- freeze, and carried obligations. The scaffold (a real bare remote, a real
-- clone, a fake gh, a stub gate) is lib/lua/common/land_queue_fixture.lua.
--
-- Usage: tillandsias-plan script run scripts/lua/test-land-queue-landing.lua
-- Verdict: ok:land-queue-landing:<n> arms | violation:land-queue-landing:<n>-failed

local fixture = require "common.fixture"
local LQ = require "common.land_queue_fixture"
local T = fixture.new("land-queue-landing")
for _, t in ipairs({ "git", "jq" }) do
    if not fixture.which(t) then T:skip("no-" .. t .. " — every arm drives the queue with it") end
end
if not fs.exists("scripts/land-queue.sh") then T:skip("no-queue-script") end
local L = LQ.new(T)
local q, has, line, caps, joined = LQ.q, LQ.has, LQ.line, LQ.caps, LQ.joined
local function arm(name, cond, got) T:arm(name, cond, got) end
local GREEN = "exit 0\n"

-- ──────────────────────────────────────────────────────────── ARM 1
-- THREE CANDIDATES LAND ONE AT A TIME IN PR-NUMBER ORDER.
local S = L:scaffold("arm1")
L:candidate(S, "1001-aaaa", "a.txt", "A")
L:candidate(S, "1002-bbbb", "b.txt", "B")
L:candidate(S, "1003-cccc", "c.txt", "C")
L:prs(S, { { 3, "work/1003-cccc" }, { 1, "work/1001-aaaa" }, { 2, "work/1002-bbbb" } })
L:gate(S, 'echo "gated $(git rev-parse HEAD)" >> @GATE_LOG@\nexit 0\n')
local out = L:run_queue(S)
local seen = joined(out, "^land:(%d+) ")
arm("ARM 1: three candidates landed one at a time in PR-NUMBER order (1,2,3), not the order gh listed them (3,1,2)",
    seen == "1,2,3,", "order '" .. seen .. "' " .. out)
-- AND THE TRUNK GREW BY EXACTLY THREE MERGES, each one an ancestor of the next:
-- a queue that landed three things in parallel would not produce a chain.
local n = text.trim(L:git(S, "rev-list", "--count", "--merges", "origin/linux-next"))
arm("ARM 1b: the remote trunk carries exactly 3 merge commits — a serialized chain, not a race", n == "3", n)

-- ──────────────────────────────────────────────────────────── ARM 2
-- A CANDIDATE WHOSE GATE FAILS IS EVICTED, ITS REFUSAL IS RECORDED ON THE PR,
-- AND THE QUEUE CONTINUES rather than aborting.
S = L:scaffold("arm2")
L:candidate(S, "2001-aaaa", "a.txt", "A")
L:candidate(S, "2002-bbbb", "b.txt", "B")
L:prs(S, { { 1, "work/2001-aaaa" }, { 2, "work/2002-bbbb" } })
-- Red for the first candidate only, keyed on the FILE the merge brought in --
-- not on the PR number, which the gate cannot see.
L:gate(S, 'if [ -f a.txt ] && [ ! -f b.txt ]; then echo "boom: a.txt is not acceptable"; exit 1; fi\nexit 0\n')
out = L:run_queue(S)
local ev = caps(out, "^evict:land%-queue:(%d+):gate%-failed")[1]
local land = caps(out, "^land:(%d+) ")[1]
local cmt = L:read(S.GH_COMMENTS)
arm("ARM 2: the red candidate was EVICTED with its refusal on PR #1, and the queue continued and landed #2",
    ev == "1" and land == "2" and cmt:find("1 %-%-body.*gate failed") ~= nil,
    "evict=" .. tostring(ev) .. " land=" .. tostring(land) .. " comments: " .. cmt .. " " .. out)

-- ──────────────────────────────────────────────────────────── ARM 3
-- A CANDIDATE THAT CONFLICTS WITH THE MOVED TARGET IS EVICTED WITH THE
-- CONFLICTING PATHS NAMED, and the queue continues.
S = L:scaffold("arm3")
L:candidate(S, "3001-aaaa", "shared.txt", "from-one")
L:candidate(S, "3002-bbbb", "shared.txt", "from-two")
L:candidate(S, "3003-cccc", "other.txt", "unrelated")
L:prs(S, { { 1, "work/3001-aaaa" }, { 2, "work/3002-bbbb" }, { 3, "work/3003-cccc" } })
L:gate(S, GREEN)
out = L:run_queue(S)
local conf = caps(out, "^evict:land%-queue:2:conflict:(.*)")[1] or ""
arm("ARM 3: the conflicting candidate was evicted NAMING shared.txt, and the queue continued to #3",
    has(conf, "shared.txt") and joined(out, "^land:(%d+) ") == "1,3,", "conflict='" .. conf .. "' " .. out)

-- ──────────────────────────────────────────────────────────── ARM 4
-- A LANDING PUSHES EXACTLY ONE MERGE COMMIT WHOSE SECOND PARENT IS THE PR HEAD,
-- so GitHub closes the PR by ancestry with no `gh pr merge` call.
S = L:scaffold("arm4")
L:candidate(S, "4001-aaaa", "a.txt", "A")
local head = L:rev(S.WORK, "origin/work/4001-aaaa")
L:prs(S, { { 7, "work/4001-aaaa" } })
L:gate(S, GREEN)
out = L:run_queue(S)
local p2 = L:rev(S.WORK, "origin/linux-next^2")
n = text.trim(L:git(S, "rev-list", "--count", "--merges", "origin/linux-next"))
arm("ARM 4: exactly one merge landed and its SECOND PARENT is the PR head — the PR closes by ancestry",
    p2 == head and n == "1", n .. " merge(s), second parent '" .. p2 .. "' want " .. head)
arm("ARM 4b: no gh pr merge call was made", not has(L:read(S.GH_COMMENTS), "pr merge"), L:read(S.GH_COMMENTS))

-- ──────────────────────────────────────────────────────────── ARM 5
-- THE TREE THAT SHIPS MUST BE THE TREE THAT GATED. The target moves DURING the
-- gate, from inside the stub gate, the only window where the defect lives.
-- Disabling the queue's comparison does NOT land a stale tree (git rejects the
-- push as a non-fast-forward); this pins that the queue DISTINGUISHES the
-- ordinary race (`target-moved`, no push attempted) from `push-did-not-land`,
-- the line a blocked credential helper and a lost network also produce.
S = L:scaffold("arm5")
L:candidate(S, "5001-aaaa", "a.txt", "A")
L:prs(S, { { 1, "work/5001-aaaa" } })
local OTHER = L:other(S)
L:gate(S, "# Another host lands while this candidate is gating.\n"
    .. "echo moved > " .. q(OTHER .. "/moved.txt") .. "\n"
    .. "git -C " .. q(OTHER) .. " add -A\ngit -C " .. q(OTHER) .. " commit -q -m 'another host'\n"
    .. "git -C " .. q(OTHER) .. " push -q origin HEAD:linux-next\nexit 0\n")
local before = L:rev(S.WORK, "origin/linux-next")
out = L:run_queue(S)
L:git(S, "fetch", "-q", "origin", "linux-next")
local after = L:rev(S.WORK, "origin/linux-next")
local other = L:rev(OTHER, "HEAD")
local rq = line(out, "^requeue:land%-queue:1:target%-moved")
-- THE PREMISE, ASSERTED BEFORE ANY VERDICT IS READ: when the mover did not move
-- the target, the queue landing the candidate is CORRECT behaviour.
if other == "" or other == before then
    LQ.skip("ARM 5", "COULD NOT RUN — the mover never moved the target (before=" .. before .. " other=" .. other .. ")")
else
    arm("ARM 5: the target moved DURING the gate, so the candidate was RE-QUEUED and nothing was pushed — trunk carries only the other host's commit",
        rq and after == other, "requeue=" .. tostring(rq) .. " before=" .. before .. " after=" .. after .. " other=" .. other .. " " .. out)
end
-- ARM 5b, THE NEGATIVE CONTROL: with the target NOT moving, the same scaffold lands.
L:gate(S, GREEN)
out = L:run_queue(S)
arm("ARM 5b (control): with a target that does NOT move, the same candidate lands — arm 5 is detecting the move, not refusing everything",
    has(out, "land:1 "), out)

-- ──────────────────────────────────────────────────────────── ARM 6
-- THE QUEUE KEEPS NO LOCAL STATE: the next run re-derives the queue from
-- `gh pr list`; nothing but the lock is written under .git.
S = L:scaffold("arm6")
L:candidate(S, "6001-aaaa", "a.txt", "A")
L:candidate(S, "6002-bbbb", "b.txt", "B")
L:prs(S, { { 1, "work/6001-aaaa" }, { 2, "work/6002-bbbb" } })
L:gate(S, GREEN)
L:run_queue(S, nil, "--limit", "1")
-- The remote is now the only record; remove #1 the way GitHub would once its PR closed.
L:prs(S, { { 2, "work/6002-bbbb" } })
out = L:run_queue(S)
local stray = text.trim((L:sh("find " .. q(S.WORK .. "/.git") .. " -maxdepth 1 -name 'tillandsias-land-queue*' 2>/dev/null")))
land = caps(out, "^land:(%d+) ")[1]
arm("ARM 6: the second run re-derived the queue from gh and landed #2, leaving no queue state under .git",
    land == "2" and stray == "", "land=" .. tostring(land) .. " stray=" .. stray .. " " .. out)

-- ──────────────────────────────────────────────────────────── ARM 7
-- AN EMPTY CAPTURE FROM gh IS NOT AN EMPTY QUEUE.
S = L:scaffold("arm7")
L:write(S.GH_BIN, "#!/usr/bin/env bash\nexit 4\n", true)
local rc
out, rc = L:run_queue(S)
arm("ARM 7: a gh that fails REFUSES (rc != 0) instead of reporting an empty queue",
    has(out, "fail:land-queue:cannot-read-queue") and rc ~= 0, "rc=" .. tostring(rc) .. " " .. out)
-- ARM 7b: a well-formed EMPTY list really is an empty queue, and must not refuse.
S = L:scaffold("arm7b")
L:prs(S, "[]\n")
out, rc = L:run_queue(S)
arm("ARM 7b: a well-formed empty list is an empty queue and exits 0 — the refusal in 7 is about the FAILURE, not about emptiness",
    has(out, "ok:land-queue:0 "), "rc=" .. tostring(rc) .. " " .. out)
-- ARM 7c (2100-vkpg): A QUEUE OF ONLY DRAFTS LANDS NOTHING AND SAYS WHICH DRAFTS IT PASSED OVER.
S = L:scaffold("arm7c")
L:prs(S, { { 196, "work/1375-amye", true }, { 42, "work/7001-aaaa", true } })
out, rc = L:run_queue(S)
arm("ARM 7c: every ignored draft is named, and a drafts-only queue still exits 0 as empty",
    has(out, "advisory:land-queue:ignored-draft:#42:work/7001-aaaa") and has(out, "advisory:land-queue:ignored-draft:#196:work/1375-amye")
    and has(out, "ok:land-queue:0 ") and rc == 0, "rc=" .. tostring(rc) .. " " .. out)

-- ──────────────────────────────────────────────────────────── ARM 8
-- THE INVOKING CHECKOUT IS PUT BACK WHERE IT WAS. Both starting states take
-- different code paths: from a branch the restore is by name; from a detached
-- HEAD `rev-parse --abbrev-ref HEAD` yields the literal "HEAD".
S = L:scaffold("arm8")
L:candidate(S, "8001-aaaa", "a.txt", "A")
L:prs(S, { { 1, "work/8001-aaaa" } })
L:gate(S, GREEN)
L:git(S, "checkout", "-q", "linux-next")
local b0 = text.trim(L:git(S, "rev-parse", "--abbrev-ref", "HEAD"))
L:run_queue(S)
local b1 = text.trim(L:git(S, "rev-parse", "--abbrev-ref", "HEAD"))
arm("ARM 8a: invoked from a branch, the queue left the caller on '" .. b0 .. "'", b1 == b0, b1)
-- 8b — from a DETACHED HEAD: the caller keeps their COMMIT. The detach point is
-- the trunk's PARENT, somewhere the queue would not leave HEAD anyway (the first
-- .sh version detached at the tip and passed against the broken restore).
S = L:scaffold("arm8b")
L:candidate(S, "8002-bbbb", "b.txt", "B")
L:prs(S, { { 1, "work/8002-bbbb" } })
L:gate(S, GREEN)
L:run_queue(S)
L:git(S, "fetch", "-q", "origin", "linux-next")
L:git(S, "checkout", "-q", "--detach", "origin/linux-next^1")
local d0 = L:rev(S.WORK, "HEAD")
local tip = L:rev(S.WORK, "origin/linux-next")
L:candidate(S, "8003-cccc", "c.txt", "C")
L:git(S, "checkout", "-q", "--detach", d0)
L:prs(S, { { 2, "work/8003-cccc" } })
L:run_queue(S)
local d1 = L:rev(S.WORK, "HEAD")
if d0 == tip then
    LQ.skip("ARM 8b", "COULD NOT RUN — the detach point equals the trunk tip")
else
    arm("ARM 8b: invoked from a DETACHED HEAD, the queue left the caller on the same commit", d1 == d0,
        "started " .. d0:sub(1, 9) .. " left at " .. d1:sub(1, 9))
end

-- ──────────────────────────────────────────────────────────── ARM 9
-- A GATE THAT READS STDIN MUST NOT EAT THE CANDIDATE LIST. The first candidate
-- FAILS its gate, so pr_comment (the only stdin-inheriting reader in the loop)
-- runs while three candidates are still unread, and the fake gh DRAINS STDIN
-- too. If the list is on stdin, gh eats the remainder; on fd 3, all process.
-- BOUNDED, because the defect's failure mode is a hang: a timeout is this
-- arm's own named failure. The run gets its own stdin (1809-iexe).
S = L:scaffold("arm9")
L:candidate(S, "9000-fail", "fail.txt", "F")
L:candidate(S, "9001-aaaa", "a.txt", "A")
L:candidate(S, "9002-bbbb", "b.txt", "B")
L:candidate(S, "9003-cccc", "c.txt", "C")
L:prs(S, { { 1, "work/9000-fail" }, { 2, "work/9001-aaaa" }, { 3, "work/9002-bbbb" }, { 4, "work/9003-cccc" } })
L:gate(S, "# A gate that drains stdin, exactly as ./build.sh --check does.\ncat >/dev/null 2>&1 || true\n[ -f fail.txt ] && exit 1\nexit 0\n")
L:fake_gh(S, "cat >/dev/null 2>&1 || true\n")
local ghs = L:read(S.GH_BIN)
local l2 = ghs:match("^[^\n]*\n([^\n]*)\n")
if l2 ~= "cat >/dev/null 2>&1 || true" or not ghs:find("^#!/usr/bin/env bash\n") then
    arm("ARM 9 SETUP: the stdin-hungry gh stub was built", false, ghs:sub(1, 120))
end
out, rc = L:sh("cd " .. q(S.WORK) .. " && timeout 120 env TILLANDSIAS_LAND_QUEUE_GH=" .. q(S.GH_BIN)
    .. " TILLANDSIAS_LAND_QUEUE_GATE=" .. q("bash " .. S.GATE_BIN)
    .. " TILLANDSIAS_LAND_QUEUE_PLAN_REFRESH= TILLANDSIAS_LAND_QUEUE_HOST_DOOR= TILLANDSIAS_LAND_QUEUE_SIDECAR_STAGE="
    .. " TILLANDSIAS_LAND_QUEUE_REMOTE=origin TILLANDSIAS_TRUNK_BRANCH=linux-next bash " .. q(L.QUEUE) .. " </dev/null 2>&1")
if rc == 124 then
    arm("ARM 9: the queue did not BLOCK with a stdin-consuming gate and gh", false,
        "timeout 120s — the candidate list is being read on stdin and a reader in the loop is waiting on it")
else
    local n9 = joined(out, "^land:(%d+) ")
    arm("ARM 9: an evicting first candidate runs pr_comment (stdin-hungry gh) with three candidates still unread, and all three are still processed — the list is read on fd 3, not stdin",
        has(out, "ok:land-queue:4 ") and n9 == "2,3,4,", "landed '" .. n9 .. "' " .. LQ.tail(out, 3))
end

-- ─────────────────────────────────────────────────────────── ARM 10
-- A PLAN-ONLY TRUNK MOVE IS ADOPTED; ANY OTHER MOVE STILL RE-QUEUES. THE PAIR
-- IS THE ARM: only both together distinguish a CLASSIFIER from a policy.
S = L:scaffold("adopt")
L:candidate(S, "1001-plan", "a.txt", "A")
L:prs(S, { { 1, "work/1001-plan" } })
OTHER = L:other(S)
L:gate(S, "mkdir -p " .. q(OTHER .. "/plan/index.d") .. "\nprintf 'packets: []\\n' > "
    .. q(OTHER .. "/plan/index.d/20260922t000000z-probe-yoga.yaml") .. "\ngit -C " .. q(OTHER) .. " add -A\ngit -C " .. q(OTHER)
    .. " commit -q -m 'plan(probe): a fragment lands mid-gate'\ngit -C " .. q(OTHER) .. " push -q origin HEAD:linux-next\nexit 0\n")
out = L:run_queue(S)
arm("ARM 10a: a PLAN-ONLY trunk move mid-gate is ADOPTED and the candidate lands",
    has(out, "adopt:land-queue:1:plan-only-move") and has(out, "land:1 "), LQ.tail(out, 3))
S = L:scaffold("noadopt")
L:candidate(S, "1002-code", "b.txt", "B")
L:prs(S, { { 2, "work/1002-code" } })
local OTHER2 = L:other(S)
L:gate(S, "mkdir -p " .. q(OTHER2 .. "/crates/x/src") .. "\nprintf 'fn main() {}\\n' > " .. q(OTHER2 .. "/crates/x/src/main.rs")
    .. "\ngit -C " .. q(OTHER2) .. " add -A\ngit -C " .. q(OTHER2) .. " commit -q -m 'fix(probe): a CRATE lands mid-gate'\ngit -C "
    .. q(OTHER2) .. " push -q origin HEAD:linux-next\nexit 0\n")
out = L:run_queue(S)
arm("ARM 10b: a move touching crates/ still RE-QUEUES — the change is a CLASSIFIER, not a decision to stop checking",
    has(out, "requeue:land-queue:2:target-moved") and not has(out, "adopt:land-queue:2"), LQ.tail(out, 3))

-- ──────────────────────────────────────────────────────────── ARM 11
-- A FROZEN TARGET HOLDS CODE, and the queue asks ORIGIN itself (1255-s4im).
-- Held BEFORE the gate: no gate is spent. 11b, the NEGATIVE CONTROL: a
-- plan-only candidate under the same live freeze lands.
S = L:scaffold("arm11")
L:candidate(S, "1101-aaaa", "a.txt", "A")
L:prs(S, { { 1, "work/1101-aaaa" } })
L:gate(S, "echo gated >> @GATE_LOG@\nexit 0\n")
local frozen = L:rev(S.WORK, "origin/linux-next")
L:git(S, "push", "-q", "origin", frozen .. ":refs/tillandsias/freeze/linux-next/fixture/1700000000")
out = L:run_queue(S)
L:git(S, "fetch", "-q", "origin", "linux-next")
after = L:rev(S.WORK, "origin/linux-next")
arm("ARM 11: a code candidate into a frozen trunk is HELD before the gate (gate not run, trunk unchanged), naming the marker",
    line(out, "^hold:land%-queue:1:frozen:refs/tillandsias/freeze/linux%-next/fixture/1700000000") and after == frozen
    and L:read(S.GATE_LOG) == "", "gate=" .. L:read(S.GATE_LOG) .. " after=" .. after .. " frozen=" .. frozen .. " " .. out)
L:must("set -e\nW=" .. q(S.WORK) .. "\ngit -C \"$W\" checkout -q -B work/1102-bbbb origin/linux-next\nmkdir -p \"$W/plan/index.d\"; echo 'x: 1' > \"$W/plan/index.d/frag.yaml\"\n"
    .. "git -C \"$W\" add -A && git -C \"$W\" commit -q -m 'work(1102-bbbb): plan only'\ngit -C \"$W\" push -q origin work/1102-bbbb\ngit -C \"$W\" checkout -q linux-next")
L:prs(S, { { 2, "work/1102-bbbb" } })
out = L:run_queue(S)
arm("ARM 11b (control): a plan-only candidate lands under the same live freeze — the hold is about held paths, not about the freeze existing",
    has(out, "land:2 "), out)

-- ──────────────────────────────────────────────────────────── ARM 12
-- A FREEZE SET WHILE THE CANDIDATE GATES IS NOT PUSHED THROUGH: the queue
-- re-asks at push. The stub gate sets the freeze, exactly where the window is.
S = L:scaffold("arm12")
L:candidate(S, "1201-aaaa", "a.txt", "A")
L:prs(S, { { 1, "work/1201-aaaa" } })
before = L:rev(S.WORK, "origin/linux-next")
L:gate(S, "git --git-dir=@REMOTE@ update-ref refs/tillandsias/freeze/linux-next/cut/1700000001 " .. q(before) .. "\nexit 0\n")
out = L:run_queue(S)
L:git(S, "fetch", "-q", "origin", "linux-next")
after = L:rev(S.WORK, "origin/linux-next")
arm("ARM 12: a freeze set DURING the gate is honoured at push — re-queued, nothing pushed, the marker named",
    line(out, "^requeue:land%-queue:1:frozen%-mid%-gate:refs/tillandsias/freeze/linux%-next/cut/1700000001") and after == before,
    "before=" .. before .. " after=" .. after .. " " .. out)
-- ARM 12b, NEGATIVE CONTROL: the same scaffold with the freeze cleared lands.
L:must("git --git-dir=" .. q(S.REMOTE) .. " update-ref -d refs/tillandsias/freeze/linux-next/cut/1700000001")
L:gate(S, GREEN)
out = L:run_queue(S)
arm("ARM 12b (control): with no freeze the same candidate lands — arm 12 detects the freeze, not refusing everything",
    has(out, "land:1 "), out)

-- ──────────────────────────────────────────────────────────── ARM 13
-- EVERY LANDING RECORDS WHAT IT OWED ITS CARRIED OBLIGATIONS (1577-568c): one
-- `Carried: <backlog> <state> [<item-or-reason>]` trailer per backlog on the
-- land commit, read from the guard on the merged tree.
S = L:scaffold("arm13")
L:must("set -e\nW=" .. q(S.WORK) .. "\nmkdir -p \"$W/methodology\" \"$W/scripts\"\ncp " .. q(L.ROOT .. "/methodology/convergence.yaml")
    .. " \"$W/methodology/\"\nprintf '#!/usr/bin/env bash\\necho ok:x\\n' > \"$W/scripts/check-x.sh\"\nprintf '.cache/\\n' > \"$W/.gitignore\"\n"
    .. "git -C \"$W\" add -A && git -C \"$W\" commit -q -m 'the rule and one decider'\ngit -C \"$W\" push -q origin linux-next")
L:candidate(S, "1301-aaaa", "notes.txt", "not in the area")
L:candidate(S, "1302-bbbb", "scripts/check-x.sh", "#!/usr/bin/env bash\necho ok:x2")
L:candidate(S, "1303-cccc", "scripts/check-x.sh", "#!/usr/bin/env bash\necho ok:x3", "Carried-Waiver: shell-to-lua no-item-in-reach")
L:prs(S, { { 1, "work/1301-aaaa" }, { 2, "work/1302-bbbb" }, { 3, "work/1303-cccc" } })
L:gate(S, 'echo "gated $(git rev-parse HEAD)" >> @GATE_LOG@\nexit 0\n')
out = L:run_queue(S)
L:git(S, "fetch", "-q", "origin", "linux-next")
local tr = L:git(S, "log", "--first-parent", "--format=%s|%(trailers:key=Carried,valueonly,separator=;)", "origin/linux-next")
-- carried_of(subject) -> that land commit's entries, one per backlog.
local function carried_of(subject)
    for l in tr:gmatch("[^\n]+") do
        if l:sub(1, #subject) == subject then
            local r = {}
            for e in l:sub(#subject + 2):gmatch("[^;]+") do r[#r + 1] = e end
            return r
        end
    end
    return {}
end
local function contains(list, v) for _, x in ipairs(list) do if x == v then return true end end return false end
local c1 = carried_of("land(1): work/1301-aaaa into linux-next")
arm("ARM 13a: a not-due candidate lands with 'Carried: shell-to-lua not-due'", contains(c1, "shell-to-lua not-due"), tr .. out)
arm("ARM 13b: a due candidate carrying a Carried-Waiver trailer lands with 'Carried: shell-to-lua waived no-item-in-reach'",
    contains(carried_of("land(3): work/1303-cccc into linux-next"), "shell-to-lua waived no-item-in-reach"), tr .. out)
-- ARM 13d: one Carried entry per backlog in the REAL convergence.yaml.
local nb, inb = 0, false
for l in (fs.read("methodology/convergence.yaml") or ""):gmatch("[^\n]*") do
    if l:match("^  backlogs:") then inb = true
    elseif inb and l:match("^[^ ]") then inb = false
    elseif inb and l:match("^    %- name: ") then nb = nb + 1 end
end
arm("ARM 13d: the land trailer carries one entry per backlog (" .. #c1 .. " of " .. nb .. " in convergence.yaml)",
    nb >= 1 and #c1 == nb, tr)
-- ARM 13c: the due, SILENT candidate is evicted before any gate runs, the
-- trailer line to add is on stdout and in the PR comment, and it never lands.
local cm = L:read(S.GH_COMMENTS)
arm("ARM 13c: a due, silent candidate is EVICTED as carried-silent before its gate, with the waiver line on stdout and on the PR",
    line(out, "^evict:land%-queue:2:carried%-silent:shell%-to%-lua$") and has(out, "Carried-Waiver: shell-to-lua <reason>")
    and line(cm, "^2 %-%-body Evicted") and line(cm, "^Carried%-Waiver: shell%-to%-lua") and not line(tr, "^land%(2%)")
    and LQ.nlines(L:read(S.GATE_LOG)) == 2, "gates=" .. LQ.nlines(L:read(S.GATE_LOG)) .. " " .. out .. " comments: " .. cm)

T:finish()
