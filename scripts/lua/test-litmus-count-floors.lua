-- @trace order:1929-gfxy
--
-- test-litmus-count-floors.lua — the three growth-fragile "N passed" pins that
-- 1929-gfxy's sweep noted are floors now, judged the way the runner judges a
-- success_pattern (grep -E over the step's output). For each pin with floor N:
--   accepts N, N+2 and 12+N passed with 0 failed;
--   refuses N-1 passed, a failed test, and a FAILED run;
--   and the retired exact pin refuses N+1 (the growth it was swapped out for).
--
-- Usage: tillandsias-plan script run scripts/lua/test-litmus-count-floors.lua

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 10000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
if ROOT == "" then verdict.could_not_run("litmus-count-floors", "not inside a git checkout") end

-- litmus file, floor, the exact pin it replaced
local PINS = {
    { "litmus-dead-tray-run-is-reaped", 5, "test result: ok. 5 passed" },
    { "litmus-no-credentials-at-rest", 5, "5 passed" },
    { "litmus-host-browser-mcp-lane-socket-shape", 2, "test result: ok. 2 passed" },
}

local function matches(pattern, output)
    local r = run({ "grep", "-Eq", "--", pattern }, { stdin = output })
    return r.status == "exited" and r.code == 0
end
local function result(n, failed, word)
    return "running " .. n .. " tests\ntest result: " .. (word or "ok") .. ". " .. n ..
        " passed; " .. failed .. " failed; 0 ignored; 0 measured; 900 filtered out\n"
end

local passed, failed = 0, 0
local function check(name, cond, why)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else failed = failed + 1; out.line("FAIL: " .. name .. " — " .. why) end
end

for _, p in ipairs(PINS) do
    local file, n, old = p[1], p[2], p[3]
    local ok_read, src = pcall(fs.read, "openspec/litmus-tests/" .. file .. ".yaml")
    if not ok_read then verdict.could_not_run("litmus-count-floors", file .. ".yaml unreadable") end
    -- The one success_pattern that carries a passed-count floor.
    local pat
    for line in src:gmatch("[^\n]+") do
        local v = line:match('^%s*success_pattern:%s*"(.*passed; 0 failed)"%s*$')
        if v then pat = v:gsub("\\\\", "\\") end
    end
    if not pat then
        check(file .. " has a floor pattern", false, "no success_pattern ending 'passed; 0 failed' — still an exact pin")
    else
        check(file .. " accepts " .. n .. ", " .. (n + 2) .. " and " .. (n + 12) .. " passed",
            matches(pat, result(n, 0)) and matches(pat, result(n + 2, 0)) and matches(pat, result(n + 12, 0)),
            "pattern " .. pat)
        check(file .. " refuses " .. (n - 1) .. " passed, a failed test and FAILED",
            not matches(pat, result(n - 1, 0)) and not matches(pat, result(n, 1))
                and not matches(pat, result(n, 1, "FAILED")),
            "pattern " .. pat)
        check(file .. " the retired exact pin refuses " .. (n + 1) .. " passed",
            not matches(old:gsub("%.", "\\."), result(n + 1, 0)),
            "the old pin '" .. old .. "' accepts growth, so swapping it proved nothing")
    end
end

if failed == 0 then verdict.emit("ok:litmus-count-floors:" .. passed .. "/" .. passed, 0) end
verdict.emit("refused:litmus-count-floors:" .. failed .. "-failed", 1)
