-- @env PATH HOME TMPDIR TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace spec:versioning, spec:ci-release, order:1218-25z3, order:2390-byz6
--
-- check-must-ship-rows.lua — name the rows marked REQUIRED FOR THE NEXT CUT whose fix is not in the tree being cut.
--
-- Order 1218-25z3. The operator, 2026-09-16, after hitting 1215-xazj live on a freshly promoted stable: "take note
-- of anything that needs to get done, and make sure it happens by the next release". 1211-34v6 landed on trunk and
-- was not in the cut that followed; nothing was done wrong, NO GATE ASKED.
--
-- A row is marked with `tillandsias-plan set-field <order> must_ship next`. The fix is found by SUBJECT,
-- `type(order): …`: a body MENTION is not a fix (`git log --grep=1211-34v6` returns five commits, three of them
-- mentions). A fix landed under a subject that does not name its order reads outstanding: a false alarm, the safe
-- direction.
--
-- REPORTS, DOES NOT BLOCK (criterion 4): a blocking cut gate is bypassed, not obeyed (748-tkjx); the cutter may
-- ship without a marked row on purpose; the defect was that nobody was TOLD. Exit 0 on every verdict, including a
-- wrong invocation, and a wrong invocation prints NO verdict about any tree.
--
-- Usage: tillandsias-plan script run scripts/lua/check-must-ship-rows.lua [-- --cut-ref <ref>] [--marker <value>]
-- Verdict (one line, closed grammar):
--   ok:must-ship:0 outstanding of <n> marked | advisory:must-ship:<n> outstanding of <m> marked
--   skipped:must-ship:(no-plan-binary|stale-plan-binary|no-cut-ref)
--   fail:must-ship:(unreadable-ledger|unknown-argument|missing-value)
-- Ported from the .sh of the same name; jq is no longer needed.

local function done(line) verdict.emit(line, 0) end
local args, MARKER, CUT_REF = arg or {}, "next", "HEAD"
local i = 1
while i <= #args do
    local a = args[i]
    if a == "--cut-ref" or a == "--marker" then
        -- A flag with no value examined nothing: say so, never answer about HEAD.
        if i == #args then log.raw("  " .. a .. " needs a value; nothing was examined"); done("fail:must-ship:missing-value") end
        if a == "--cut-ref" then CUT_REF = args[i + 1] else MARKER = args[i + 1] end
        i = i + 2
    elseif a == "-h" or a == "--help" then
        log.raw("usage: check-must-ship-rows.lua [-- --cut-ref <ref>] [--marker <value>]")
        verdict.emit("skipped:must-ship:help", 0)
    else
        -- Refused, not discarded: a positional ref used to be dropped and HEAD answered for, a confident clean verdict
        -- about a tree nobody asked about (found by macuahuitl hitting it).
        log.raw("  unrecognised argument: " .. a .. "\n  Nothing was examined, and NO verdict was printed: the run you asked for\n"
            .. "  is not the run this would have made. It would have answered about HEAD.\n  The ref goes behind --cut-ref:\n"
            .. "      check-must-ship-rows.lua -- --cut-ref " .. a)
        done("fail:must-ship:unknown-argument")
    end
end

local function nonempty(v) return v ~= nil and v ~= "" end
local ep = text.trim(proc.run({ argv = { "git", "--exec-path" }, timeout_ms = 10000 }).stdout or "")
local SH = ep:find("^%a:/.*/libexec/git%-core$") and (ep:gsub("/[^/]+/libexec/git%-core$", "/bin/bash.exe")) or "bash"
local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN")
if not nonempty(PLAN) then
    local r = proc.run({ argv = { SH, "-s" }, timeout_ms = 60000, stdin = '. scripts/plan-binary-probe.sh 2>/dev/null || exit 1\n'
        -- native-argv: the /c/... answer is made C:/... by cygpath -m on the next line of the script
        .. 'p="$(resolve_plan_binary)" || exit 1\ncase "$p" in ./*) p="$PWD/${p#./}" ;; esac\n'
        .. 'command -v cygpath >/dev/null 2>&1 && p="$(cygpath -m "$p")"\nprintf "%s" "$p"\n' })
    PLAN = r.code == 0 and text.trim(r.stdout or "") or ""
end
if not nonempty(PLAN) then log.raw("  tillandsias-plan not built; the must-ship pass did not run"); done("skipped:must-ship:no-plan-binary") end

if proc.run({ argv = { "git", "rev-parse", "--verify", "-q", CUT_REF }, timeout_ms = 30000 }).code ~= 0 then
    log.raw("  note: ref '" .. CUT_REF .. "' unavailable — nothing was examined")
    done("skipped:must-ship:no-cut-ref")
end

