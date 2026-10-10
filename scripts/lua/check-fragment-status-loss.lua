-- @trace spec:ci-release, order:1570-mxcg, order:635-i6vm
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- check-fragment-status-loss.lua — catch status transitions the fold silently
-- discards. PORTED from check-fragment-status-loss.sh (1570-mxcg); every pass,
-- verdict and advisory below is that script's, and its incident history is
-- kept in git (`git log -- scripts/check-fragment-status-loss.sh`).
--
-- THE TRAP (635-i6vm). `packets:` in a ledger fragment is a G-SET keyed by
-- packet_id: re-adding an existing packet is a NO-OP. Status is a separate
-- LWW-Register with its own `status:` channel. Re-declaring a packet with a new
-- status LOOKS exactly like recording a transition — it parses, validates and
-- reviews correctly — and the fold throws the status away. Measured 2026-08-09:
-- 11 of 21 fragment-recorded completions were still folding as `ready`.
--
-- WHAT THE PORT CHANGES, AND WHY THAT IS THE POINT. The .sh found the
-- `packets:` and `status:` rows with awk over indentation: a row was "a dash at
-- indent 0-4 whose key is packet_id or order", and that heuristic carried two
-- recorded false verdicts (864-hv2n: state leaking across files; 1319-vd5h /
-- 1331-884p: nested lists and flat rows lost or split). Here every fragment is
-- read with yaml.parse — the same parser the plan binary folds with (1375-btuf)
-- — and a row is a sequence item of the top-level key. A row splitter cannot be
-- wrong because there is none (1384-ddua: make the class unrepresentable).
-- Measured on yoga (1570-mxcg): the .sh took 16,537 ms over 937 fragments.
--
-- THE PLAN BINARY is still required: the fold (query --json) and the per-file
-- event verbs are its answers, not this script's. It is NAMED by the caller,
-- in this order: `-- --plan <path>`, TILLANDSIAS_PLAN_BIN (the probe's own
-- override), TILLANDSIAS_SCRIPT_RUNNER_BIN (set by build.sh's _run_lua_decider
-- to the runner it resolved) — because the caller already resolved it through
-- scripts/plan-binary-probe.sh to run this script at all (704-zcgi: one probe;
-- a second resolver here would be the drift it forbids).
-- Every call is argv through proc.run; no shell string anywhere.
--
-- WHAT THIS GATE CANNOT SEE, stated here so no reader has to find the .sh:
--   * plan/index.d ONLY. A closure already compacted into plan/index.yaml is
--     outside it; scripts/check-base-ledger-status-loss.sh is the (advisory)
--     reader of the base ledger.
--   * an UNKNOWN packet_id under `packets:` — that entry CREATES the packet,
--     so there is nothing to compare; unknown ids are caught only on the
--     `status:` block and on closure events, which declare without creating.
--   * the LWW `status:` channel is not compared for loss (it works); it is
--     asked only "does this packet exist?" (797-qm4t).
--   * advisories, NOT failures (699-dycj: historical fragments are append-only
--     and one host's typo must not redden every host): a non-terminal event on
--     an unknown packet, a packet definition misfiled under `events:`
--     (812-d45t), a status-block closure on an ARCHIVED row the resolver
--     reports applied, and a closure superseded by a later `falsified` event.
--   * with a plan binary predating fragment-terminal-events, the closure-event
--     pass is SKIPPED with a note (702-68zj), never approximated.
--   * whether a fragment PARSES is its own gate (added-fragments-parse,
--     698-7n6q), but that one is diff-scoped, so an unreadable fragment that
--     arrived by merge is refused HERE as UNPARSEABLE (787-f7dh).
--
-- GRAMMAR — exactly one stdout line (details go to stderr):
--   ok:no-fragment-status-loss:<n> checked         exit 0
--   violation:fragment-status-loss:<n>             exit 1
--   violation:fragment-status-loss:0               exit 2  (no plan binary)

local FRAG_DIR = "plan/index.d"

-- Terminal-set membership is the resolver's (is_terminal_status, 650-dq6u); a
-- guard laxer OR wider than the resolver is decorative (649-b2e4).
-- litmus:terminal-status-vocabulary-shape reads the `want == "<x>"` literals.
local function is_terminal(want)
    return want == "completed" or want == "verified" or want == "done" or want == "obsoleted"
end

-- ── the fragment set (direct children, C-sorted, as the .sh's glob) ─────────
local frags = {}
do
    local ok_walk, walked = pcall(fs.walk, FRAG_DIR)
    if ok_walk then
        for _, f in ipairs(walked) do
            local rel = f:sub(#FRAG_DIR + 2)
            if not rel:find("/", 1, true) and rel:match("%.yaml$") then
                frags[#frags + 1] = FRAG_DIR .. "/" .. rel
            end
        end
    end
    table.sort(frags)
end
-- FAST PATH: nothing to examine costs no subprocess at all.
if #frags == 0 then verdict.emit("ok:no-fragment-status-loss:0 checked", 0) end

-- ── PASS 1: (packet_id, status) declared under `packets:` (635-i6vm) ────────
-- ── PASS 1b: the LWW `status:` channel, unknown-packet question only (797-qm4t)
-- A fragment yaml.parse cannot read contributes nothing here; the event pass
-- below names it UNPARSEABLE and refuses (787-f7dh), so it is never silent.
local declared, declared_lww = {}, {}       -- list of {pid, want}, first-seen order
local rows_read = {}                        -- "<file>\t<pid>\t<status>", for --dump-declared
local seen_decl, seen_lww = {}, {}
local function str(v) if type(v) == "string" and v ~= "" then return v end end
for _, f in ipairs(frags) do
    local ok_r, content = pcall(fs.read, f)
    local ok_p, doc = false, nil
    if ok_r then ok_p, doc = pcall(yaml.parse, content) end
    if ok_p and type(doc) == "table" then
        if type(doc.packets) == "table" then
            for _, row in ipairs(doc.packets) do
                if type(row) == "table" then
                    local pid, want = str(row.packet_id), str(row.status)
                    if pid and want then rows_read[#rows_read + 1] = f .. "\t" .. pid .. "\t" .. want end
                    if pid and want and not seen_decl[pid .. "\t" .. want] then
                        seen_decl[pid .. "\t" .. want] = true
                        declared[#declared + 1] = { pid, want }
                    end
                end
            end
        end
        if type(doc.status) == "table" then
            for _, row in ipairs(doc.status) do
                if type(row) == "table" then
                    local pid, want = str(row.packet_id), str(row.value)
                    if pid and want and not seen_lww[pid .. "\t" .. want] then
                        seen_lww[pid .. "\t" .. want] = true
                        declared_lww[#declared_lww + 1] = { pid, want }
                    end
                end
            end
        end
    end
end
local function by_pair(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end
table.sort(declared, by_pair)
table.sort(declared_lww, by_pair)

-- `-- --dump-declared`: print every (file, packet_id, status) row pass 1 read,
-- one per line, and stop. The row-boundary fixture compares this against the
-- pre-port awk pass over the live corpus (1331-884p arm 4); it needs no binary.
for i = 1, #arg do
    if arg[i] == "--dump-declared" then
        for _, r in ipairs(rows_read) do out.line(r) end
        verdict.ok("fragment-status-loss-dump", #rows_read)
    end
end

-- ── the plan binary, as named by the caller ─────────────────────────────────
local PLAN
for i = 1, #arg do
    if arg[i] == "--plan" then PLAN = arg[i + 1] end
end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.emit("violation:fragment-status-loss:0", 2,
        "  tillandsias-plan not named (pass `-- --plan <path>`, TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN); cannot resolve the fold")
end

local function run(argv)
    return proc.run({ argv = argv, timeout_ms = 300000 })
end

local caps = {}
do
    local r = run({ PLAN, "capabilities" })
    if r.status == "exited" and r.code == 0 then
        for _, l in ipairs(text.lines(r.stdout or "")) do caps[text.trim(l)] = true end
    else
        verdict.emit("violation:fragment-status-loss:0", 2,
            "  " .. PLAN .. " does not run (capabilities: status=" .. tostring(r.status) .. "); cannot resolve the fold")
    end
end


-- ── PASS 2: closure events, any-event addressees, misplaced definitions ─────
-- Structural, per file, through the binary's framed verbs (752-pst5, 1307-kic6):
-- `<status>\t<path>\t<payload>`, one line per id, an `ok` line with an empty
-- payload for a fragment that declares nothing — "read it, found nothing" is
-- not "never read it" (787-f7dh). Batched so no argv outgrows Windows' ~32k
-- command line (1307-kic6 measured 1302 paths ≈ 91k characters).
local BATCH = 200
local function frames_for(verb)
    local out = {}
    for i = 1, #frags, BATCH do
        local argv = { PLAN, verb, "--files" }
        for j = i, math.min(i + BATCH - 1, #frags) do argv[#argv + 1] = frags[j] end
        local r = run(argv)
        for _, l in ipairs(text.lines(r.stdout or "")) do
            local st, path, payload = l:match("^([^\t]*)\t([^\t]*)\t?(.*)$")
            if st and st ~= "" then out[#out + 1] = { st, path, payload } end
        end
    end
    return out
end

local unparseable = {}
local declared_events, event_packets, misdef = {}, {}, {}
local function add_unique(list, set, v)
    if not set[v] then set[v] = true; list[#list + 1] = v end
end
if caps["fragment-terminal-events"] then
    local ev_set, any_set = {}, {}
    for _, fr in ipairs(frames_for("fragment-terminal-events")) do
        if fr[1] == "ok" then
            if fr[3] ~= "" then add_unique(declared_events, ev_set, fr[3]) end
        elseif fr[1] == "unparseable" or fr[1] == "unreadable" then
            unparseable[#unparseable + 1] = fr[2]
            log.raw("  " .. fr[1] .. ": " .. fr[2] .. ": " .. fr[3])
        end
    end
    if caps["fragment-event-packets"] then
        for _, fr in ipairs(frames_for("fragment-event-packets")) do
            if fr[1] == "ok" and fr[3] ~= "" then add_unique(event_packets, any_set, fr[3]) end
        end
    end
    if caps["fragment-misplaced-definitions"] then
        for _, fr in ipairs(frames_for("fragment-misplaced-definitions")) do
            if fr[1] == "ok" and fr[3] ~= "" then misdef[#misdef + 1] = fr[2] .. ": " .. fr[3] end
        end
    end
    table.sort(declared_events)
    table.sort(event_packets)
else
    -- 702-68zj: a binary predating the rule is STALE HOST STATE. The declared
    -- pass still runs; the event pass is skipped LOUDLY, never approximated.
    log.raw("  note: " .. PLAN .. " predates fragment-terminal-events — closure-event pass SKIPPED (rebuild with 'cargo build --release -p tillandsias-plan')")
end

-- ── AN UNREADABLE FRAGMENT REFUSES (787-f7dh) ───────────────────────────────
-- Above the independence check: what it might hide is unknowable.
if #unparseable > 0 then
    local d = {
        "  UNPARSEABLE fragment(s) — the closure-event pass could not read these,",
        "  so any terminal event they declare is UNEXAMINED, not absent:",
    }
    for _, f in ipairs(unparseable) do d[#d + 1] = f end
    d[#d + 1] = "  CAUSE: almost always an unquoted colon-space inside a summary or title."
    d[#d + 1] = "         Quote the value, or write it as a block scalar (summary: >)."
    d[#d + 1] = "  NOTE: added-fragments-parse (698-7n6q) is diff-scoped, so it does not"
    d[#d + 1] = "        see a malformed fragment that arrived by merge or hand edit."
    verdict.emit("violation:fragment-status-loss:" .. #unparseable, 1, table.concat(d, "\n"))
end

-- ── THE PASSES ARE INDEPENDENT (785-sqe6) ───────────────────────────────────
-- Only genuinely-nothing-to-examine exits early; an events-only fragment set
-- reaches the join. The misplaced-definition advisory keeps itself alive
-- (864-hv2n) rather than leaning on another pass's mistake.
if #declared == 0 and #declared_events == 0 and #misdef == 0 then
    verdict.emit("ok:no-fragment-status-loss:0 checked", 0)
end

-- ── THE FOLD, READ ONCE (783-xyk5) ──────────────────────────────────────────
-- One `query --json` instead of one `status` spawn per packet. FAIL-SAFE: if
-- the batch cannot be read, fall back to per-packet status, never to an empty
-- map (an empty map would silently pass every packet).
local st = {}
local have_map = false
if caps["query"] then
    local r = run({ PLAN, "query", "--json", "--limit", "0" })
    if r.status == "exited" and r.code == 0 then
        local ok_j, rows = pcall(json.parse, r.stdout or "")
        if ok_j and type(rows) == "table" then
            for _, row in ipairs(rows) do
                if type(row) == "table" and str(row.packet_id) then
                    st[row.packet_id] = type(row.status) == "string" and row.status or ""
                    have_map = true
                end
            end
        end
    end
end
local function status_of(pid)
    local r = run({ PLAN, "status", pid })
    if r.status == "exited" and r.code == 0 then
        local s = (r.stdout or ""):match("^[^\t\n]*\t([^\t\n]*)")
        if s and s ~= "" then return s end
    end
end
if not have_map then
    log.raw("  note: batched fold unavailable (" .. PLAN .. " query --json); falling back to per-packet status lookups")
    local asked = {}
    local function ask(pid)
        if asked[pid] then return end
        asked[pid] = true
        local s = status_of(pid)
        if s then st[pid] = s end
    end
    for _, p in ipairs(declared) do ask(p[1]) end
    for _, pid in ipairs(declared_events) do ask(pid) end
end

-- ── THE JOIN ────────────────────────────────────────────────────────────────
-- `checked` counts DISTINCT packet_ids examined by ANY pass (785-sqe6).
-- Order of the report: declared, status-block, closure-event, then advisories.
local seen, checked = {}, 0
local function examine(pid)
    if not seen[pid] then seen[pid] = true; checked = checked + 1 end
end
local dv, lv, ev, adv = {}, {}, {}, {}
for _, p in ipairs(declared) do
    local pid, want = p[1], p[2]
    examine(pid)
    -- A `packets:` entry CREATES the packet, so an unknown pid is unreachable
    -- here. A declaration the fold is AHEAD of is not a loss; only a terminal
    -- declaration the fold is BEHIND is.
    local got = st[pid]
    if got ~= nil and got ~= want and is_terminal(want) then
        dv[#dv + 1] = string.format("%s: declared '%s' in a fragment, folds as '%s'", pid, want, got)
    end
end
for _, p in ipairs(declared_lww) do
    local pid, want = p[1], p[2]
    examine(pid)
    if st[pid] == nil and is_terminal(want) then
        lv[#lv + 1] = { pid, want, string.format(
            "%s: declared '%s' in a fragment status block but NO SUCH PACKET is in the fold (typo, or filed against a deleted packet)", pid, want) }
    end
end
for _, pid in ipairs(declared_events) do
    examine(pid)
    local got = st[pid]
    if got == nil then
        ev[#ev + 1] = { pid, string.format(
            "%s: has a 'completed' EVENT but NO SUCH PACKET is in the fold (typo, or filed against a deleted packet)", pid), false }
    elseif not is_terminal(got) then
        -- A completed EVENT pairs with ANY closure-ladder terminal (650-dq6u).
        ev[#ev + 1] = { pid, string.format("%s: has a 'completed' EVENT but folds as '%s'", pid, got), true }
    end
end
for _, pid in ipairs(event_packets) do
    -- 797-qm4t: a note/progress aimed at a packet nobody filed is discarded
    -- silently. REPORTED, not failed (699-dycj: historical fragments are
    -- append-only, so one host's typo must not redden every host).
    examine(pid)
    if st[pid] == nil then
        adv[#adv + 1] = pid .. ": an events block addresses it but NO SUCH PACKET is in the fold (typo, or filed against a deleted packet) — that event was discarded"
    end
end
for _, a in ipairs(adv) do log.raw("  advisory: " .. a) end
for _, m in ipairs(misdef) do
    log.raw("  advisory: " .. m .. " is a packet DEFINITION under `events:` — the fold DROPS it; move it under the top-level `packets:` key")
end

-- `query` reads the LIVE fold only; per-packet `status` also answers from
-- plan/archive rows. A status-block closure of an ARCHIVED packet that the
-- resolver reports applied is supersession, not loss (2026-08-23, 829-dkuc).
local lv_kept = {}
for _, v in ipairs(lv) do
    local got = status_of(v[1])
    if got and got == v[2] then
        log.raw(string.format("  advisory: %s: declared '%s' targets an ARCHIVED row — absent from the live fold (query) but the resolver reports it applied; supersession of an archived packet, not a lost closure", v[1], v[2]))
    else
        lv_kept[#lv_kept + 1] = v[3]
    end
end

-- A REOPEN AFTER FALSIFICATION IS NOT STATUS LOSS (2026-09-12, 1115-yvrq): a
-- `falsified` event no older than the latest closure event supersedes it.
-- ISO-8601 Z timestamps, so string order is time order.
local ev_kept = {}
for _, v in ipairs(ev) do
    local rescued = false
    if v[3] then
        local r = run({ PLAN, "plan-events", v[1] })
        local c_ts, f_ts = "", ""
        for _, l in ipairs(text.lines(r.stdout or "")) do
            local typ, ts = l:match("^([^\t]*)\t([^\t]*)")
            if typ == "completed" or typ == "verified" or typ == "done" then
                if ts > c_ts then c_ts = ts end
            elseif typ == "falsified" then
                if ts > f_ts then f_ts = ts end
            end
        end
        if f_ts ~= "" and c_ts ~= "" and not (f_ts < c_ts) then
            rescued = true
            log.raw(string.format("  advisory: %s: closure event of %s is superseded by a falsified event at %s (reopened through 650-dq6u) — the non-terminal fold IS the reopen, not a lost transition", v[1], c_ts, f_ts))
        end
    end
    if not rescued then ev_kept[#ev_kept + 1] = v[2] end
end

local violations = {}
for _, v in ipairs(dv) do violations[#violations + 1] = v end
for _, v in ipairs(lv_kept) do violations[#violations + 1] = v end
for _, v in ipairs(ev_kept) do violations[#violations + 1] = v end

if #violations > 0 then
    local d = {}
    for _, v in ipairs(violations) do d[#d + 1] = "  " .. v end
    -- 696-6byc: one CAUSE/REMEDY per class that actually fired, independently.
    if #dv > 0 then
        d[#d + 1] = "  CAUSE (declared): `packets:` is a G-Set — re-declaring a packet does NOT change its status."
        d[#d + 1] = "  REMEDY (declared): write a NEW fragment with a `status:` entry (packet_id/field/value/ts/host)."
    end
    local any_event_fold = false
    for _, v in ipairs(ev_kept) do
        if v:find("EVENT but folds as", 1, true) then any_event_fold = true end
    end
    if any_event_fold then
        d[#d + 1] = "  CAUSE (event): a terminal event was recorded without the matching `status:` transition. Nothing was discarded, so nothing looks wrong — the packet just stays claimable forever."
        d[#d + 1] = "  REMEDY (event): decide which channel is telling the truth. If the closure IS real, add the `status:` entry. If it is NOT, the event type must match the rung — `set-field --evidence` derives it from the status since 696-6byc, so re-run it rather than hand-writing a terminal event."
    end
    d[#d + 1] = "          See plan/index.d/README.md."
    verdict.emit("violation:fragment-status-loss:" .. #violations, 1, table.concat(d, "\n"))
end

verdict.emit("ok:no-fragment-status-loss:" .. checked .. " checked", 0)
