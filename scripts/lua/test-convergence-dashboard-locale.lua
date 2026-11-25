-- @trace order:1191-vrjf, order:2232-k8jc
--
-- The dashboard renderer's output must be BYTE-IDENTICAL whatever numeric
-- locale the caller runs it under. Not merely exit 0: a comma-decimal locale
-- that parses a value writes "89,0" into a file read as data and exits 0.
-- Ported from test-convergence-dashboard-locale.sh (2232-k8jc).
--
-- PRE-FIX RESULT: FAILS on the comma-decimal arms — "printf: 89.8989898989899:
-- nombre non valable" (rc=1) under fr_FR, measured on yoga 2026-09-14 and again
-- 2026-09-26 on trunk 6f8d134dd.
--
-- Premises first, so a green is about the property: (a) the C-locale render
-- succeeds and shows the expected value; (b) two C renders are byte-identical.
-- Every render pins the clock seam (CONVERGENCE_DASHBOARD_NOW): without it the
-- renderer's wall-clock stamp made (b) hold only when both renders fell in the
-- same second — green on a fast host, red 1 in 3 on macbookair. A host with no
-- comma-decimal locale installed prints a NAMED skip for those arms, never a pass.
--
-- Each render runs under proc.run's scrubbed environment, which gives every
-- child LC_ALL=C and LANG=C, plus the locale variables it names. The
-- LC_NUMERIC arm therefore passes LC_ALL="" (glibc reads empty as unset), as
-- the .sh's `env -u LC_ALL` unset it; without that the arm cannot fail.
--
-- Verdict: ok:convergence-dashboard-locale:<n> arms (skipped=<k>)
--        | violation:convergence-dashboard-locale:<n> failed

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local R = root .. "/scripts/update-convergence-dashboard.sh"
local rel = "target/plan-scratch/dashboard-locale-" .. tostring(time.now_ms())
local work = root .. "/" .. rel
proc.run{ argv = { "mkdir", "-p", work } }
local function cleanup() proc.run{ argv = { "find", work, "-delete" }, timeout_ms = 60000 } end

local function record(pct, total, earned)
    fs.write(rel .. "/sig.jsonl", '{"timestamp":"2026-09-26T11:21:12Z","version":"0.0.0.0","source_commit":"000000000000",'
        .. '"source_namespace":"local_development","ci_run_id":"fixture","ci_phase":"pre-build",'
        .. '"release_date":"2026-09-26T11:21:12Z","expected_total_cc":' .. total .. ',"actual_earned_cc":' .. earned
        .. ',"residual_cc":100,"percent_closed":' .. pct .. ',"litmus_tests_run":0,"litmus_passed":0,'
        .. '"litmus_failed":0,"litmus_skipped":0,"project_cc_earned":' .. earned .. ',"project_cc_total":' .. total
        .. ',"ci_result":"FAIL","max_residual_spec":"spec:fixture","max_residual_reason":"fixture",'
        .. '"max_residual_cc":100,"evidence_bundle_ref":"x","centicolon_projection_ref":"x",'
        .. '"top_residual_reasons":[],"failed_checks":[],"failed_reasons":[]}\n')
end

local pass, failn, skip = 0, 0, 0
local function ok(m) pass = pass + 1; out.line("ok   " .. m) end
local function bad(m) failn = failn + 1; out.line("FAIL " .. m) end

-- render <dir rel> {locale vars}: returns rc and the last line of its output
local function render(d, locale_env)
    proc.run{ argv = { "mkdir", "-p", root .. "/" .. d } }
    local e = {
        CONVERGENCE_DASHBOARD_NOW = "2026-09-26T12:34:56Z",
        SOURCE = work .. "/sig.jsonl",
        MD_OUT = root .. "/" .. d .. "/md", JSON_OUT = root .. "/" .. d .. "/json",
        SUMMARY_OUT = root .. "/" .. d .. "/summary",
        METRICS_SAMPLE = work .. "/no-such-metrics.json", TERMINAL_PREVIEW = "0",
    }
    for k, v in pairs(locale_env) do e[k] = v end
    local r = proc.run{ argv = { "bash", R }, cwd = root, env = e, timeout_ms = 120000 }
    local lines = text.lines((r.stdout or "") .. (r.stderr or ""))
    local last = ""
    for i = #lines, 1, -1 do if lines[i] ~= "" then last = lines[i]; break end end
    return r.code, last
