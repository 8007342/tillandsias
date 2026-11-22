-- @trace order:1505-hedu, order:1247-amcu, order:2197-h5kv
--
-- test-release-preflight-affordances.lua — PORTED from
-- test-release-preflight-affordances.sh (2197-h5kv), same arms, same lines.
-- Every blocked: verdict of release-preflight.sh says why and what clears it,
-- keeps its token and exit code, and an actionable remedy is carried out and
-- clears its refusal.
--
-- HERMETIC: release-preflight.sh and plan-binary-probe.sh are copied into a
-- scratch repository under target/plan-scratch. Gate 1's monotonicity script
-- is a stub that passes; there is no built binary (Gate 2 has nothing to
-- inspect), and the scratch ledger is a minimal valid one (Gate 3 passes
-- whether or not a plan binary resolves from PATH), so Gate 4 is reached.
-- HOME and system git config point into the scratch dir; TILLANDSIAS_PLAN_BIN
-- and CARGO_TARGET_DIR are unset for the subject (`env -u`, because the
-- runner passes TILLANDSIAS_* through).
--
-- Arms:
--   1 AUDIT     the slice-4 audit counts 0 bare sites in release-preflight.sh
--   2 CONTRACT  the verdict tokens and their exit codes are unchanged
--   3 REMEDY    blocked:unsanctioned-workflow is reproduced, the remedy it
--               prints (git rm the listed workflow) is carried out, and the
--               re-run no longer refuses with that token. NEGATIVE CONTROL:
--               without it the refusal stands
--
-- Verdict: ok:release-preflight-affordances:3 arms | violation:release-preflight-affordances:<n> failed

local RP = "scripts/release-preflight.sh"
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
local bare = count_prefix(audit, "bare " .. RP .. ":")
local covered = count_prefix(audit, "covered " .. RP .. ":")
if bare == 0 and covered >= 10 then
    ok("ARM1 0 bare verdict sites in release-preflight.sh (" .. covered .. " covered; pre-fix 10 bare)")
else bad("ARM1 bare=" .. bare .. " covered=" .. covered) end

-- ── ARM 2 ────────────────────────────────────────────────────────────────
-- The verdict line, then `exit <code>` on it or within the next two lines.
local contract = {
    { "not-a-git-repo", 2 }, { "cannot-enter-repo-root", 2 }, { "version-not-monotonic", 1 },
    { "version-monotonic-script-missing", 1 }, { "retired-flag-advertised", 1 },
    { "retired-flag-in-usage-text", 1 }, { "plan-ledger-incomplete", 1 },
    { "plan-ledger-invalid", 1 }, { "unsanctioned-workflow", 1 },
}
local lines = text.lines(fs.read(RP) or "")
local missing = ""
for _, c in ipairs(contract) do
    local t, e, found = "blocked:" .. c[1] .. '"', "exit " .. c[2], false
    for i, l in ipairs(lines) do
        if l:find(t, 1, true) then
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
local rel = "target/plan-scratch/release-afford-" .. tostring(time.now_ms())
local W = root .. "/" .. rel
local R = W .. "/root"
local GENV = { HOME = W .. "/home", GIT_CONFIG_NOSYSTEM = "1" }
local function run(argv, cwd)
    return proc.run{ argv = argv, env = GENV, cwd = cwd, timeout_ms = 120000 }
end
run({ "mkdir", "-p", W .. "/home", R .. "/scripts", R .. "/.github/workflows", R .. "/plan/index.d" })
fs.write(rel .. "/root/plan/index.yaml", "plan_index:\n  steps: []\n")
run({ "cp", RP, "scripts/plan-binary-probe.sh", R .. "/scripts/" })
fs.write(rel .. "/root/scripts/verify-version-monotonic.sh", "#!/bin/sh\nexit 0\n")
run({ "chmod", "+x", R .. "/scripts/release-preflight.sh", R .. "/scripts/plan-binary-probe.sh",
    R .. "/scripts/verify-version-monotonic.sh" })
fs.write(rel .. "/root/.github/workflows/release.yml", "name: release\n")
fs.write(rel .. "/root/.github/workflows/nightly.yml", "name: nightly\n") -- the unsanctioned one
run({ "git", "init", "-q", "-b", "linux-next", R })
run({ "git", "-C", R, "config", "user.email", "f@f" })
run({ "git", "-C", R, "config", "user.name", "f" })
run({ "git", "-C", R, "add", "-A" })
run({ "git", "-C", R, "commit", "-qm", "base" })

local function pre()
    local r = run({ "env", "-u", "TILLANDSIAS_PLAN_BIN", "-u", "CARGO_TARGET_DIR",
        "bash", "scripts/release-preflight.sh" }, R)
    return r.code, r.stdout or "", r.stderr or ""
end
local function tail3(s)
    local l = text.lines(s); local o = {}
    for i = math.max(1, #l - 2), #l do o[#o + 1] = l[i] end
    return table.concat(o, "|")
end

local rc1, out1, err1 = pre()
if rc1 == 1 and out1:find("blocked:unsanctioned-workflow", 1, true)
    and err1:find("  remedy: remove the workflow files listed above", 1, true) then
    local _, outnc = pre()                                    -- negative control
    local still = outnc:find("blocked:unsanctioned-workflow", 1, true) ~= nil
    run({ "git", "-C", R, "rm", "-q", ".github/workflows/nightly.yml" })   -- the remedy
    run({ "git", "-C", R, "commit", "-qm", "remove unsanctioned workflow" })
    local rc2, out2 = pre()
    if still and not out2:find("blocked:unsanctioned-workflow", 1, true) then
        ok("ARM3 carrying out the remedy clears unsanctioned-workflow (re-run rc=" .. tostring(rc2) ..
            ", later gates may still speak); without it the refusal stands")
    else bad("ARM3 negative-control still=" .. tostring(still) .. " after rc=" .. tostring(rc2) ..
        " out='" .. oneline(out2) .. "'") end
else
    bad("ARM3 could not reproduce unsanctioned-workflow with its remedy: rc=" .. tostring(rc1) ..
        " out='" .. oneline(out1) .. "' err='" .. tail3(err1) .. "'")
end

proc.run{ argv = { "find", W, "-delete" } }
if failn > 0 then
    out.line("FAILED: release-preflight-affordances (1505-hedu)")
    verdict.emit("violation:release-preflight-affordances:" .. failn .. " failed", 1)
end
out.line("PASS: release-preflight-affordances (1505-hedu)")
verdict.emit("ok:release-preflight-affordances:3 arms", 0)
