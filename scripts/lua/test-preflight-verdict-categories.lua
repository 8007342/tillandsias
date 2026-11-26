-- @trace order:1353-ryhq, spec:ci-release, order:2385-psbb
-- @env PATH HOME TILLANDSIAS_PREFLIGHT_LIVE TOOLBOX_PATH container TILLANDSIAS_SKIP_TOOLBOX TILLANDSIAS_SHARED_TARGET_HELD TILLANDSIAS_SHARED_TARGET CARGO_TARGET_DIR
--
-- test-preflight-verdict-categories.lua — the preflight verdict distinguishes what ran from what
-- did not, and never vouches for a guard that did not examine the tree. Ported from
-- test-preflight-verdict-categories.sh (2385-psbb); same nine arms (arm 9 opt-in).
--
-- Measured 2026-09-22 on three hosts: yolanda-windows printed ok: with 20 of 31 skips being
-- deadline cut-offs; macneo booked 110 guards as REFUSALS when one binary (setsid) was absent;
-- the forge printed refused: for guards that never ran (tmpfs full, 1349-53h6). One defect: the
-- verdict could not say whether a guard answered. NO ARM ASSERTS A GUARD COUNT (rosters differ
-- by checkout, 108 vs 110 minutes apart); arms assert CATEGORIES and their SUM. Arms 1-8 read
-- build.sh and script_run.rs; arm 9 runs ./build.sh --preflight only when
-- TILLANDSIAS_PREFLIGHT_LIVE=1, with the ambient env plus fixture.gate_inherit (2384-svqx).
--
--   1  the verdict names every category
--   2  a category set that does not sum to the roster refuses (accounting-mismatch, _pf_sum)
--   3  unanswered guards report partial:, not ok:
--   4  a declared skip is not counted as unanswered (965-sxec)
--   5  a guard the runner could not start is could-not-run, not refused
--   6  no branch compares a category against a fixed number
--   7  every summary verdict line (>= 3) carries 1352-vmbc's isolation= field
--   8  classify: the named-skip arm precedes could-not-run (1384-bqhy precedence)
--   9  LIVE (opt-in): the door's categories add up to its stated sum, isolation present
--
-- GRAMMAR ok:preflight-verdict-categories:<n> arms | violation:preflight-verdict-categories:<n>-failed
--       | refused:preflight-verdict-categories:no-build-sh