-- FALSIFY THE INSTRUMENT BEFORE TRUSTING A ZERO: a binary older than the field projects no must_ship, so every
-- row reads unmarked and the verdict would be a confident `ok: 0 of 0`.
local probe = proc.run({ argv = { SH, "-s", "--", PLAN }, timeout_ms = 60000, stdin = 'd="$(mktemp -d "${TMPDIR:-/tmp}/must-ship-probe.XXXXXX")" || exit 9\n'
    .. "printf 'packets:\\n  - packet_id: probe\\n    order: 9999-zzzz\\n    status: ready\\n    kind: bug\\n    must_ship: next\\n    title: |\\n      probe\\n' > \"$d/index.yaml\"\n"
    .. 'i="$d/index.yaml"; command -v cygpath >/dev/null 2>&1 && i="$(cygpath -m "$i")"\n'
    .. '"$1" --index "$i" query --status ready --limit 1 --json 2>/dev/null; rc=$?; rm -rf "$d"; exit $rc\n' })
local ok_p, prows = pcall(json.parse, probe.stdout or "")
local saw = ok_p and type(prows) == "table" and type(prows[1]) == "table" and prows[1].must_ship or nil
if saw ~= "next" then
    log.raw("  " .. PLAN .. " does not project must_ship (probe read '" .. tostring(saw or "ABSENT") .. "').\n"
        .. "  A zero from this binary would mean 'cannot see marks', not 'no marks'.\n"
        .. "  Remedy, BOTH halves — the build alone is often a no-op on a current checkout and what is missing is the STAMP:\n"
        .. "      cargo build --release -p tillandsias-plan && scripts/check-plan-binary-current.sh")
    done("skipped:must-ship:stale-plan-binary")
end

local rows, any = {}, false
for _, st in ipairs{ "ready", "in_progress", "completed", "implemented" } do
    local q = proc.run({ argv = { PLAN, "query", "--status", st, "--limit", "999", "--json" }, timeout_ms = 120000 })
    if q.code == 0 and text.trim(q.stdout or "") ~= "" then
        any = true
        local ok_, list = pcall(json.parse, q.stdout)
        if ok_ and type(list) == "table" then for _, r in ipairs(list) do rows[#rows + 1] = r end end
    end
end
-- An EMPTY RESULT and an UNREADABLE LEDGER are different facts: "no matches" is the two characters [].
if not any then
    log.raw("  '" .. PLAN .. " query --json' produced no output — the ledger could not be read.\n  This is NOT 'no rows are marked': that answer is the two characters [].")
    done("fail:must-ship:unreadable-ledger")
end

local marked, seen = {}, {}
for _, r in ipairs(rows) do
    if type(r) == "table" and type(r.must_ship) == "string" and r.must_ship ~= "" then
        local key = tostring(r.order) .. "\t" .. tostring(r.packet_id) .. "\t" .. tostring(r.status)
        if not seen[key] then seen[key] = true; marked[#marked + 1] = { order = tostring(r.order), pid = tostring(r.packet_id), status = tostring(r.status), key = key } end
    end
end
table.sort(marked, function(a, b) return a.key < b.key end)
if #marked == 0 then done("ok:must-ship:0 outstanding of 0 marked") end

local subjects = {}
for s in ((proc.run({ argv = { "git", "log", "--format=%s", CUT_REF }, timeout_ms = 120000 }).stdout or ""):gsub("\r", "")):gmatch("[^\n]+") do
    subjects[#subjects + 1] = s
end
local outstanding, report = 0, {}
for _, m in ipairs(marked) do
    local pat = "^%l+%([^)]*" .. m.order:gsub("%p", "%%%0") .. "[^)]*%)"
    local hits = 0
    for _, s in ipairs(subjects) do if s:find(pat) then hits = hits + 1 end end
    if hits == 0 then
        outstanding = outstanding + 1
        report[#report + 1] = "  OUTSTANDING  " .. m.order .. "  [" .. m.status .. "]  " .. m.pid .. "\n      no commit in '" .. CUT_REF .. "' has a subject naming this order"
    else
        report[#report + 1] = "  present      " .. m.order .. "  [" .. m.status .. "]  " .. hits .. " commit(s) in '" .. CUT_REF .. "'"
    end
end
log.raw(table.concat(report, "\n"))
if outstanding == 0 then done("ok:must-ship:0 outstanding of " .. #marked .. " marked") end
log.raw("  These rows are marked '" .. MARKER .. "' and no commit in '" .. CUT_REF .. "' names them.\n"
    .. "  ADVISORY (1218-25z3): it does not block the cut. Ship anyway if that is the\n"
    .. "  decision — the defect this closes was that nobody was TOLD, not that someone\n"
    .. "  overrode a warning. To clear a row, land its fix or drop the marker tag.")
done("advisory:must-ship:" .. outstanding .. " outstanding of " .. #marked .. " marked")
