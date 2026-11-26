-- @env PATH HOME TMPDIR TILLANDSIAS_CHECK_LOG_INDEX TILLANDSIAS_RELEASE_TIER_MAX_AGE_DAYS
-- @trace order:890-27mv, order:1174-6r4k, order:888-vgs8, order:2409-qbgu, spec:ci-release
--
-- check-release-tier-freshness.lua — answer "when was the RELEASE tier last exercised on this host, and what was
-- the verdict", without cutting a release. Ported from the .sh of the same name (2409-qbgu); same tokens, same exits.
--
-- THE GAP THIS FILLS (890-27mv). The recurring loop gates on `./build.sh --check`; the release gates on `--ci-full`.
-- The delta between the two tiers is never exercised between releases, accumulates silently, and is discharged all
-- at once by whoever is trying to ship. Measured on yoga 2026-09-12: no check-logs.jsonl at all, the release tier
-- had never run on that host. Not "failed quietly": never ran.
--
-- THIS DOES NOT RUN THE TIER and deliberately does not gate the inner loop (758-jw6v). It only READS the history the
-- heavier tier already leaves behind, so it is cheap enough to call from anywhere.
--
-- NEVER-RAN MUST NOT READ AS PASS. Every non-green outcome exits non-zero, and could-not-run keeps 965-sxec's
-- grammar: exit 3 means the instrument could not answer, never that the answer was good.
--
-- Exit codes:  0 exercised, recent, all green               ok:release-tier-fresh:<run>:<age>d:<pass>/<total>
--              1 a real, loud answer that is not green      never: | red: | stale:release-tier:...
--              3 could-not-run — this host cannot even determine it
-- Context lines (last exercised, verdict counts, skip:phase-only-run:...) go to stdout before the verdict, as the .sh
-- printed them; the explanatory lines under never: go to stderr.
--
-- Usage: tillandsias-plan script run scripts/lua/check-release-tier-freshness.lua

local ep = text.trim(proc.run({ argv = { "git", "--exec-path" }, timeout_ms = 10000 }).stdout or "")
local SH = ep:find("^%a:/.*/libexec/git%-core$") and (ep:gsub("/[^/]+/libexec/git%-core$", "/bin/bash.exe")) or "bash"
local function sh(script)
    return proc.run({ argv = { SH, "-s" }, stdin = script, timeout_ms = 60000 })
end

-- 888-vgs8: the one path rule, override included, is scripts/convergence-log-path.sh; resolving through it adopts a
-- legacy target/ index once, by copy, which is what keeps the answer true across the move.
local r = sh("scripts/convergence-log-path.sh\n")
local INDEX = text.trim(r.stdout or "")
if r.code ~= 0 or INDEX == "" then
    verdict.emit("could-not-run:release-tier:scripts/convergence-log-path.sh did not answer", 3)
end
local MAX_AGE = tonumber(env.get("TILLANDSIAS_RELEASE_TIER_MAX_AGE_DAYS") or "") or 7