end
local KINDS = { "md", "json", "summary" }
local function read(d, k) return fs.exists(d .. "/" .. k) and fs.read(d .. "/" .. k) or nil end
local function same(a, b)
    for _, k in ipairs(KINDS) do
        local x, y = read(a, k), read(b, k)
        if x == nil or x ~= y then return false end
    end
    return true
end
-- The first differing line, whatever it is: an earlier version grepped only for
-- a comma-decimal number, so a difference of any other kind (macbookair's: a
-- wall-clock stamp) was reported with an EMPTY sample that pointed at nothing.
local function first_diff(a, b)
    for _, k in ipairs(KINDS) do
        local x, y = read(a, k) or "", read(b, k) or ""
        if x ~= y then
            local xl, yl = text.lines(x), text.lines(y)
            for i = 1, math.max(#xl, #yl) do
                if xl[i] ~= yl[i] then
                    return k .. ": < " .. (xl[i] or "") .. " > " .. (yl[i] or "")
                end
            end
            return k .. ": (trailing bytes differ)"
        end
    end
    return ""
end

-- the first comma-decimal locale installed, if any
local avail = "\n" .. (proc.run{ argv = { "locale", "-a" } }.stdout or "") .. "\n"
local loc = ""
for _, c in ipairs({ "fr_FR.UTF-8", "fr_FR.utf8", "de_DE.UTF-8", "de_DE.utf8" }) do
    if avail:find("\n" .. c .. "\n", 1, true) then loc = c; break end
end

-- Two values, two failure modes. The renderer derives the percent from
-- earned/total, so the case is chosen by the COUNTS: 890/990 is fractional and
-- is REFUSED under a comma locale (loud, rc=1); 900/1000 is 90 exactly, which
-- PARSES and would render "90,0" (quiet, rc=0) — the one only byte identity
-- catches.
for _, case in ipairs({ { "89.8989898989899", 990, 890, "89.9" }, { "90", 1000, 900, "90.0" } }) do
    local pct, want = case[1], case[4]
    record(case[1], case[2], case[3])
    local run = rel .. "/run-" .. pct
    local rc1, last1 = render(run .. "/c1", { LC_ALL = "C" })
    render(run .. "/c2", { LC_ALL = "C" })
    local md1 = read(run .. "/c1", "md") or ""
    if rc1 ~= 0 or not md1:find(want, 1, true) then
        bad("[" .. pct .. "] premise: the C-locale render did not succeed with " .. want .. " (rc=" .. tostring(rc1) .. "): " .. last1)
    elseif not same(run .. "/c1", run .. "/c2") then
        bad("[" .. pct .. "] premise: two C-locale renders differ, so byte identity cannot be asserted")
    else
        ok("[" .. pct .. "] premise: C render succeeds, shows " .. want .. ", and is reproducible")
        if loc == "" then
            skip = skip + 1
            out.line("skip [" .. pct .. "] no comma-decimal locale installed (fr_FR/de_DE): the locale arms did not run")
        else
            for _, mode in ipairs({ "LC_ALL", "LC_NUMERIC" }) do
                local d = run .. "/" .. (mode .. "=" .. loc):gsub("[=.@]", "_")
                -- LC_ALL="" for the LC_NUMERIC arm: proc.run gives every child
                -- LC_ALL=C (and LANG=C), which would override LC_NUMERIC and make
                -- this arm vacuous. glibc reads an empty LC_ALL as unset.
                local lenv = { [mode] = loc }
                if mode == "LC_NUMERIC" then lenv.LC_ALL = "" end
                local rc, last = render(d, lenv)
                if rc ~= 0 then bad("[" .. pct .. "] under " .. mode .. "=" .. loc .. " the renderer exits " .. tostring(rc) .. ": " .. last)
                elseif not same(run .. "/c1", d) then
                    bad("[" .. pct .. "] under " .. mode .. "=" .. loc .. " the output differs from C — first difference: " .. first_diff(run .. "/c1", d))
                else ok("[" .. pct .. "] under " .. mode .. "=" .. loc .. " the output is byte-identical to C") end
            end
        end
    end
end

cleanup()
if failn == 0 then verdict.ok("convergence-dashboard-locale:" .. pass .. " arms (skipped=" .. skip .. ")") end
verdict.emit("violation:convergence-dashboard-locale:" .. failn .. " failed", 1)
