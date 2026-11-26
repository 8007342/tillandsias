-- @trace order:1056-5344, order:1060-7mmm, order:2209-jw2t
--
-- test-pre-push-plan-lane-after-merge.lua — PORTED from
-- test-pre-push-plan-lane-after-merge.sh (2209-jw2t), same arms, same lines.
-- On a platform branch the plan-only lane must survive the MANDATED merge of
-- origin/linux-next, and must not become a way to smuggle code past the gate.
--
-- THE DEFECT: that merge brings other hosts' non-plan files into the diff
-- against the platform remote, so a one-file ledger append cost a full gate
-- whenever anyone touched code on trunk (esmeraldinha, 2026-09-05).
--
-- EVERY ARM IS CROSS-BRANCH: the defect exists only when the merge SOURCE
-- (linux-next) and the push TARGET (windows-next) differ; a same-branch repro
-- passes against the unfixed hook. --first-parent ALONE IS A BYPASS (a side
-- branch merged --no-ff), which arm 3 is the negative control for.
--
-- HEAD: the hook runs in a scratch repo under target/plan-scratch with its own
-- origin, never against the real checkout's HEAD (2196-rdec: clean by
-- construction). The checkout's own validator is resolved HERE, where the
-- probe can see it, and handed to the hook as TILLANDSIAS_PLAN_BIN, as the
-- .sh exported it; with none and no yq, a NAMED skip.
--
-- Verdict: after the .sh's summary line, ok:plan-lane-after-merge:<p> |
-- violation:plan-lane-after-merge:<f> | skip:plan-lane-after-merge:no-validator

-- 2246-fkea helpers (yolanda, msys: `pwd -P` gave /c/..., a "relative" cwd to
-- the native runner, and a bare bash is WSL's there).
local fixture = require "common.fixture"
local SH = fixture.posix_shell()
local root = fixture.repo_root()
local GUARD = "scripts/hooks/pre-push-local-gate.sh"
local pass, fail = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) log.raw("FAIL: " .. m); fail = fail + 1 end
local function indent(s) -- the .sh's `sed 's/^/      /' >&2` of the guard output
    for _, l in ipairs(text.lines((s or ""):gsub("\n+$", ""))) do log.raw("      " .. l) end
end
local function has(s, p) return (s or ""):find(p, 1, true) ~= nil end
local function first_line_with(s, p)
    for _, l in ipairs(text.lines(s or "")) do if l:find(p, 1, true) then return l end end
    return ""
end

local rel = "target/plan-scratch/prepush-lane-merge-" .. tostring(time.now_ms())
local W = root .. "/" .. rel
local WC = W .. "/wc"
proc.run{ argv = { "mkdir", "-p", W } }
local function cleanup() proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 } end

fs.write(rel .. "/resolve.sh", ". scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null\n")
local V = text.trim(proc.run{ argv = { SH, W .. "/resolve.sh" } }.stdout or "")
if V:sub(1, 2) == "./" then V = root .. "/" .. V:sub(3) end
if V == "" and not proc.run{ argv = { "yq", "--version" } }.ok then
    cleanup()
    log.raw("skip:plan-lane-after-merge:no-validator — no runnable tillandsias-plan and no yq, so the lane cannot validate fragments on this host; the acceptance arms would fail on tooling, not behaviour")
    out.line("plan-lane-after-merge: 0 passed, 0 failed (skipped)")
    verdict.skip("plan-lane-after-merge:no-validator")
