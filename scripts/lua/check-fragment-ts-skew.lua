-- @env TILLANDSIAS_FRAGMENT_TS_SKEW_LIMIT TILLANDSIAS_FRAGMENT_PARSE_BASE TILLANDSIAS_GATE_DIFF_BASE
-- @trace spec:ci-release, order:1313-w78k, order:2124-mwzr
--
-- check-fragment-ts-skew.lua — refuse a fragment whose `ts:` is in the FUTURE
-- against the pushing host's clock, and REPORT one that is in the past.
-- Ported from check-fragment-ts-skew.sh (2124-mwzr); the grammar is unchanged.
--
-- WHY THIS EXISTS. `tillandsias-plan append-event` already refuses a ts more
-- than 900 s from the host's clock. A fragment written BY HAND as YAML goes
-- through no such check, so the limit protected only the path a careful agent
-- was already on. MEASURED on pirria 2026-09-20: six hand-written fragments in
-- one session, five of them in the FUTURE, the worst by 4h49m. `ts` is what
-- "stalest first" sorts on, what claim expiry reads, and what every recency
-- claim consumes, and the records are permanent.
--
-- THE RULE IS ASYMMETRIC (coordinator ruling, 2026-09-20):
--   FUTURE beyond the limit -> REFUSED, always. No clock-correct writer produces
--   one, so it is never a backfill; it is an invented time.
--   PAST beyond the limit -> ACCEPTED, and the skew PRINTED. A delayed push is
--   real and common; a declaration for it would become a ritual.
--
-- DIFF-SCOPED, like check-added-fragments-parse (698-7n6q): you break it, your
-- push fails; you inherit it, you are not even told.
--
-- THE EPOCH IS COMPUTED, NOT ASKED OF date(1). The .sh tried GNU `date -d`, then
-- BSD `date -j -f`, and had to validate the output because BSD date SUCCEEDS
-- WITH GARBAGE on -d. Days-from-civil arithmetic reads the same on every host.
--
-- Grammar (stdout):
--   ^(ok:fragment-ts-skew:[0-9]+ checked, [0-9]+ past-noted|skip:fragment-ts-skew:no-base-ref)$
--   note:fragment-ts-past:<file>:<n>s      (one per past ts, stdout)
--   violation:fragment-ts-future:<n>       (exit 1; details on stderr)
local FRAG_DIR = "plan/index.d"
local LIMIT = tonumber(env.get("TILLANDSIAS_FRAGMENT_TS_SKEW_LIMIT") or "") or 900
local base_ref = env.get("TILLANDSIAS_FRAGMENT_PARSE_BASE")
if not base_ref or base_ref == "" then base_ref = env.get("TILLANDSIAS_GATE_DIFF_BASE") end
if not base_ref or base_ref == "" then base_ref = "origin/linux-next" end

local function git(args)
    local argv = { "git" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, timeout_ms = 60000 })
    return r.status == "exited" and r.code == 0, r.stdout or ""
end

if not git({ "rev-parse", "--verify", "--quiet", base_ref }) then
    log.raw("  note: base ref '" .. base_ref .. "' unavailable — ts-skew enforcement skipped")
    verdict.emit("skip:fragment-ts-skew:no-base-ref", 0)
end

local seen, files = {}, {}
local function add(out)
    for _, f in ipairs(text.lines(out)) do
        if f ~= "" and f:match("%.yaml$") and not seen[f] then seen[f] = true; files[#files + 1] = f end
    end
end
local spec = FRAG_DIR .. "/*.yaml"
add(select(2, git({ "diff", "--name-only", "--diff-filter=AM", base_ref, "--", spec })))
add(select(2, git({ "ls-files", "--others", "--exclude-standard", "--", spec })))
add(select(2, git({ "diff", "--name-only", "--cached", "--diff-filter=AM", "--", spec })))
table.sort(files)
if #files == 0 then verdict.emit("ok:fragment-ts-skew:0 checked", 0) end

-- Seconds since the epoch for YYYY-MM-DDTHH:MM:SSZ, or nil (Howard Hinnant's
-- days_from_civil, in integer arithmetic).
local function epoch(stamp)
    local y, mo, d, h, mi, s = stamp:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
    if not y then return nil end
    y, mo, d, h, mi, s = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)
    if mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or s > 60 then return nil end
    if mo <= 2 then y = y - 1 end
    local era = (y >= 0 and y or y - 399) // 400
    local yoe = y - era * 400
    local mp = (mo + 9) % 12
    local doy = (153 * mp + 2) // 5 + d - 1
    local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    local days = era * 146097 + doe - 719468
    return days * 86400 + h * 3600 + mi * 60 + s
end

local now = time.now_ms() // 1000
local checked, refused, past = 0, 0, 0
for _, f in ipairs(files) do
    local ok, body = pcall(fs.read, f)
    if ok and body then
        for stamp in body:gmatch('"(20%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ)"') do
            local e = epoch(stamp)
            if not e then
                log.raw("note:fragment-ts-unreadable:" .. f .. ":" .. stamp)
            else
                checked = checked + 1
                local delta = e - now
                if delta > LIMIT then
                    refused = refused + 1
                    log.raw("violation:fragment-ts-future:" .. f)
                    log.raw("  ts " .. stamp .. " is " .. delta .. "s AHEAD of this host's clock (" .. os.date("!%Y-%m-%dT%H:%M:%SZ", now) .. "); limit " .. LIMIT .. "s.")
                    log.raw("  A future timestamp is not a backfill — no clock-correct writer produces one.")
                    log.raw("  REMEDY: read the clock instead of composing a time:")
                    log.raw("    date -u +%Y-%m-%dT%H:%M:%SZ")
                    log.raw("  or let the tool write it: tillandsias-plan append-event ... (omit --ts).")
                elseif delta < -LIMIT then
                    past = past + 1
                    out.line("note:fragment-ts-past:" .. f .. ":" .. (-delta) .. "s")
                end
            end
        end
    end
end

if refused > 0 then
    verdict.emit("violation:fragment-ts-future:" .. refused, 1)
end
verdict.emit("ok:fragment-ts-skew:" .. checked .. " checked, " .. past .. " past-noted", 0)
