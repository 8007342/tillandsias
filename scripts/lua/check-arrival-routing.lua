-- @env TILLANDSIAS_ROUTING_BASE TILLANDSIAS_GATE_DIFF_BASE TILLANDSIAS_PLAN_BIN CARGO_TARGET_DIR PATH HOME
-- @trace spec:ci-release, order:831-ezea, order:702-68zj, order:785-sqe6, order:787-f7dh, order:2400-ejm8
--
-- check-arrival-routing.lua — name the rows this change FILED that were not independently
-- schedulable. Ported from the .sh of the same name; the grammar, the exits and the stderr advisory
-- are unchanged.
--
-- Order 831-ezea, the ARRIVAL half (its sibling check-carry-forward asks whether a cycle left the
-- rows it TOUCHED resumable). THE RULE (methodology/distributed-work.yaml ->
-- new_row_only_if_independently_schedulable): a finding becomes a new ROW only if it names
-- owned_files no open row already owns, OR a different pickup_role can claim it than every open row
-- covering that scope. Otherwise it is a next_action clause or an event on that row. Arrivals were
-- measured at lambda = 2.2 + 1.80*mu (r = 0.868): at b = 1.80 every extra cycle fills the ready queue
-- faster than it drains. Every other budget caps SERVICE; this is the one rule that touches ARRIVAL.
--
-- WHAT THIS CHECKS: owned_files overlap with an OPEN row, through answer.rs owned_file_owners (the
-- same fold answer_next uses; one implementation in the crate), plus a labelled weaker heuristic:
-- normalized deliverable/title EQUALITY. NOT CHECKED: the pickup_role disjunct (both roles are
-- printed, nothing is decided), whether two rows are "really" one piece of work, rows filed anywhere
-- but a new fragment.
--
-- ADVISORY, NOT A GATE, with the number that would make it one. Measured 2026-08-21: OPEN rows
-- carrying owned_files were 3/490 = 0.6%, so a blocking gate on that predicate would be GREEN BECAUSE
-- ITS INPUT IS EMPTY. PROMOTION BAR: (1) owned_files: make the advisory exit 1 (and give build.sh an
-- _error branch) once OPEN rows carrying owned_files reach >= 40%; (2) deliverable/title: NEVER
-- promote, because free-text equality already collides on 43 of 490 legitimate open rows (699-dycj).
--
-- DIFF-SCOPED: only rows newly defined by fragments this change ADDS against the base ref
-- (TILLANDSIAS_ROUTING_BASE, else TILLANDSIAS_GATE_DIFF_BASE, else origin/linux-next). "Newly
-- defined" is the fold's origin_source_of, so a re-declared packet is not an arrival.
--
-- GRAMMAR, exactly one line on stdout:
--   ^(ok:arrival-routing:[0-9]+ of [0-9]+ new rows|advisory:arrival-routing:[0-9]+ of [0-9]+ new rows|skipped:arrival-routing:(no-plan-binary|stale-plan-binary|no-diff-base|unreadable-fragment)|fail:arrival-routing:checker-exit-[0-9]+)$
-- Exit 0 on ok/advisory/skipped; 1 only when the pass CANNOT RUN. A pass that never ran never says ok.
--
-- Usage: tillandsias-plan script run scripts/lua/check-arrival-routing.lua

-- ORDER 2246-fkea, inlined: a decider run from a scratch copy has no lib/ beside it.
local SH
do
    local r = proc.run{ argv = { "git", "--exec-path" }, timeout_ms = 10000 }
    local ep = text.trim(r.stdout or "")
    if ep:find("^%a:/.*/libexec/git%-core$") then SH = (ep:gsub("/[^/]+/libexec/git%-core$", "/bin/bash.exe")) end
    SH = SH or "bash"
end
local function eget(k) local v = env.get(k); if v == nil or v == "" then return nil end; return v end
local function note(s) log.raw(s) end

local FRAG_DIR = "plan/index.d"
if not fs.exists(FRAG_DIR) then verdict.emit("ok:arrival-routing:0 of 0 new rows", 0) end