end
-- 2242-u39b: the scratch checkout is tested, never the caller's frozen diff base
-- (TILLANDSIAS_* names pass proc.run's scrub, so both are passed empty).
local HENV = { GIT_TERMINAL_PROMPT = "0", TILLANDSIAS_GATE_DIFF_BASE = "", TILLANDSIAS_GATE_DIFF_BASE_ROOT = "" }
if V ~= "" then HENV.TILLANDSIAS_PLAN_BIN = V end

local function G(args)
    local a = { "git", "-c", "user.email=t@t", "-c", "user.name=t" }
    for _, x in ipairs(args) do a[#a + 1] = x end
    return proc.run{ argv = a, cwd = WC, env = HENV, timeout_ms = 120000 }
end
local function put(path, body) fs.write(rel .. "/wc/" .. path, body) end
local function append(path, body) put(path, (fs.read(rel .. "/wc/" .. path) or "") .. body) end
local function commit(msg) G({ "add", "-A" }); G({ "commit", "-q", "-m", msg }) end
local function mkdirs(...)
    local a = { "mkdir", "-p" }
    for _, x in ipairs({ ... }) do a[#a + 1] = WC .. "/" .. x end
    proc.run{ argv = a }
end
local function rm_marker()
    proc.run{ argv = { "find", WC .. "/.git", "-maxdepth", "1", "-name", "tillandsias-union-ungated", "-delete" } }
end
local function marker_nonempty()
    local m = rel .. "/wc/.git/tillandsias-union-ungated"
    if not fs.exists(m) then return false end
    return (fs.read(m) or "") ~= ""
end

proc.run{ argv = { "git", "init", "-q", "--bare", W .. "/bare.git" } }
proc.run{ argv = { "git", "init", "-q", "-b", "linux-next", WC } }
G({ "remote", "add", "origin", W .. "/bare.git" })
-- core.hooksPath is GLOBAL and OVERRIDES .git/hooks; pin it so the seeding
-- pushes never run the real hooks against this scratch tree.
G({ "config", "core.hooksPath", ".git/hooks" })
G({ "config", "core.autocrlf", "false" })
mkdirs("scripts/hooks", "plan/index.d", "plan/issues")
proc.run{ argv = { "cp", GUARD, WC .. "/scripts/hooks/pre-push-local-gate.sh" } }
for _, f in ipairs({ "plan-binary-probe.sh", "gate-stamp.sh", "common.sh", "check-issue-citation-convention.sh" }) do
    if fs.exists("scripts/" .. f) then proc.run{ argv = { "cp", "scripts/" .. f, WC .. "/scripts/" .. f } } end
end
proc.run{ argv = { "find", WC .. "/scripts", "-name", "*.sh", "-exec", "chmod", "+x", "{}", "+" } }
put("plan/index.yaml", "packets: []\n")
put("README.md", "base\n")
-- A landed capture for the correction arms (1060-7mmm) to modify.
put("plan/issues/existing-report.md", "See `main.rs` `resolve_probe`.\n")
-- A tracked non-plan file for arm 7 (not README.md, which trunk modifies).
put("src_placeholder.rs", "fn main() {}\n")
commit("base")
G({ "push", "-q", "-u", "origin", "linux-next" })
G({ "push", "-q", "origin", "linux-next:windows-next" })

-- Trunk moves with another host's NON-PLAN file.
put("README.md", "base\nchanged by another host\n")
commit("foreign code change on trunk")
G({ "push", "-q", "origin", "linux-next" })
G({ "reset", "-q", "--hard", "origin/linux-next~1" })

-- Drive the guard the way git does: one ref line on stdin, pushing WINDOWS-NEXT.
local function run_guard()
    local rsha = text.trim(G({ "rev-parse", "origin/windows-next" }).stdout or "")
    local head = text.trim(G({ "rev-parse", "HEAD" }).stdout or "")
    local r = proc.run{ argv = { SH, "scripts/hooks/pre-push-local-gate.sh" }, cwd = WC, env = HENV,
        stdin = "refs/heads/windows-next " .. head .. " refs/heads/windows-next " .. rsha .. "\n", timeout_ms = 600000 }
    return (r.stdout or "") .. (r.stderr or ""), r.code
end
-- `reset --hard` does not recreate plan/index.d/, and a write into a missing
-- directory would leave the arm's commit empty: recreate it every time.
local function reset_branch()
    G({ "reset", "-q", "--hard", "origin/windows-next" }); G({ "clean", "-qfd" }); mkdirs("plan/index.d", "scripts/hooks")
end
local function outgoing() return G({ "diff", "--name-only", "origin/windows-next", "HEAD" }).stdout or "" end
local function mandated_merge() G({ "merge", "-q", "--no-edit", "origin/linux-next", "-m", "mandated merge of origin/linux-next" }) end

G({ "checkout", "-q", "-B", "windows-next", "origin/windows-next" })
mkdirs("plan/index.d")

-- ── ARM 1: a ledger-only cycle takes the lane after the mandated merge ──────
put("plan/index.d/20260905t000000z-fixture.yaml", "packets: []\n")
commit("ledger append")
G({ "fetch", "-q", "origin" })
mandated_merge()
local o, rc = run_guard()
if rc == 0 and has(o, "plan-only lane") then
    ok("ARM 1: ledger-only push takes the lane despite a merge carrying foreign code")
else
    bad("ARM 1: lane refused a ledger-only push after the mandated merge (rc=" .. tostring(rc) .. ")"); indent(o)
end

-- ── ARM 2: the host's OWN code change still requires the full gate ──────────
reset_branch()
put("plan/index.d/20260905t000001z-fixture.yaml", "packets: []\n")
put("own_code.rs", "fn main() {}\n")
commit("ledger append PLUS the host's own code")
mandated_merge()
if not has(outgoing(), "own_code.rs") then
    bad("ARM 2 is VACUOUS — own_code.rs is not in the outgoing diff; the arm would pass on an empty push")
end
o, rc = run_guard()
if rc ~= 0 then ok("ARM 2: a push whose own commits touch code still requires the full gate")
else bad("ARM 2: the lane accepted a push carrying the host's own code file"); indent(o) end

-- ── ARM 3: NEGATIVE CONTROL — code hidden behind a NON-TRUNK merge ──────────
reset_branch()
G({ "branch", "-q", "-D", "side" })
G({ "checkout", "-q", "-b", "side" })
put("sneaky.rs", "fn sneaky() {}\n")
commit("code parked on a side branch")
G({ "checkout", "-q", "windows-next" })
put("plan/index.d/20260905t000002z-fixture.yaml", "packets: []\n")
commit("ledger append")
G({ "merge", "-q", "--no-ff", "--no-edit", "side", "-m", "merge side branch" })
mandated_merge()
if not has(outgoing(), "sneaky.rs") then
    bad("ARM 3 is VACUOUS — sneaky.rs is not in the outgoing diff; the arm would pass on an empty push")
end
o, rc = run_guard()
if rc ~= 0 then ok("ARM 3: code arriving via a NON-TRUNK merge still requires the full gate")
else bad("ARM 3: BYPASS — code hidden behind a side-branch merge took the plan-only lane"); indent(o) end

-- ── ARM 4: the un-gated union is RECORDED, not implied ──────────────────────
reset_branch()
rm_marker()
put("plan/index.d/20260905t000003z-fixture.yaml", "packets: []\n")
commit("ledger append")
mandated_merge()
o, rc = run_guard()
if rc == 0 and marker_nonempty() and has(o, "UN-GATED UNION") then
    ok("ARM 4: the lane records the un-gated union for the coordinator's land")
else
    bad("ARM 4: the lane took a merge-scoped push without recording the union debt (rc=" .. tostring(rc) .. ")"); indent(o)
end

-- ── ARM 5: no merge in the range writes NO marker ───────────────────────────
reset_branch()
rm_marker()
put("plan/index.d/20260905t000004z-fixture.yaml", "packets: []\n")
commit("ledger append, no merge")
o, rc = run_guard()
if rc == 0 and not marker_nonempty() then
    ok("ARM 5: a push with no merge takes the lane and records no union debt")
else
    bad("ARM 5: a merge-free push either failed the lane or recorded a spurious union marker (rc=" .. tostring(rc) .. ")"); indent(o)
end

-- ── ARM 6: a CORRECTION to a landed report rides the lane after the merge ──
reset_branch()
put("plan/index.d/20260905t000005z-fixture.yaml", "packets: []\n")
append("plan/issues/existing-report.md", "Also see `lib.rs` `resolve_plan_binary`.\n")
commit("new fragment plus a correction to a landed report")
mandated_merge()
rm_marker()
o, rc = run_guard()
if rc == 0 and has(o, "plan-only lane") then
    ok("ARM 6: an M confined to plan/issues/ rides the lane beside a new fragment")
else
    bad("ARM 6: a correction to a landed report was refused after the merge (rc=" .. tostring(rc) .. ")")
    local n = 0
    for _, l in ipairs(text.lines(o)) do
        if n < 2 and l:find("plan-only lane", 1, true) then log.raw("      " .. l); n = n + 1 end
    end
end
if marker_nonempty() then ok("ARM 6: the un-gated union is still recorded when a correction takes the lane")
else bad("ARM 6: relaxing the M rule dropped the union marker — the gate debt is now invisible") end

-- ── ARM 7: NEGATIVE CONTROL — an M outside the plan dirs still full-gates ──
reset_branch()
put("plan/index.d/20260905t000006z-fixture.yaml", "packets: []\n")
append("src_placeholder.rs", "fn other() {}\n")
commit("fragment plus a modified non-plan file")
mandated_merge()
if not has(outgoing(), "src_placeholder.rs") then
    bad("ARM 7 is VACUOUS — the modified file is not in the outgoing diff")
end
o, rc = run_guard()
if rc ~= 0 and has(o, "outside plan/index.d/") then
    ok("ARM 7: an M outside the plan directories still requires the full gate")
elseif rc ~= 0 then
    bad("ARM 7: refused, but not by the path-scope rule — " .. first_line_with(o, "plan-only lane"))
else bad("ARM 7: a modified non-plan file rode the lane — the M relaxation is too wide") end

cleanup()
out.line("plan-lane-after-merge: " .. pass .. " passed, " .. fail .. " failed")
if fail == 0 then verdict.ok("plan-lane-after-merge:" .. pass) end
verdict.emit("violation:plan-lane-after-merge:" .. fail, 1)
