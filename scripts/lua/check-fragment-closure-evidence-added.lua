-- @env PWD TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN TILLANDSIAS_CLOSURE_EVIDENCE_BASE TILLANDSIAS_GATE_DIFF_BASE
-- @trace spec:ci-release, order:686-7qcm, order:702-68zj, order:1024-c3h3
--
-- check-fragment-closure-evidence-added.lua — 686-7qcm criterion 3. Refuse a
-- change that ADDS a ledger fragment recording a closure rung
-- (completed/verified/done) with NO evidence-bearing event for that packet.
-- (Ported from scripts/check-fragment-closure-evidence-added.sh, the
-- shell-to-lua item carried by order 2166-ypfh; history in
-- `git log -- scripts/check-fragment-closure-evidence-added.sh`.)
--
-- WHY. set-field already requires --evidence for a closure rung, but a fragment
-- HAND-AUTHORED under packets:/status: bypasses it. This is the gate-time
-- backstop; the per-file rule is `tillandsias-plan closure-evidence-check`.
--
-- DIFF-SCOPED (698-7n6q): only fragments added or modified versus the base
-- ref, staged, or wholly untracked. Standing history is never re-judged.
--
-- Grammar (one line on stdout), unchanged from the .sh:
--   ^(ok:closure-evidence:[0-9]+ checked|violation:closure-without-evidence:[0-9]+|skip:stale-plan-binary)$
-- Exit 0 on ok and on the skip; 1 on a violation.
--
-- skip:stale-plan-binary (702-68zj): the named binary predates the rule. That
-- is stale HOST state, not a ledger defect, and not a pass dressed as one.
--
-- 1024-c3h3 (advisory, stderr): an evidence_refs SHA reachable from neither
-- the base ref nor HEAD is what a pre-landing SHA looks like after a rebase.
--
-- THE RULE'S BINARY is named by `-- --plan <bin>`, TILLANDSIAS_PLAN_BIN, or
-- TILLANDSIAS_SCRIPT_RUNNER_BIN (build.sh's _run_lua_decider). It may differ
-- from the runner — that is how the stale-binary litmus arm hands it a stub.
-- Unnamed: `ok:closure-evidence:0 checked` with a note, as the .sh did when
-- no binary was built.
--
-- WHERE IT LOOKS: every git call, file test and fragment read runs in the
-- caller's PWD (2166-zvst): the landing fixture runs this from a scratch repo,
-- and the runner's default cwd is its repository root, which env may point
-- elsewhere. Fragment reads are a child `cat` for the same reason (fs.* is
-- confined to the runner's root).

local NAME = "closure-evidence"
local function caller_dir()
    local d = env.get("PWD")
    if d ~= nil and d ~= "" and (d:sub(1, 1) == "/" or d:match("^%a:[/\\]")) then return d end
    return nil
end
local CALLER = caller_dir()
local function run(argv, timeout)
    return proc.run({ argv = argv, cwd = CALLER, timeout_ms = timeout or 60000 })
end
local function ok(r) return r.status == "exited" and r.code == 0 end
local function git(...) return run({ "git", ... }) end
local function lines(s)
    local t = {}
    for l in (s or ""):gmatch("[^\n]+") do t[#t + 1] = l end
    return t
end

local PLAN = nil
for i = 1, #arg do if arg[i] == "--plan" then PLAN = arg[i + 1] end end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.emit("ok:" .. NAME .. ":0 checked", 0,
        "  note: tillandsias-plan not named — closure-evidence gate skipped")
end

local caps = run({ PLAN, "capabilities" }, 30000)
local has = false
for _, l in ipairs(lines(caps.stdout)) do if text.trim(l) == "closure-evidence-check" then has = true end end
if not has then
    verdict.emit("skip:stale-plan-binary", 0,
        "  note: " .. PLAN .. " predates closure-evidence-check — rebuild with 'cargo build --release -p tillandsias-plan' to enable this gate")
end

local base = env.get("TILLANDSIAS_CLOSURE_EVIDENCE_BASE")
if base == nil or base == "" then base = env.get("TILLANDSIAS_GATE_DIFF_BASE") end
if base == nil or base == "" then base = "origin/linux-next" end
if not ok(git("rev-parse", "--verify", "--quiet", base .. "^{commit}")) then
    verdict.emit("ok:" .. NAME .. ":0 checked", 0,
        "  note: base ref '" .. base .. "' unavailable — closure-evidence enforcement skipped")
end

local SPEC = "plan/index.d/*.yaml"
local seen, candidates = {}, {}
for _, argv in ipairs{
    { "diff", "--name-only", "--diff-filter=AM", base, "--", SPEC },
    { "ls-files", "--others", "--exclude-standard", "--", SPEC },
    { "diff", "--name-only", "--cached", "--diff-filter=AM", "--", SPEC },
} do
    local r = git(table.unpack(argv))
    for _, f in ipairs(ok(r) and lines(r.stdout) or {}) do
        if not seen[f] then seen[f] = true; candidates[#candidates + 1] = f end
    end
end
table.sort(candidates)

local function is_file(f) return ok(run({ "test", "-f", f }, 10000)) end

local checked, violations = 0, 0
local present = {}
for _, f in ipairs(candidates) do
    if is_file(f) then
        present[#present + 1] = f
        checked = checked + 1
        local r = run({ PLAN, "closure-evidence-check", f })
        if not ok(r) then
            violations = violations + 1
            local out = (r.stdout or "") .. (r.stderr or "")
            for _, l in ipairs(lines(out)) do log.raw("  " .. l) end
        end
    end
end

-- 1024-c3h3: evidence_refs SHAs that are not upstream (advisory).
local ghosts = 0
for _, f in ipairs(present) do
    local body = run({ "cat", f }, 10000)
    for l in (body.stdout or ""):gmatch("[^\n]+") do
        local sha = l:match("evidence_refs:%s*(%x%x%x%x%x%x%x+)")
        if sha and #sha <= 40 and ok(git("cat-file", "-e", sha .. "^{commit}"))
            and not ok(git("merge-base", "--is-ancestor", sha, base))
            and not ok(git("merge-base", "--is-ancestor", sha, "HEAD")) then
            ghosts = ghosts + 1
            log.raw("  evidence-ref-not-upstream: " .. sha .. " (in " .. f .. ")")
            log.raw("    It is reachable from neither " .. base .. " nor the commit being pushed,")
            log.raw("    which is what a pre-landing SHA looks like after the rebase (1024-c3h3).")
            local s = git("log", "-1", "--format=%s", sha)
            local subj = ok(s) and text.trim(s.stdout or "") or ""
            if subj ~= "" then
                local landed = nil
                local lg = git("log", "--format=%H %s", base, "-n", "400")
                for _, ll in ipairs(ok(lg) and lines(lg.stdout) or {}) do
                    local h, rest = ll:match("^(%x+) (.*)$")
                    if h and rest and rest:find(subj, 1, true) then landed = h; break end
                end
                if landed then
                    log.raw("    The landed commit with the same subject is " .. landed .. ".")
                    log.raw("    Cite that one; it is the SHA a reader can follow.")
                else
                    log.raw("    Subject: " .. subj)
                    log.raw("    No commit with that subject is on " .. base .. " — this may be work")
                    log.raw("    that genuinely never landed, which is the OTHER diagnosis.")
                end
            end
        end
    end
end

if violations > 0 then
    verdict.emit("violation:closure-without-evidence:" .. violations, 1,
        "  why: an added fragment records a closure rung with no evidence-bearing event for that packet (686-7qcm)\n" ..
        "  remedy: write the closure with `tillandsias-plan set-field ... --evidence`, or add the completed event with evidence_refs to the same fragment")
end
if ghosts > 0 then
    log.raw("  ⚠ " .. ghosts .. " evidence ref(s) name a commit that is not upstream (1024-c3h3, advisory)")
end
verdict.emit("ok:" .. NAME .. ":" .. checked .. " checked", 0)
