-- @trace spec:ci-release, plan 698-7n6q, order:2223-afpl
-- @env TILLANDSIAS_FRAGMENT_PARSE_BASE TILLANDSIAS_GATE_DIFF_BASE TILLANDSIAS_SCRIPT_RUNNER_BIN TILLANDSIAS_PLAN_BIN
--
-- check-added-fragments-parse.lua — refuse a push that ADDS a ledger fragment
-- the fold cannot read. PORTED from check-added-fragments-parse.sh (2223-afpl):
-- same grammar, exit codes, diff scope and stderr blocks.
--
-- WHY THIS EXISTS. `tillandsias-plan check` warns that a fragment "does not
-- parse and was SKIPPED" and exits 0, so a fragment can reach origin carrying a
-- packet that exists in git and in NO ANSWER (697-s3by, 2026-08-12: an
-- unquoted colon-space read as a nested mapping).
--
-- DIFF-SCOPED BY CONSTRUCTION: only fragments ADDED or MODIFIED versus the base
-- ref (plus untracked and staged ones). You break it, your push fails; you
-- inherit it, `tillandsias-plan check` merely warns.
--
-- BARE TIMESTAMPS ARE ALSO REFUSED (720-24u6): `ts: 2026-08-12T15:31:54Z`
-- unquoted parses under serde_yaml, but compaction folds it verbatim into
-- plan/index.yaml, where Ruby's safe_load reads it as Time and the 440 status
-- gate can no longer load the base.
--
-- THE VALIDATOR is the runner itself (`validate-yaml`, 1454-ssg3): the .sh
-- preferred tillandsias-policy, then the plan binary, then yq; a Lua decider
-- always runs on a plan binary, so that binary is the one every host has. With
-- no plan binary the .sh shim keeps the .sh's refusal
-- (blocked:added-fragments-parse:no-validator), never a green.
--
--   ok:added-fragments-parse:<n> checked
--   violation:added-fragment-unparseable:<n>       exit 1
--   violation:added-fragment-bare-timestamp:<n>    exit 1
--   blocked:added-fragments-parse:no-validator     exit 1
--
-- The repo is the CALLER's checkout (git in its PWD), as the .sh's was the
-- checkout its copy sat in.

local FRAG_DIR = "plan/index.d"
local function run(argv, ms) return proc.run({ argv = argv, timeout_ms = ms or 120000 }) end
local function okr(r) return r.status == "exited" and r.code == 0 end
local function split(s)
    local t = {}
    for l in ((s or "") .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = l end
    if t[#t] == "" then t[#t] = nil end
    return t
end

local top = run({ "git", "rev-parse", "--show-toplevel" }, 30000)
local ROOT = text.trim(top.stdout or "")
if not okr(top) or ROOT == "" then
    verdict.emit("ok:added-fragments-parse:0 checked", 0, "  note: not inside a git checkout — added-fragment enforcement skipped")
end
local function git(...) local a = { "git", "-C", ROOT }; for _, v in ipairs({ ... }) do a[#a + 1] = v end; return run(a) end

local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or ""
if PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") or "" end
local caps = PLAN ~= "" and run({ PLAN, "capabilities" }, 30000) or { stdout = "" }
local has_validate = false
for _, l in ipairs(split(caps.stdout)) do if text.trim(l) == "validate-yaml" then has_validate = true end end
if not has_validate then
    verdict.emit("blocked:added-fragments-parse:no-validator", 1,
        "  why: no YAML validator resolves (the runner names no tillandsias-plan with validate-yaml),\n"
        .. "  so an unparseable fragment would pass unread.\n"
        .. "  remedy: cargo build --release -p tillandsias-plan")
end

local base = env.get("TILLANDSIAS_FRAGMENT_PARSE_BASE") or ""
if base == "" then base = env.get("TILLANDSIAS_GATE_DIFF_BASE") or "" end
if base == "" then base = "origin/linux-next" end
if not okr(git("rev-parse", "--verify", "--quiet", base .. "^{commit}")) then
    verdict.emit("ok:added-fragments-parse:0 checked", 0,
        "  note: base ref '" .. base .. "' unavailable — added-fragment enforcement skipped")
end

local seen, cands = {}, {}
for _, r in ipairs({
    git("diff", "--name-only", "--diff-filter=AM", base, "--", FRAG_DIR .. "/*.yaml"),
    git("ls-files", "--others", "--exclude-standard", "--", FRAG_DIR .. "/*.yaml"),
    git("diff", "--name-only", "--cached", "--diff-filter=AM", "--", FRAG_DIR .. "/*.yaml"),
}) do
    for _, f in ipairs(split(r.stdout)) do
        if f ~= "" and not seen[f] then seen[f] = true; cands[#cands + 1] = f end
    end
end
table.sort(cands)

local checked, violations, bare_ts = 0, 0, 0
for _, f in ipairs(cands) do
    local abs = ROOT .. "/" .. f
    local cat = run({ "cat", abs }, 30000)
    if okr(cat) then -- deleted (e.g. folded by compaction): nothing to parse
        checked = checked + 1
        -- grep -nE '^[[:space:]]*ts:[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}' minus quoted values
        local bare = {}
        for n, l in ipairs(split(cat.stdout)) do
            if l:match("^%s*ts:%s+%d%d%d%d%-%d%d%-%d%d") then bare[#bare + 1] = n .. ":" .. l end
        end
        if #bare > 0 then
            bare_ts = bare_ts + 1
            local head = {}
            for i = 1, math.min(3, #bare) do head[#head + 1] = bare[i] end
            log.raw("REFUSED: " .. f .. " writes an UNQUOTED timestamp — it parses here, but compaction folds it\n"
                .. "         verbatim into plan/index.yaml, where Ruby reads a bare ISO-8601 scalar as\n"
                .. "         Time (a disallowed class) and the 440 status-vocab gate can no longer load\n"
                .. "         the base. Quote the value: ts: \"2026-08-12T15:31:54Z\".\n"
                .. "   " .. table.concat(head, "\n") .. "\n")
        end
        local v = run({ PLAN, "validate-yaml", abs }, 60000)
        if not okr(v) then
            violations = violations + 1
            local err = split(v.stderr)[1] or ""
            log.raw("REFUSED: " .. f .. " does not parse — the fold will SKIP it and its packets will exist in git and in no answer.\n"
                .. "   " .. err .. "\n")
        end
    end
end

if violations > 0 then verdict.emit("violation:added-fragment-unparseable:" .. violations, 1) end
if bare_ts > 0 then verdict.emit("violation:added-fragment-bare-timestamp:" .. bare_ts, 1) end
verdict.emit("ok:added-fragments-parse:" .. checked .. " checked", 0)