local fixture = require "common.fixture"
local T = fixture.new("preflight-verdict-categories")
local ROOT = fixture.repo_root()
if not fs.exists("build.sh") then T:refuse("no-build-sh", ROOT .. "/build.sh") end
local src = fs.read("build.sh")
local function has(s, needle) return s:find(needle, 1, true) ~= nil end
local function lines(s)
    local t = {}
    for l in (s .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = l end
    return t
end
local SRC = lines(src)

-- 1
local missing = {}
for _, c in ipairs{ "ran=", "declared-skip=", "skipped-by-deadline=", "benched=", "could-not-run=", "refused=" } do
    if not has(src, c) then missing[#missing + 1] = c end
end
T:arm("arm1 the verdict names ran, declared-skip, skipped-by-deadline, could-not-run and refused",
    #missing == 0, "missing: " .. table.concat(missing, " "))

-- 2: categories a reader cannot check are a vocabulary, not an accounting.
T:arm("arm2 a category set that does not sum to the roster refuses instead of reporting",
    has(src, "accounting-mismatch") and has(src, "_pf_sum"), "no accounting-mismatch/_pf_sum")

-- 3: the arm the pre-fix code fails.
T:arm("arm3 a run with unanswered guards reports partial:, not ok:",
    has(src, "partial:preflight:") and has(src, "_pf_unanswered"), "no partial:preflight:/_pf_unanswered")

-- 4: the complement of 3; treating every skip as a gap teaches hosts to suppress named skips.
local una
for _, l in ipairs(SRC) do if has(l, "_pf_unanswered=") then una = l; break end end
T:arm("arm4 a declared skip is an observation, not an unanswered guard",
    una ~= nil and not has(una, "_pf_declskip"), una or "no unanswered tally exists to check")

-- 5
T:arm("arm5 a guard the runner could not start is could-not-run, not refused",
    has(src, "could-not-run:preflight:") and has(src, "_pf_cantrun"), "no could-not-run:preflight:/_pf_cantrun")

-- 6: ERE (ran|refused|skipped[a-z-]*|could-not-run|declared-skip)\s*[!=]=\s*[0-9]+, minus the
-- lines that compare a computed tally.
local CMP = { "ran", "refused", "skipped[%a%-]*", "could%-not%-run", "declared%-skip" }
local EXEMPT = { "_pf_sum", "_pf_unanswered", "_pf_failed", "-gt 0", "-ne 0" }
local fixed
for _, l in ipairs(SRC) do
    local hit = false
    for _, w in ipairs(CMP) do if l:find(w .. "%s*[!=]=%s*%d") then hit = true; break end end
    if hit then
        local ex = false
        for _, e in ipairs(EXEMPT) do if has(l, e) then ex = true; break end end
        if not ex then fixed = l; break end
    end
end
T:arm("arm6 no arm or branch asserts a fixed guard count", fixed == nil, fixed)

-- 7: SUMMARY lines only (they carry $_pf_counts); the count is asserted so a stale selector reds.
local seen, iso_missing = 0, {}
for i, l in ipairs(SRC) do
    for _, k in ipairs{ "ok", "partial", "refused" } do
        if l:find('echo "' .. k .. ':preflight[^"]*%$_pf_counts') then
            seen = seen + 1
            if not has(l, "_pf_iso") then iso_missing[#iso_missing + 1] = tostring(i) end
            break
        end
    end
end
T:arm("arm7 every summary verdict line carries 1352-vmbc's isolation= field (" .. seen .. " seen)",
    seen >= 3 and #iso_missing == 0,
    seen < 3 and ("found " .. seen .. " summary line(s), expected at least 3 — the selector has gone stale")
        or ("build.sh line(s) without isolation=: " .. table.concat(iso_missing, " ")))

-- 8: keyed on the check calls, not if/elif (an if/elif selector reds for the wrong reason).
local rs = fs.exists("crates/tillandsias-plan/src/script_run.rs") and fs.read("crates/tillandsias-plan/src/script_run.rs") or ""
local skip_ln, cnr_ln
for i, l in ipairs(lines(rs)) do
    if not skip_ln and has(l, 'line_starts(text, "skip:")') then skip_ln = i end
    if not cnr_ln and has(l, 'line_starts(text, "could-not-run:")') then cnr_ln = i end
end
T:arm("arm8 a guard printing both tokens scores as a declared skip (named-skip arm precedes could-not-run)",
    skip_ln ~= nil and cnr_ln ~= nil and skip_ln < cnr_ln,
    "skip=" .. tostring(skip_ln) .. " could-not-run=" .. tostring(cnr_ln))

-- 9: the only arm that runs the thing. A named skip where not requested (965-sxec).
if (env.get("TILLANDSIAS_PREFLIGHT_LIVE") or "0") ~= "1" then
    out.line("  [SKIP] arm9:live-run:not-requested — set TILLANDSIAS_PREFLIGHT_LIVE=1 to run the real door (minutes, not seconds)")
else
    local r = T:run{ fixture.posix_shell("/bin/bash"), "-s", cwd = ROOT, timeout_ms = 3600000,
        env = fixture.gate_inherit{ PATH = env.get("PATH"), HOME = env.get("HOME") },
        stdin = "./build.sh --preflight 2>&1\n" }
    local verdict
    for _, l in ipairs(lines(r.stdout or "")) do
        local m = l:match("^ok:preflight:ran=.*") or l:match("^partial:preflight:ran=.*") or l:match("^refused:preflight:ran=.*")
        if m then verdict = m end
    end
    if not verdict then
        T:arm("arm9 the door printed a category verdict", false, text.trim(r.stdout or ""):sub(-400))
    else
        local function get(k) return tonumber(verdict:match("%f[%w%-]" .. k:gsub("%-", "%%-") .. "=(%d+)") or "") end
        local s = 0
        for _, k in ipairs{ "ran", "declared-skip", "skipped-by-deadline", "benched", "could-not-run", "refused" } do
            s = s + (get(k) or 0)
        end
        local stated = get("sum")
        T:arm("arm9 the live door's categories add up to its own stated sum, isolation present",
            stated ~= nil and s == stated and has(verdict, "isolation="),
            "sum=" .. tostring(s) .. " stated=" .. tostring(stated) .. " " .. verdict)
    end
end

T:finish()