-- The index may live anywhere the override names (a fixture's temp dir), outside the fs door: read it through the
-- shell. 10: absent, 11: present but empty.
local q = "'" .. INDEX:gsub("'", "'\\''") .. "'"
r = sh("f=" .. q .. '\n[ -f "$f" ] || exit 10\n[ -s "$f" ] || exit 11\ncat "$f"\n')
if r.code == 10 then
    log.raw("  This is an answer, not a failure to get one: nothing has ever written a\n"
        .. "  release-tier record on this host. Run scripts/local-ci.sh (or ./build.sh\n"
        .. "  --ci-full) to create one. It is NOT a statement that the tier would pass.")
    verdict.emit("never:release-tier:no " .. INDEX .. " on this host — the release tier has NEVER been exercised here", 1)
elseif r.code == 11 then
    verdict.emit("never:release-tier:" .. INDEX .. " is empty — a run was started but recorded no check", 1)
elseif r.code ~= 0 then
    verdict.emit("could-not-run:release-tier:" .. INDEX .. " could not be read", 3)
end

-- local-ci writes no ts field: the moment is the ci_run_id. field_of matches the .sh's: the first "name":"value".
local function field_of(rec, name)
    local v = rec:match('"' .. name .. '":"([^"]*)')
    return v
end
local recs = {}
for line in (r.stdout or ""):gmatch("[^\n]+") do
    line = line:gsub("\r$", "")
    if line ~= "" then recs[#recs + 1] = line end
end

-- ORDER 1174-6r4k — PICK THE NEWEST FULL-TIER RUN, NOT THE NEWEST RUN. A run is full-tier if its records say `all`,
-- or if between them they cover pre-build AND post-build AND runtime. Order is first appearance in the index.
local run_ids, phases, seen = {}, {}, {}
for _, rec in ipairs(recs) do
    local id = field_of(rec, "ci_run_id")
    if id then
        if not seen[id] then seen[id] = true; run_ids[#run_ids + 1] = id; phases[id] = { list = {}, has = {} } end
        local p = field_of(rec, "ci_phase")
        if p and p ~= "" and not phases[id].has[p] then
            phases[id].has[p] = true; phases[id].list[#phases[id].list + 1] = p
        end
    end
end
local function phase_set(id) return " " .. table.concat(phases[id].list, " ") end
local full = {}
local LAST = nil
for _, id in ipairs(run_ids) do
    local h = phases[id].has
    if h["all"] or (h["pre-build"] and h["post-build"] and h["runtime"]) then full[id] = true; LAST = id end
end
if not LAST then
    log.raw("  A phase-only run is not a release-tier answer (1174-6r4k). Run\n"
        .. "  scripts/local-ci.sh (all phases) or ./build.sh --ci-full to produce one.")
    local newest = run_ids[#run_ids] or ""
    verdict.emit("never:release-tier:no FULL-tier run in " .. INDEX .. " — the newest run " .. newest
        .. " covers only [" .. (newest ~= "" and phase_set(newest) or "") .. "]", 1)
end

-- NAME THE RUNS BEING IGNORED: silence would look identical to "there was nothing newer".
local after = false
for _, id in ipairs(run_ids) do
    if after and not full[id] then
        print("skip:phase-only-run:" .. id .. " (newer than " .. LAST .. ", covers only [" .. phase_set(id) .. "] — not a release-tier answer)")
    end
    if id == LAST then after = true end
end

-- Verdict over the WHOLE last run, not just its last line.
local pass, fail, skip, other = 0, 0, 0, 0
local needle = '"ci_run_id":"' .. LAST .. '"'
for _, rec in ipairs(recs) do
    if rec:find(needle, 1, true) then
        local st = field_of(rec, "status") or ""
        if st == "pass" or st == "passed" or st == "ok" then pass = pass + 1
        elseif st == "fail" or st == "failed" or st == "red" then fail = fail + 1
        elseif st == "skip" or st == "skipped" then skip = skip + 1
        else other = other + 1 end
    end
end
local total = pass + fail + skip + other

-- days_from_civil, as the .sh did it: no date(1) flags, nothing locale-dependent.
local function days_from_civil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = (y >= 0 and y or y - 399) // 400
    local yoe = y - era * 400
    local doy = (153 * (m > 2 and m - 3 or m + 9) + 2) // 5 + d - 1
    local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468
end
local Y, M, D, h, mi, s = LAST:match("^local%-ci%-(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)Z$")
if not Y then
    log.raw("  Verdict over that run was " .. pass .. " pass / " .. fail .. " fail / " .. skip .. " skip, but HOW OLD\n"
        .. "  it is cannot be determined, so freshness is unanswerable.")
    verdict.emit("could-not-run:release-tier:cannot read a timestamp out of ci_run_id '" .. LAST .. "'", 3)
end
local last_epoch = days_from_civil(tonumber(Y), tonumber(M), tonumber(D)) * 86400
    + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
local now = os.time()
if type(now) ~= "number" then verdict.emit("could-not-run:release-tier:the runtime would not give an epoch", 3) end
local age = (now - last_epoch) // 86400
if age < 0 then age = 0 end

print("release-tier last exercised here: " .. LAST .. " (" .. age .. "d ago)")
print("  verdict over that run: " .. pass .. " pass, " .. fail .. " fail, " .. skip .. " skip, " .. other
    .. " unrecognised, " .. total .. " records")

if fail > 0 then
    verdict.emit("red:release-tier:" .. fail .. " failing check(s) in " .. LAST .. " — the last release-tier answer on this host was RED", 1)
end
if age > MAX_AGE then
    verdict.emit("stale:release-tier:" .. age .. "d exceeds " .. MAX_AGE .. "d — green, but too old to be evidence about this tree", 1)
end
verdict.emit("ok:release-tier-fresh:" .. LAST .. ":" .. age .. "d:" .. pass .. "/" .. total, 0)
