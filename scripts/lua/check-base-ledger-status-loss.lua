-- @env PATH HOME BASE_STATUS_LOSS_ROOT BASE_STATUS_LOSS_INDEX TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:751-i9mb, order:787-f7dh, spec:methodology-accountability, order:2390-byz6
--
-- check-base-ledger-status-loss.lua — the closure-event pass, applied where the events ACTUALLY LIVE.
--
-- scripts/lua/check-fragment-status-loss.lua reads plan/index.d/ only. Compaction folds every fragment into
-- plan/index.yaml, so a closure event moves where that checker cannot see. Measured 2026-08-15: packet 532 read
-- `in_progress` while its work was done and on the remote; a `claim` landed after both closure events. The
-- gate was green throughout, because the packet no longer lived in a fragment.
--
-- ADVISORY, EXIT 0 ALWAYS, and a separate decider: the fragment checker is a hard gate, and folding an advisory
-- into a gate makes one exit code carry two severities; the first false positive on a historical row would turn
-- the gate off. It corrects nothing: a terminal event beside a non-terminal status is a question for a cycle
-- (532 was only closable because its litmus was re-run and passed). Branch on the verdict, never the exit code.
-- Ported from the .sh of the same name.
--
-- Usage: tillandsias-plan script run scripts/lua/check-base-ledger-status-loss.lua
--   BASE_STATUS_LOSS_ROOT names another checkout (a fixture's), BASE_STATUS_LOSS_INDEX another base.
-- Verdict (one line on stdout, exit 0):
--   ok:no-base-status-loss:<n> checked | advisory:base-status-loss:<n> (each named on stderr)
--   skip:no-base-ledger | skip:plan-binary-unavailable
--   skip:base-ledger-unparseable   (787-f7dh: NOT ok:, an unexamined ledger is not a clean one)

local function nonempty(v) return v ~= nil and v ~= "" end
local ROOT = env.get("BASE_STATUS_LOSS_ROOT")
if not nonempty(ROOT) then ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 }).stdout or "") end
local BASE = env.get("BASE_STATUS_LOSS_INDEX")
if not nonempty(BASE) then BASE = "plan/index.yaml" end
local BASE_ABS = (BASE:sub(1, 1) == "/" or BASE:find("^%a:[/\\]")) and BASE or (ROOT .. "/" .. BASE)
if not fs.exists(BASE_ABS) then verdict.emit("skip:no-base-ledger", 0) end

-- The plan binary, resolved by execution (721-nyev) through the shared probe unless the runner handed one down.
local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN")
if not nonempty(PLAN) then
    local ep = text.trim(proc.run({ argv = { "git", "--exec-path" }, timeout_ms = 10000 }).stdout or "")
    local sh = ep:find("^%a:/.*/libexec/git%-core$") and (ep:gsub("/[^/]+/libexec/git%-core$", "/bin/bash.exe")) or "bash"
    local r = proc.run({ argv = { sh, "-s", "--", ROOT }, timeout_ms = 60000,
        stdin = 'cd "$1" || exit 1\n. scripts/plan-binary-probe.sh 2>/dev/null || exit 1\np="$(resolve_plan_binary)" || exit 1\n'
            -- native-argv: the /c/... answer is made C:/... by cygpath -m on the next line of the script
            .. 'case "$p" in ./*) p="$PWD/${p#./}" ;; esac\ncommand -v cygpath >/dev/null 2>&1 && p="$(cygpath -m "$p")"\nprintf "%s" "$p"\n' })
    PLAN = r.code == 0 and text.trim(r.stdout or "") or ""
end
if not nonempty(PLAN) then
    log.raw("  note: tillandsias-plan is not built, so the base closure pass did not run.")
    verdict.emit("skip:plan-binary-unavailable", 0)
end
local function plan(argv)
    table.insert(argv, 1, PLAN)
    return proc.run({ argv = argv, cwd = ROOT, timeout_ms = 120000 })
end
local caps = "\n" .. ((plan{ "capabilities" }.stdout or ""):gsub("\r", "")) .. "\n"
local function has(c) return caps:find("\n" .. c .. "\n", 1, true) ~= nil end
-- A binary predating the subcommand, or its base-ledger walk (751-i9mb), would report every base clean.
if not has("fragment-terminal-events") then
    log.raw("  note: this tillandsias-plan predates fragment-terminal-events; rebuild it (scripts/cycle-preflight.sh).")
    verdict.emit("skip:plan-binary-unavailable", 0)
end

-- --live applies the withdrawal rule: a closure a later `falsified` retracted is not a live declaration.
local d = plan{ "fragment-terminal-events", BASE_ABS, "--live" }
if d.code == 3 then
    log.raw("  note: " .. BASE .. " did not parse, so every terminal event it declares is UNEXAMINED.")
    verdict.emit("skip:base-ledger-unparseable", 0)
end
local declared, seen = {}, {}
for p in ((d.stdout or ""):gsub("\r", "")):gmatch("[^\n]+") do
    if not seen[p] then seen[p] = true; declared[#declared + 1] = p end
end
if #declared == 0 then verdict.emit("ok:no-base-status-loss:0 checked", 0) end

-- The FOLDED status is the question, read once (783-xyk5). A packet absent from the live fold is SKIPPED, not
-- reported: an archived row would otherwise read adrift on every run.
local st
if has("query") then
    local q = plan{ "query", "--json", "--limit", "0" }
    local ok_, rows = pcall(json.parse, q.code == 0 and q.stdout or "")
    if ok_ and type(rows) == "table" then
        st = {}
        for _, row in ipairs(rows) do
            if type(row) == "table" and type(row.packet_id) == "string" and row.packet_id ~= "" then
                st[row.packet_id] = type(row.status) == "string" and row.status or ""
            end
        end
    end
end
if not st then
    log.raw("  note: batched fold unavailable (" .. PLAN .. " query --json); falling back to per-packet status lookups")
    st = {}
    for _, p in ipairs(declared) do
        local s = (plan{ "status", p }.stdout or ""):match("^%S+%s+(%S+)")
        if s then st[p] = s end
    end
end
local TERMINAL = { completed = true, verified = true, done = true, obsoleted = true }
local adrift = {}
for _, p in ipairs(declared) do
    local s = st[p]
    if s ~= nil and not TERMINAL[s] then adrift[#adrift + 1] = { p, s } end
end
if #adrift == 0 then verdict.emit("ok:no-base-status-loss:" .. #declared .. " checked", 0) end

local msg = {}
for _, a in ipairs(adrift) do msg[#msg + 1] = "  advisory: " .. a[1] .. " declares a terminal event in " .. BASE .. " but folds as '" .. a[2] .. "'" end
for _, l in ipairs{ "  WHAT THIS MEANS: the work may be finished while the packet still advertises",
    "  itself as claimable — the 532 shape, and the mechanical reason agents go in",
    "  circles on work that is already done.",
    "  WHAT TO DO: check the packet's exit criteria AGAINST THE TREE. If they hold,",
    "  close it with evidence (set-field ... --evidence). If they do not, the event",
    "  is the thing that is wrong. Do NOT promote a status from an event alone —",
    "  532 was only closable because its litmus was re-run and passed.",
    "  This is ADVISORY and never fails a build (order 751-i9mb)." } do msg[#msg + 1] = l end
log.raw(table.concat(msg, "\n"))
verdict.emit("advisory:base-status-loss:" .. #adrift, 0)
