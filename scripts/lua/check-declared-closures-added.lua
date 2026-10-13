-- @trace spec:spec-traceability, order:885-92iu, order:1642-cc54
-- @env TILLANDSIAS_DECLARED_CLOSURES_BASE TILLANDSIAS_GATE_DIFF_BASE TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- check-declared-closures-added.lua — refuse a NEWLY FILED packet whose
-- `verifiable_closure` names a litmus test that cannot run. (Ported from
-- scripts/check-declared-closures-added.sh: the shell-to-lua item 1642-cc54
-- carried. Its history is in `git log -- scripts/check-declared-closures-added.sh`.)
--
-- WHY THIS EXISTS. Order 721-77yu established the defect for shell scripts:
-- a "Pinned by litmus:<x>" header that READS as verification and supplies
-- none, in two shapes — `unresolvable` (no test declares that name) and
-- `unbound` (the file exists but no spec binds it, and execution is
-- binding-driven, so it runs in no suite). The LEDGER carries the same empty
-- claim with more weight: methodology/convergence.yaml makes the verifiable
-- closure the thing that distinguishes a reduction from a restatement.
-- Measured: packet 795-5itp declared `litmus:one-length-delimited-framing-impl`
-- on 2026-08-17, and that string existed only in the field itself for eight
-- days while three slices landed against it and `./build.sh --check` stayed green.
--
-- SCOPE IS DELIBERATE AND NARROW. Only fragments ADDED or MODIFIED versus the
-- base ref, staged ones, and wholly-untracked ones — new debt refused at the
-- door. The base ledger's standing debt is reported, exit 0, by
-- `tillandsias-plan declared-closures`, never redded here.
--
-- WHAT THE PORT CHANGES. The .sh resolved its own plan binary and, with none,
-- printed ok and PASSED — a gate that was a no-op on a cold tree (1009-gccx
-- hoisted it above the build for exactly that reason, and 1034-ihxw moved it
-- back). Here the binary is NAMED by the caller (TILLANDSIAS_PLAN_BIN, then
-- TILLANDSIAS_SCRIPT_RUNNER_BIN, which build.sh's _run_lua_decider sets to the
-- runner it resolved: 704-zcgi, one probe), and a run with none is
-- could-not-run, never ok. Every call is argv through proc.run.
--
-- Grammar (one line on stdout; details on stderr):
--   ok:declared-closures:<n> checked                              exit 0
--   violation:declared-closure-unresolvable:<n>                   exit 1
--   skip:stale-plan-binary                                        exit 0
--   could-not-run:declared-closures                               exit 3  (no plan binary named; reason on stderr)
--
-- Pinned by litmus:declared-closure-resolves.

local FRAG_DIR = "plan/index.d"

local function nonempty(v) return v ~= nil and v ~= "" end
local base_ref = env.get("TILLANDSIAS_DECLARED_CLOSURES_BASE")
if not nonempty(base_ref) then base_ref = env.get("TILLANDSIAS_GATE_DIFF_BASE") end
if not nonempty(base_ref) then base_ref = "origin/linux-next" end

local BIN = env.get("TILLANDSIAS_PLAN_BIN")
if not nonempty(BIN) then BIN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not nonempty(BIN) then
    verdict.could_not_run("declared-closures", "no-plan-binary — run through build.sh's _run_lua_decider, or set TILLANDSIAS_PLAN_BIN")
end

-- Same ruling as order 702-68zj: a binary predating the rule is stale HOST
-- state, not a ledger defect. Skip, name it, pass.
local caps = proc.run({ argv = { BIN, "capabilities" }, timeout_ms = 30000 })
local has = false
for _, c in ipairs(text.lines(caps.stdout or "")) do
    if text.trim(c) == "declared-closures-check" then has = true; break end
end
if caps.status ~= "exited" or caps.code ~= 0 or not has then
    log.raw("  note: " .. BIN .. " predates declared-closures-check — rebuild with 'cargo build --release -p tillandsias-plan' to enable this gate")
    verdict.emit("skip:stale-plan-binary", 0)
end

local function git(argv)
    local r = proc.run({ argv = argv, timeout_ms = 60000 })
    if r.status ~= "exited" or r.code ~= 0 then return nil end
    return r.stdout or ""
end

if not git({ "git", "rev-parse", "--verify", "--quiet", base_ref }) then
    log.raw("  note: base ref '" .. base_ref .. "' unavailable — declared-closures enforcement skipped")
    verdict.ok("declared-closures", "0 checked")
end

local spec = FRAG_DIR .. "/*.yaml"
local seen, candidates = {}, {}
for _, argv in ipairs({
    { "git", "diff", "--name-only", "--diff-filter=AM", base_ref, "--", spec },
    { "git", "ls-files", "--others", "--exclude-standard", "--", spec },
    { "git", "diff", "--name-only", "--cached", "--diff-filter=AM", "--", spec },
}) do
    for _, f in ipairs(text.lines(git(argv) or "")) do
        f = text.trim(f)
        if f ~= "" and not seen[f] then
            seen[f] = true
            candidates[#candidates + 1] = f
        end
    end
end
table.sort(candidates)

local checked, violations = 0, 0
for _, f in ipairs(candidates) do
    if fs.exists(f) then
        checked = checked + 1
        local r = proc.run({ argv = { BIN, "declared-closures-check", f }, timeout_ms = 60000 })
        if r.status ~= "exited" or r.code ~= 0 then
            violations = violations + 1
            for _, l in ipairs(text.lines((r.stdout or "") .. (r.stderr or ""))) do
                if l ~= "" then log.raw("  " .. l) end
            end
        end
    end
end

if violations > 0 then
    verdict.emit("violation:declared-closure-unresolvable:" .. violations, 1)
end
verdict.ok("declared-closures", checked .. " checked")
