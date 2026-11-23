-- @trace order:1504-4tty, order:1247-amcu, order:2197-h5kv
--
-- test-finalize-cycle-affordances.lua — PORTED from
-- test-finalize-cycle-affordances.sh (2197-h5kv), same arms, same lines.
-- Every refused:finalize: verdict of finalize-cycle.sh says why and what
-- clears it, keeps its token and exit code, and an actionable remedy is
-- carried out and clears its refusal.
--
-- HERMETIC: finalize-cycle.sh is copied into a scratch repository under
-- target/plan-scratch with stub collaborators (worktree guard = "tree is
-- clean", held-claims/land/attest stubs that succeed). HOME and system git
-- config point into the scratch dir.
--
-- Arms:
--   1 AUDIT     the slice-4 audit counts 0 bare sites in finalize-cycle.sh
--   2 CONTRACT  the verdict tokens and their exit codes are unchanged
--   3 REMEDY    boundary-verify-failed is reproduced by an uncommitted cycle
--               change, its remedy (commit it) is carried out, and the re-run
--               exits 0. NEGATIVE CONTROL: without it the refusal stands (rc 3)
--
-- Verdict: ok:finalize-cycle-affordances:3 arms | violation:finalize-cycle-affordances:<n> failed

local FC = "scripts/finalize-cycle.sh"
local failn = 0
local function ok(m) out.line("ok:   " .. m) end
local function bad(m) out.line("FAIL: " .. m); failn = failn + 1 end
local function count_prefix(s, p)
    local n = 0
    for _, l in ipairs(text.lines(s)) do if l:sub(1, #p) == p then n = n + 1 end end
    return n
end
local function oneline(s) return (s or ""):gsub("\n", "|") end

-- ── ARM 1 ────────────────────────────────────────────────────────────────
local audit = proc.run{ argv = { "bash", "scripts/check-refusal-affordance-added.sh", "--audit" },
    timeout_ms = 120000 }.stdout or ""
local bare = count_prefix(audit, "bare " .. FC .. ":")
local covered = count_prefix(audit, "covered " .. FC .. ":")
if bare == 0 and covered >= 9 then
    ok("ARM1 0 bare verdict sites in finalize-cycle.sh (" .. covered .. " covered; pre-fix 9 bare)")
else bad("ARM1 bare=" .. bare .. " covered=" .. covered) end

-- ── ARM 2 ────────────────────────────────────────────────────────────────
-- The verdict line (token followed by `"` or a space), then `exit <code>` on
-- it or within the next two lines.
local contract = {
    { "no-boundary-state", 2 }, { "boundary-verify-failed", 3 }, { "work-land-failed", 6 },
    { "boundary-verify-failed-post-land", 3 }, { "record-failed", 4 }, { "commit-failed", 5 },
    { "ledger-land-failed", 6 }, { "boundary-verify-failed-post-record", 3 },
}
local lines = text.lines(fs.read(FC) or "")
local missing = ""
for _, c in ipairs(contract) do
    local t1 = "refused:finalize:" .. c[1] .. '"'
    local t2 = "refused:finalize:" .. c[1] .. " "
    local e, found = "exit " .. c[2], false
    for i, l in ipairs(lines) do
        if l:find(t1, 1, true) or l:find(t2, 1, true) then
            for j = i, math.min(i + 2, #lines) do
                if lines[j]:find(e, 1, true) then found = true end
            end
        end
    end
    if not found then missing = missing .. " " .. c[1] .. ":" .. c[2] end
end
if missing == "" then ok("ARM2 every verdict keeps its token and exit code")
else bad("ARM2 changed:" .. missing) end

-- ── ARM 3 ────────────────────────────────────────────────────────────────
local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local rel = "target/plan-scratch/finalize-afford-" .. tostring(time.now_ms())
local W = root .. "/" .. rel
local R = W .. "/root"
local GENV = { HOME = W .. "/home", GIT_CONFIG_NOSYSTEM = "1" }
local function run(argv, cwd)
    return proc.run{ argv = argv, env = GENV, cwd = cwd, timeout_ms = 120000 }
end
run({ "mkdir", "-p", W .. "/home", W .. "/boundary", R .. "/scripts", R .. "/plan/mo-full-attestations.d" })
run({ "cp", FC, R .. "/scripts/finalize-cycle.sh" })
fs.write(rel .. "/root/scripts/meta-orchestration-worktree-guard.sh", '[ -z "$(git status --porcelain)" ]\n')
fs.write(rel .. "/root/scripts/report-held-claims.sh", "#!/bin/sh\nexit 0\n")
fs.write(rel .. "/root/scripts/land-on-platform-branch.sh", "#!/bin/sh\nexit 0\n")
fs.write(rel .. "/root/scripts/mo-full-attest.sh",
    '#!/bin/sh\ncase "$1" in record) echo "MO-FULL: COMPLETE stub" ;; *) echo "MO-FULL: marker" ;; esac\n')
for _, s in ipairs({ "finalize-cycle", "meta-orchestration-worktree-guard", "report-held-claims",
    "land-on-platform-branch", "mo-full-attest" }) do
    run({ "chmod", "+x", R .. "/scripts/" .. s .. ".sh" })
end
run({ "git", "init", "-q", "-b", "linux-next", R })
run({ "git", "-C", R, "config", "user.email", "f@f" })
run({ "git", "-C", R, "config", "user.name", "f" })
run({ "git", "-C", R, "add", "-A" })
run({ "git", "-C", R, "commit", "-qm", "base" })
local gitdir = text.trim(run({ "git", "-C", R, "rev-parse", "--absolute-git-dir" }).stdout or "")
proc.run{ argv = { "dd", "of=" .. gitdir .. "/boundary-state", "status=none" }, stdin = W .. "/boundary" }
proc.run{ argv = { "dd", "of=" .. R .. "/cycle-output.txt", "status=none" }, stdin = "stray\n" } -- the cycle's own, uncommitted change

local function fin()
    local r = run({ "bash", "scripts/finalize-cycle.sh", "linux-next" }, R)
    return r.code, r.stderr or ""
end

local rc1, err1 = fin()
if rc1 == 3 and err1:find("refused:finalize:boundary-verify-failed", 1, true)
    and err1:find("  remedy: run git status: commit", 1, true) then
    local rc_nc = fin()                                          -- negative control
    run({ "git", "-C", R, "add", "-A" })                         -- the remedy's action
    run({ "git", "-C", R, "commit", "-qm", "the cycle's own change" })
    local rc2, err2 = fin()
    if rc_nc == 3 and rc2 == 0 and not err2:find("refused:finalize", 1, true) then
        ok("ARM3 the remedy clears boundary-verify-failed (re-run rc=0); without it the refusal stands (rc=3)")
    else bad("ARM3 negative-control rc=" .. tostring(rc_nc) .. " after-remedy rc=" .. tostring(rc2) ..
        " err='" .. oneline(err2) .. "'") end
else
    bad("ARM3 could not reproduce boundary-verify-failed with its remedy: rc=" .. tostring(rc1) ..
        " err='" .. oneline(err1) .. "'")
end

proc.run{ argv = { "find", W, "-delete" } }
if failn > 0 then
    out.line("FAILED: finalize-cycle-affordances (1504-4tty)")
    verdict.emit("violation:finalize-cycle-affordances:" .. failn .. " failed", 1)
end
out.line("PASS: finalize-cycle-affordances (1504-4tty)")
verdict.emit("ok:finalize-cycle-affordances:3 arms", 0)
