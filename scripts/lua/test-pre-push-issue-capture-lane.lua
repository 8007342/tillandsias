-- @trace order:889-twhe, order:881-29me, order:863-iicc, order:1507-e693, order:2212-2m8s
-- @env CARGO_TARGET_DIR
--
-- test-pre-push-issue-capture-lane.lua — PORTED from
-- test-pre-push-issue-capture-lane.sh (2212-2m8s), same arms, same lines. Pins
-- that the pre-push plan-only lane admits NEW plan/issues captures, and every
-- boundary of that admission; plus the plan/deslop-sweeps.d (1141-f5nk) and
-- plan/inbox/ mailbox (1507-e693) arms.
--
-- WHY IT IS NARROW. The coordinator's ruling attached four conditions:
--   (a) NEW files only — arms 1, 3
--   (b) validated in the lane by check-issue-citation-convention — arms 2, 6
--   (c) explicit depth + prose guards — arms 4, 5, 7
--   (d) A NEGATIVE CONTROL: a malformed capture must FALL BACK to the full
--       gate — arm 2, the one that matters.
-- Several arms say in their own comment that they pass in both states and only
-- mean something next to their sibling (1c, 1f); that caveat is kept.
--
-- HEAD: the hook runs in a scratch repo under target/plan-scratch with its own
-- origin, never against the real checkout's HEAD (2196-rdec: clean by
-- construction). The runner scrubs CARGO_TARGET_DIR from children, and the
-- hook resolves its validator through it inside a forge or the builder
-- toolbox, so it is forwarded to every child when set (the .sh inherited it).
-- TILLANDSIAS_PLAN_BIN passes through as before; arm 8 sets it, as the .sh
-- exported it there.
--
-- Verdict: after the .sh's summary line, ok:issue-capture-lane:<n> |
-- violation:issue-capture-lane:<f> | skip:issue-capture-lane:no-validator

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local pass, fail = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) log.raw("FAIL: " .. m); fail = fail + 1 end
local function has(s, p) return (s or ""):find(p, 1, true) ~= nil end
local function first_with(s, pats)
    for _, l in ipairs(text.lines(s or "")) do
        for _, p in ipairs(pats) do if l:find(p, 1, true) then return l end end
    end
    return ""
end
-- 1060-7mmm: ANY "not applicable" is a disqualification.
local function lane_qualified(s) return not has(s, "plan-only lane: not applicable") end

local rel = "target/plan-scratch/prepush-issue-lane-" .. tostring(time.now_ms())
local W = root .. "/" .. rel
local WC = W .. "/wc"
proc.run{ argv = { "mkdir", "-p", W } }
local function cleanup() proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 } end

local CTD = env.get("CARGO_TARGET_DIR")
local HENV = { GIT_TERMINAL_PROMPT = "0" }
if CTD and CTD ~= "" then HENV.CARGO_TARGET_DIR = CTD end