-- One probe, shared with every script that needs the binary (704-zcgi); it resolves by EXECUTION
-- (721-nyev). plan_binary_has asks the binary itself whether it knows the subcommand (702-68zj).
local probe = proc.run{ argv = { SH, "-s" }, timeout_ms = 120000, stdin = [==[
. scripts/plan-binary-probe.sh
p="$(resolve_plan_binary)" || p=""
[ -n "$p" ] || { echo "none"; exit 0; }
case "$p" in ./*) p="$(pwd)/${p#./}" ;; esac
if plan_binary_has "$p" arrival-routing-check; then echo "ok $p"; else echo "stale $p"; fi
]==] }
local pr = text.trim((probe.stdout or ""):gsub("\r", ""))
local kind, PLAN = pr:match("^(%S+) ?(.*)$")
if kind ~= "ok" and kind ~= "stale" then
    note("  tillandsias-plan not built; the arrival-routing pass did not run")
    verdict.emit("skipped:arrival-routing:no-plan-binary", 0)
end
if kind == "stale" then
    note("  note: " .. PLAN .. " predates arrival-routing-check — pass SKIPPED (rebuild with 'cargo build --release -p tillandsias-plan')")
    verdict.emit("skipped:arrival-routing:stale-plan-binary", 0)
end

local function git(...)
    local r = proc.run{ argv = { "git", ... }, timeout_ms = 120000 }
    return r.stdout or "", r.code
end
local base = eget("TILLANDSIAS_ROUTING_BASE") or eget("TILLANDSIAS_GATE_DIFF_BASE") or "origin/linux-next"
local _, vrc = git("rev-parse", "--verify", "--quiet", base .. "^{commit}")
if vrc ~= 0 then
    -- No base, no diff scope; a whole-ledger fallback is exactly the gate this refuses to be.
    note("  note: base ref '" .. base .. "' unavailable — set TILLANDSIAS_ROUTING_BASE to scope the pass")
    verdict.emit("skipped:arrival-routing:no-diff-base", 0)
end

-- Fragments this change ADDS: added vs base, staged-added, and wholly untracked. --diff-filter=A
-- only: a fragment is immutable once written, so a MODIFIED one is not a new arrival.
local seen, files = {}, {}
local function add(out)
    for f in ((out or ""):gsub("\r", "")):gmatch("([^\n]+)") do
        if not seen[f] and f:match("%.yaml$") and fs.exists(f) then seen[f] = true; files[#files + 1] = f end
    end
end
add((git("diff", "--name-only", "--diff-filter=A", base, "--", FRAG_DIR .. "/*.yaml")))
add((git("diff", "--name-only", "--cached", "--diff-filter=A", "--", FRAG_DIR .. "/*.yaml")))
add((git("ls-files", "--others", "--exclude-standard", "--", FRAG_DIR .. "/*.yaml")))
table.sort(files)
if #files == 0 then verdict.emit("ok:arrival-routing:0 of 0 new rows", 0) end

-- ONE invocation for the whole set: the arm loads the folded ledger, and paying that per fragment
-- would scale the gate's cost with how much a cycle filed. Run through the shell so an override that
-- is a script still starts on Windows; its own exit status is read, never a pipeline's.
local argv = { SH, "-s", "--", PLAN, "arrival-routing-check" }
for _, f in ipairs(files) do argv[#argv + 1] = f end
local r = proc.run{ argv = argv, timeout_ms = 600000, stdin = 'exec "$@" 2>/dev/null\n' }
local rc = r.code
if rc == 3 then
    -- An unreadable named fragment contributes NO packets, so "no arrivals" and "unreadable" would be
    -- one answer. check-added-fragments-parse already hard-refuses this class; this one only says so.
    note("  note: a fragment this change adds does not parse — its rows are UNEXAMINED by the arrival rule, not cleared by it (see check-added-fragments-parse.lua)")
    verdict.emit("skipped:arrival-routing:unreadable-fragment", 0)
end
if rc ~= 0 then
    note("  the arrival-routing pass could not run (tillandsias-plan arrival-routing-check exited " .. tostring(rc) .. ") — that is a broken checkout, not a clean ledger")
    verdict.emit("fail:arrival-routing:checker-exit-" .. tostring(rc), 1)
end

-- `population|<n>` is the first line; `overlap|<id>|<predicate>|<sentence>` lines follow.
local population, flagged, sentences = nil, {}, {}
for line in ((r.stdout or ""):gsub("\r", "")):gmatch("([^\n]*)\n?") do
    if not population then population = line:match("^population|(.*)$") end
    local id, predicate, sentence = line:match("^overlap|([^|]*)|([^|]*)|(.*)$")
    if id then
        flagged[id] = true
        if sentence ~= "" then sentences[#sentences + 1] = "  advisory[" .. predicate .. "]: " .. sentence end
    end
end
if not population or not population:match("^%d+$") then
    note("  the checker exited 0 without declaring its population — refusing to report a count over an unknown denominator")
    verdict.emit("fail:arrival-routing:checker-exit-0", 1)
end
local n = 0
for _ in pairs(flagged) do n = n + 1 end
if n == 0 then verdict.emit("ok:arrival-routing:0 of " .. population .. " new rows", 0) end

for _, s in ipairs(sentences) do note(s) end
note("  RULE: methodology/distributed-work.yaml -> new_row_only_if_independently_schedulable. A finding is a NEW ROW only if it names owned_files no open row already owns, OR a different pickup_role can claim it than every open row covering that scope.")
note("  REMEDY if it is NOT independently schedulable: put it on the row it overlaps instead of beside it —")
note("          tillandsias-plan set-field <id|order> next_action \"<first concrete command or edit>\" --reason \"arrival routing\"")
note("          or append an event to that row. accumulate_then_promote: observations that are not schedulable accumulate as events; promotion to a row is TLATOANI-GATED.")
note("  REMEDY if it IS independently schedulable: say so on the new row — give it owned_files that do not overlap, or a pickup_role that differs from the row named above.")
note("  NOT DECIDED HERE: the pickup_role disjunct, and whether two rows are really the same work. Both roles are printed above; the call is yours.")
note("  ADVISORY ONLY: open rows carrying owned_files are 0.6% (3/490, measured 2026-08-21), so the rule's own predicate is nearly blind today. Promotion bar and its two clauses are in the header of this file.")
verdict.emit("advisory:arrival-routing:" .. n .. " of " .. population .. " new rows", 0)
