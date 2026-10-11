-- @trace order:778-hb3x, order:1607-8bq5, spec:git-mirror-service
--
-- test-git-mirror-seed-failure-surfaced.lua — PORTED from
-- test-git-mirror-seed-failure-surfaced.sh (1607-8bq5's carried shell->lua
-- payment). The launcher's seeded-gate surfaces the mirror's own seed-fetch
-- failure line (778-hb3x criterion 3). Structural, and deliberately so: the
-- behaviour is unit-tested in main.rs (mirror_seed_failure_tests), and what
-- those cannot see from inside one crate is the CROSS-COMPONENT string, so this
-- checks it across both files:
--   1 MARKER    the marker the launcher searches for
--               (GIT_MIRROR_SEED_FAILURE_MARKER, main.rs) is the one
--               images/git/entrypoint.sh prints (`retry_msg "<marker> ..."`), in
--               BOTH of the mirror's failure arms
--   2 GATE      wait_for_git_mirror_ready reads the mirror log (.log_tail) and
--               calls last_seed_failure while it waits AND before it gives up
--   3 MUTANTS   an entrypoint with one failure arm stripped of the marker, and a
--               gate body with one call, are each refused (the checks can fail)
--   4 READERS   the .sh's retired PASS: line has no reader in scripts/, the gate
--               steps or the litmus specs; the count searched is printed
--
-- Terminal line: ok:git-mirror-seed-failure-surfaced, or
-- refused:git-mirror-seed-failure-surfaced:<failed>.
--
-- Usage: tillandsias-plan script run scripts/lua/test-git-mirror-seed-failure-surfaced.lua

local MAIN = "crates/tillandsias-headless/src/main.rs"
local ENTRY = "images/git/entrypoint.sh"
local passed, failed = 0, 0
local function ok(m) out.line("ok:   " .. m); passed = passed + 1 end
local function bad(m) out.line("FAIL: " .. m); failed = failed + 1 end
local function has(s, sub) return s:find(sub, 1, true) ~= nil end
local function count(s, sub)
    local n, i = 0, 1
    while true do
        local a, b = s:find(sub, i, true)
        if not a then return n end
        n = n + 1; i = b + 1
    end
end

-- judge(main_src, entry_src) -> marker, arms, calls, logs, why[]
local function judge(main_src, entry_src)
    local why = {}
    local marker = main_src:match('\nconst GIT_MIRROR_SEED_FAILURE_MARKER: &str = "(.-)";\n')
    if not marker then
        why[#why + 1] = "GIT_MIRROR_SEED_FAILURE_MARKER not found in main.rs"
        return nil, 0, 0, 0, why
    end
    local arms = count(entry_src, 'retry_msg "' .. marker)
    if arms < 2 then why[#why + 1] = "entrypoint.sh prints [" .. marker .. "] in " .. arms .. " arms (want both: auth-refused and generic)" end
    local body = main_src:match("\n(async fn wait_for_git_mirror_ready%(.-\n})\n") or ""
    local calls = count(body, "last_seed_failure(&tail.lines)")
    local logs = count(body, ".log_tail(container_name")
    if calls < 2 or logs < 2 then
        why[#why + 1] = "wait_for_git_mirror_ready calls last_seed_failure " .. calls .. " times and log_tail " .. logs .. " times (want >= 2 each)"
    end
    return marker, arms, calls, logs, why
end

local main_src, entry_src = fs.read(MAIN) or "", fs.read(ENTRY) or ""
local marker, arms, calls, logs, why = judge(main_src, entry_src)
if marker and arms >= 2 then ok("1: the mirror prints the launcher's marker [" .. marker .. "] in " .. arms .. " failure arms")
else bad("1: " .. table.concat(why, "; ")) end
if calls >= 2 and logs >= 2 then
    ok("2: the seeded-gate reads the mirror log and surfaces the failure while waiting and on give-up (" .. calls .. " calls)")
else bad("2: " .. table.concat(why, "; ")) end

-- 3: mutants, judged by the same function.
local one_arm = marker and entry_src:gsub('retry_msg "' .. marker:gsub("%p", "%%%0"), 'retry_msg "seed failed (no marker):', 1) or entry_src
local _, m_arms = judge(main_src, one_arm)
local one_call = main_src:gsub("last_seed_failure%(&tail%.lines%)", "last_seed_failure_removed(&tail.lines)", 1)
local _, _, m_calls = judge(one_call, entry_src)
-- Today there are exactly two arms and two calls, so stripping one of each
-- drops below the floor; if either grows, this arm says so instead of passing.
if marker and m_arms == arms - 1 and m_arms < 2 and m_calls == calls - 1 and m_calls < 2 then
    ok("3: a failure arm without the marker and a gate body with one call are each refused (" .. m_arms .. " arm, " .. m_calls .. " call)")
else
    bad("3: mutants were not refused, or the floor moved (arms " .. tostring(arms) .. "->" .. tostring(m_arms)
        .. ", calls " .. tostring(calls) .. "->" .. tostring(m_calls) .. "); extend the mutants")
end

-- 4: the retired PASS: line, assembled so this file cannot match itself.
local NEEDLE = "PA" .. "SS: git-mirror-seed-failure-surfaced"
local SELF = "scripts/lua/test-git-mirror-seed-failure-surfaced.lua"
local searched, hits = 0, {}
for _, root in ipairs({ "scripts", "openspec/litmus-tests" }) do
    for _, f in ipairs(fs.walk(root)) do
        if f ~= SELF and (f:sub(-3) == ".sh" or f:sub(-4) == ".lua" or f:sub(-5) == ".step" or f:sub(-5) == ".yaml") then
            searched = searched + 1
            local okr, b = pcall(fs.read, f)
            if okr and b and has(b, NEEDLE) then hits[#hits + 1] = f end
        end
    end
end
if #hits == 0 and searched > 100 then
    ok("4: the retired PASS: line has 0 readers (" .. searched .. " files searched: scripts/, gate steps, litmus specs)")
else
    bad("4: readers of the retired PASS: line: " .. #hits .. " in " .. searched .. " files: " .. table.concat(hits, ", "))
end

if failed == 0 then verdict.emit("ok:git-mirror-seed-failure-surfaced", 0) end
verdict.emit("refused:git-mirror-seed-failure-surfaced:" .. failed, 1)