local function G(args)
    local a = { "git", "-c", "user.email=t@t", "-c", "user.name=t" }
    for _, x in ipairs(args) do a[#a + 1] = x end
    return proc.run{ argv = a, cwd = WC, env = HENV, timeout_ms = 120000 }
end
local function put(path, body) fs.write(rel .. "/wc/" .. path, body) end
local function append(path, body)
    local p = rel .. "/wc/" .. path
    put(path, (fs.exists(p) and fs.read(p) or "") .. body)
end
local function commit(msg) G({ "add", "-A" }); G({ "commit", "-q", "-m", msg }) end
local function mkdirs(...)
    local a = { "mkdir", "-p" }
    for _, x in ipairs({ ... }) do a[#a + 1] = WC .. "/" .. x end
    proc.run{ argv = a }
end

proc.run{ argv = { "git", "init", "-q", "--bare", W .. "/bare.git" } }
proc.run{ argv = { "git", "init", "-q", "-b", "linux-next", WC } }
G({ "remote", "add", "origin", W .. "/bare.git" })
-- core.hooksPath is GLOBAL and OVERRIDES .git/hooks — pin it per scratch repo.
G({ "config", "core.hooksPath", ".git/hooks" })
mkdirs("scripts/hooks", "plan/issues", "plan/index.d")
proc.run{ argv = { "cp", "scripts/hooks/pre-push-local-gate.sh", WC .. "/scripts/hooks/pre-push-local-gate.sh" } }
proc.run{ argv = { "cp", "scripts/check-issue-citation-convention.sh", WC .. "/scripts/check-issue-citation-convention.sh" } }
for _, f in ipairs({ "plan-binary-probe.sh", "gate-stamp.sh", "common.sh" }) do
    if fs.exists("scripts/" .. f) then proc.run{ argv = { "cp", "scripts/" .. f, WC .. "/scripts/" .. f } } end
end
proc.run{ argv = { "find", WC .. "/scripts", "-name", "*.sh", "-exec", "chmod", "+x", "{}", "+" } }
put("plan/index.yaml", "packets: []\n")
put("plan/issues/existing.md", "base\n")
put("plan/issues/linux-next-work-queue-2026-05-25.md", "- 2026-09-01 macuahuitl: See `main.rs` `resolve_probe`.\n")
commit("base")
G({ "push", "-q", "-u", "origin", "linux-next" })

-- PRECONDITION (889-twhe, 1058-fenk): resolve the validator from the CHECKOUT
-- and RUN it; the bit is a claim, running it is evidence.
fs.write(rel .. "/resolve.sh", ". scripts/plan-binary-probe.sh && resolve_plan_binary\n")
local probe = text.trim(proc.run{ argv = { "bash", W .. "/resolve.sh" }, env = HENV }.stdout or "")
if probe:sub(1, 2) == "./" then probe = root .. "/" .. probe:sub(3)
elseif probe ~= "" and probe:sub(1, 1) ~= "/" then probe = root .. "/" .. probe end
local why = ""
if probe ~= "" then
    local r = proc.run{ argv = { probe, "capabilities" }, env = HENV }
    if not r.ok then why = text.trim(r.stderr or ""); probe = "" end
else
    -- RECOVER THE REASON from a file sitting at the conventional path.
    for _, cand in ipairs({ ((CTD and CTD ~= "") and CTD or (root .. "/target")) .. "/release/tillandsias-plan",
            root .. "/target/release/tillandsias-plan" }) do
        if proc.run{ argv = { "test", "-f", cand } }.ok then
            local r = proc.run{ argv = { cand, "capabilities" }, env = HENV }
            if not r.ok then
                why = text.trim(r.stderr or "")
                if why == "" then why = cand .. " exists but did not run" end
                break
            end
            why = text.trim(r.stderr or "")
        end
    end
end
if probe == "" and not proc.run{ argv = { "yq", "--version" } }.ok then
    cleanup()
    log.raw("skip:issue-capture-lane:no-validator — " .. (why ~= "" and why or "no runnable tillandsias-plan")
        .. " and no yq, so the lane cannot validate fragments here; the acceptance arms would fail on tooling, not behaviour")
    out.line("issue-capture-lane: 0 passed, 0 failed (skipped)")
    verdict.skip("issue-capture-lane:no-validator")
end
if probe == "" then
    log.raw("skip:plan-binary-not-runnable-here:" .. (why ~= "" and why or "no runnable tillandsias-plan resolved"))
    log.raw("  The lane skips ledger validation without a runnable binary, so the")
    log.raw("  scratch base is not load-bearing and the arms below still mean what")
    log.raw("  they say. This is host state, not a lane defect (1058-fenk).")
elseif proc.run{ argv = { probe, "--index", "plan/index.yaml", "check" }, cwd = WC, env = HENV }.ok then
    ok("PRECONDITION: the scratch base ledger folds")
else
    cleanup()
    log.raw("FAIL: PRECONDITION — the scratch base ledger does not fold; the arms below would fail for an environment reason, not a lane defect")
    out.line("issue-capture-lane: 0 passed, 1 failed")
    verdict.emit("violation:issue-capture-lane:precondition", 1)
end

-- Drive the guard the way git does. No stamp exists in this scratch tree, so
-- the lane is the ONLY thing that can accept a push here.
local function run_guard()
    local rsha = text.trim(G({ "rev-parse", "origin/linux-next" }).stdout or "")
    local head = text.trim(G({ "rev-parse", "HEAD" }).stdout or "")
    local r = proc.run{ argv = { "bash", "scripts/hooks/pre-push-local-gate.sh" }, cwd = WC, env = HENV,
        stdin = "refs/heads/linux-next " .. head .. " refs/heads/linux-next " .. rsha .. "\n", timeout_ms = 600000 }
    return (r.stdout or "") .. (r.stderr or "")
end
local function reset_to_remote()
    G({ "reset", "-q", "--hard", "origin/linux-next" }); G({ "clean", "-qfd" })
    mkdirs("plan/issues", "plan/index.d", "plan/inbox", "scripts/hooks")
    put("plan/index.yaml", "packets: []\n")
end
local function clean_lane(o) return has(o, "plan-only lane clean") end
local function names(o, path) return has(o, "plan-only lane: validated " .. path) end

-- ── 1. (a) A NEW top-level capture with symbol citations is ADMITTED. ──────
put("plan/issues/new-capture.md", "The const lives in `main.rs` `build_git_run_args`.\n")
commit("file a capture")
local o = run_guard()
if lane_qualified(o) and (clean_lane(o) or names(o, "plan/issues/new-capture.md")) then
    ok("a NEW plan/issues capture qualifies for the lane")
else bad("new capture was turned away: " .. first_with(o, { "not applicable", "FAILED", "refused" })) end
if names(o, "plan/issues/new-capture.md") then ok("the push record NAMES the validated capture")
else bad("the accepted capture was not named in the push record") end
reset_to_remote()

-- ── 1b. ORDER 1141-f5nk: a de-slop SWEEP RECORD qualifies, new and appended. ─
mkdirs("plan/deslop-sweeps.d")
put("plan/deslop-sweeps.d/lenovinha.md", "# sweeps\n\n- 2026-09-13 lenovinha: examined 12 confirmed 0\n")
commit("record a sweep")
o = run_guard()
if lane_qualified(o) then ok("a NEW plan/deslop-sweeps.d record qualifies for the lane (1141-f5nk)")
else bad("a new sweep record was turned away: " .. first_with(o, { "not applicable" })) end
append("plan/deslop-sweeps.d/lenovinha.md", "- 2026-09-13 lenovinha: examined 9 confirmed 1\n")
commit("append a second sweep")
o = run_guard()
if lane_qualified(o) then ok("an APPENDED sweep record qualifies (M, not just A)")
else bad("an appended sweep record was turned away: " .. first_with(o, { "not applicable" })) end
reset_to_remote()

-- ── 1c. NEGATIVE CONTROL for 1141-f5nk: a REWRITE must fall back. ───────────
--      Passes in both states; it only has meaning next to 1b.
mkdirs("plan/deslop-sweeps.d")
put("plan/deslop-sweeps.d/lenovinha.md", "# sweeps\n\n- 2026-09-13 lenovinha: examined 12 confirmed 0\n- 2026-09-13 lenovinha: examined 9 confirmed 1\n")
commit("seed two sweep records")
G({ "push", "-q", "origin", "linux-next" })
put("plan/deslop-sweeps.d/lenovinha.md", "# sweeps\n\n- 2026-09-13 lenovinha: examined 12 confirmed 0\n")
commit("REWRITE: drop a sweep record")
o = run_guard()
if clean_lane(o) then bad("NEGATIVE CONTROL BREACHED — an edit REMOVING a sweep record rode the lane")
else ok("a sweep-record REMOVAL falls back to the full gate (1141-f5nk)") end
reset_to_remote()

-- ── 1d. THE DRILL CONVENTION IS A PINNED PROPERTY, NOT A COINCIDENCE. ──────
put("plan/issues/fleet-restart-2026-09-12-lenovinha.md", "- 2026-09-13 lenovinha: drill note\n")
commit("flat per-host drill note")
o = run_guard()
if lane_qualified(o) then ok("the FLAT per-host drill name qualifies for the lane (the adopted convention)")
else bad("the flat per-host drill name was turned away, so every host now pays a full gate per drill note: " .. first_with(o, { "not applicable" })) end
reset_to_remote()

-- CONTROL: the rejected nested shape must STAY rejected.
mkdirs("plan/issues/fleet-restart-2026-09-12.d")
put("plan/issues/fleet-restart-2026-09-12.d/lenovinha.md", "- 2026-09-13 lenovinha: drill note\n")
commit("nested .d per-host drill note")
o = run_guard()
if lane_qualified(o) then
    bad("CONTROL: the nested .d/ shape now QUALIFIES — the class arm has widened, and arm 1d above no longer proves the convention was the reason the flat name is cheap")
else
    ok("CONTROL: the nested .d/ shape still takes the full gate, so 1d is about the NAME and not about a permissive lane")
end
reset_to_remote()

-- ── 1e. ORDER 1507-e693: a NEW plan/inbox/ MAILBOX MESSAGE qualifies. ───────
mkdirs("plan/inbox")
put("plan/inbox/codex.md", "# Codex inbox\n\n## MSG codex-2026-09-29-01 — hello\nfirst message\n")
commit("file the first inbox message")
o = run_guard()
if lane_qualified(o) and (clean_lane(o) or names(o, "plan/inbox/codex.md")) then
    ok("a NEW plan/inbox/ mailbox message qualifies for the lane (1507-e693)")
else bad("a new inbox message was turned away: " .. first_with(o, { "not applicable" })) end
append("plan/inbox/codex.md", "\n## MSG codex-2026-09-30-02 — second message\nRECEIVED: codex-2026-09-29-01\n")
commit("append a second inbox message")
o = run_guard()
if lane_qualified(o) then ok("an APPENDED inbox message qualifies (M, not just A)")
else bad("an appended inbox message was turned away: " .. first_with(o, { "not applicable" })) end
reset_to_remote()

-- ── 1f. NEGATIVE CONTROL for 1507-e693: an inbox REWRITE must fall back. ───
mkdirs("plan/inbox")
put("plan/inbox/codex.md", "# Codex inbox\n\n## MSG one\nfirst\n\n## MSG two\nsecond\n")
commit("seed two inbox messages")
G({ "push", "-q", "origin", "linux-next" })
put("plan/inbox/codex.md", "# Codex inbox\n\n## MSG one\nfirst\n")
commit("REWRITE: drop an inbox message")
o = run_guard()
if clean_lane(o) then bad("NEGATIVE CONTROL BREACHED — an edit REMOVING an inbox message rode the lane")
else ok("an inbox-message REMOVAL falls back to the full gate (1507-e693)") end
reset_to_remote()

-- ── 1g. NEGATIVE CONTROL: plan/inbox/ mixed with a scripts/ file is refused.
mkdirs("plan/inbox")
put("plan/inbox/codex.md", "# Codex inbox\n\n## MSG\nhello\n")
put("scripts/some-inbox-code.sh", "echo hi\n")
commit("inbox message plus code")
o = run_guard()
if clean_lane(o) then bad("a push mixing plan/inbox/ with code rode the lane")
else ok("plan/inbox/ mixed with a scripts/ file still takes the full gate (no gate stamp exists in this scratch tree, so a stamp-free acceptance would show up as 'plan-only lane clean')") end
reset_to_remote()

-- ── 1h. plan/inbox/ SHAPE GUARDS: nested path and non-markdown are refused.
mkdirs("plan/inbox/sub")
put("plan/inbox/sub/x.md", "nested message\n")
commit("nested inbox path")
o = run_guard()
if clean_lane(o) then bad("a nested plan/inbox/sub/x.md rode the lane")
else ok("a nested plan/inbox/sub/x.md takes the full gate") end
reset_to_remote()

mkdirs("plan/inbox")
put("plan/inbox/x.sh", "#!/usr/bin/env bash\necho hi\n")
commit("non-markdown inbox file")
o = run_guard()
if clean_lane(o) then bad("a non-markdown plan/inbox/x.sh rode the lane")
else ok("a non-markdown plan/inbox/x.sh takes the full gate") end
reset_to_remote()

-- ── 2. (d) THE NEGATIVE CONTROL: a capture violating 881-29me FALLS BACK. ──
put("plan/issues/bad-capture.md", "The const lives at `main.rs:1136-1145`.\n")
commit("file a capture with a line citation")
o = run_guard()
if clean_lane(o) then bad("NEGATIVE CONTROL BREACHED — a line-number citation rode the lane")
elseif has(o, "check-issue-citation-convention") then ok("a malformed capture falls back to the full gate, naming 881-29me")
else ok("a malformed capture falls back to the full gate") end
reset_to_remote()

-- ── 3. A MODIFIED capture now QUALIFIES (order 1060-7mmm) ──────────────────
append("plan/issues/existing.md", "See `main.rs` `resolve_probe`.\n")
commit("correct an existing capture")
o = run_guard()
if lane_qualified(o) then ok("a CORRECTED capture (M under plan/issues/) qualifies for the lane")
else bad("a corrected capture was refused: " .. first_with(o, { "plan-only lane" })) end
reset_to_remote()

-- ── 3b. NEGATIVE CONTROL: an M ELSEWHERE still takes the full gate ─────────
append("build.sh", "\n# touched by a fixture\n")
commit("modify build.sh")
o = run_guard()
if clean_lane(o) then bad("a MODIFIED build.sh rode the lane")
else ok("a MODIFIED file outside the plan dirs still takes the full gate") end
reset_to_remote()

-- ── 3c. A DELETED capture is still refused ────────────────────────────────
G({ "rm", "-q", "plan/issues/existing.md" })
G({ "commit", "-q", "-m", "delete a capture" })
o = run_guard()
if clean_lane(o) then bad("a DELETED capture rode the lane")
else ok("a DELETED capture still takes the full gate") end
reset_to_remote()

-- ── 3d. AN APPEND to a work-queue ledger qualifies (order 1013-xm63) ───────
append("plan/issues/linux-next-work-queue-2026-05-25.md", "- 2026-09-05 pirria: See `lib.rs` `resolve_plan_binary`.\n")
commit("append a work-queue line")
o = run_guard()
if names(o, "plan/issues/linux-next-work-queue-2026-05-25.md") then ok("an APPEND to a work-queue ledger qualifies and is named")
else bad("an append to a work-queue ledger was refused: " .. first_with(o, { "plan-only lane" })) end
reset_to_remote()

-- ── 3e. A REWRITE of a work-queue ledger is still refused ──────────────────
put("plan/issues/linux-next-work-queue-2026-05-25.md", "- 2026-09-01 macuahuitl: REWRITTEN, and the original line is gone.\n")
commit("rewrite the work-queue ledger")
o = run_guard()
if has(o, "is a work-queue ledger and this edit REMOVES or REWRITES lines") then
    ok("a REWRITE of a work-queue ledger takes the full gate, naming the hunk")
else bad("a rewrite of a work-queue ledger was not refused by name: " .. first_with(o, { "plan-only lane" })) end
reset_to_remote()

-- ── 3f. A correction to NON-queue prose is still free (1060-7mmm holds) ────
append("plan/issues/existing.md", "See `lib.rs` `other_fn`.\n")
commit("correct a non-queue capture")
o = run_guard()
if names(o, "plan/issues/existing.md") then ok("a correction to a non-queue capture is still free (1060-7mmm intact)")
else bad("the work-queue rule leaked onto ordinary captures: " .. first_with(o, { "plan-only lane" })) end
reset_to_remote()

-- ── 4. (c) A class subdirectory is admitted at exactly one level deep. ─────
mkdirs("plan/issues/optimization")
put("plan/issues/optimization/scoped.md", "See `main.rs` `resolve_probe`.\n")
commit("file under a class directory")
o = run_guard()
if lane_qualified(o) and (clean_lane(o) or names(o, "plan/issues/optimization/scoped.md")) then
    ok("a capture under optimization/ qualifies for the lane")
else bad("a class-directory capture was turned away: " .. first_with(o, { "not applicable", "FAILED" })) end
reset_to_remote()

-- ── 5. (c) Deeper than one level, and unknown directories, are refused. ────
mkdirs("plan/issues/optimization/deeper")
put("plan/issues/optimization/deeper/x.md", "text\n")
commit("file too deep")
o = run_guard()
if clean_lane(o) then bad("a capture nested two levels deep rode the lane")
else ok("a capture nested two levels deep takes the full gate") end
reset_to_remote()

mkdirs("plan/issues/unsanctioned")
put("plan/issues/unsanctioned/x.md", "text\n")
commit("file under an unknown directory")
o = run_guard()
if clean_lane(o) then bad("a capture under an unsanctioned directory rode the lane")
else ok("an unsanctioned class directory takes the full gate") end
reset_to_remote()

-- ── 6. (b) A capture pushed ALONGSIDE code takes the full gate. ────────────
put("plan/issues/with-code.md", "See `main.rs` `resolve_probe`.\n")
put("scripts/some-code.sh", "echo hi\n")
commit("capture plus code")
o = run_guard()
if clean_lane(o) then bad("a push mixing a capture with code rode the lane")
else ok("a capture pushed alongside code takes the full gate") end
reset_to_remote()

-- ── 7. (c) README.md under plan/issues is prose, not a capture. ────────────
put("plan/issues/README.md", "How to file issues. See `main.rs` `main`.\n")
commit("add a README")
o = run_guard()
if clean_lane(o) then bad("plan/issues/README.md rode the lane as if it were a capture")
else ok("plan/issues/README.md is prose and takes the full gate") end
reset_to_remote()

-- ── 8. CONTROL: the pre-889 lanes still work, so this change is additive. ──
-- Hand over a binary that RUNS, or none at all (1060-6fx7).
if probe ~= "" then HENV.TILLANDSIAS_PLAN_BIN = probe end
put("plan/index.d/20260101t000000z-control.yaml", "packets: []\n")
commit("a plain fragment")
o = run_guard()
if has(o, "is outside plan/index.d/") then
    bad("CONTROL BROKEN — a plan/index.d fragment no longer qualifies for the lane")
elseif clean_lane(o) or has(o, "plan-only lane: validation FAILED") then
    ok("CONTROL: a plain plan/index.d fragment still qualifies for the lane")
elseif has(o, "no runnable tillandsias-plan resolved") or has(o, "does NOT run here") then
    ok("CONTROL: the fragment qualified; the lane refused fail-closed for a missing fold validator (1124-7f3u)")
else
    bad("CONTROL: unexpected verdict for a plain fragment: " .. first_with(o, { "not applicable", "FAILED" }))
end
reset_to_remote()

cleanup()
out.line("issue-capture-lane: " .. pass .. " passed, " .. fail .. " failed")
if fail ~= 0 then verdict.emit("violation:issue-capture-lane:" .. fail, 1) end
verdict.ok("issue-capture-lane:" .. pass)
