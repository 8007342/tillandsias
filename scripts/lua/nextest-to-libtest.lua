-- @trace order:2243-urcy
--
-- nextest-to-libtest.lua — rewrite a `cargo nextest run` log into the
-- `cargo test` transcript shape scripts/check-test-baseline.sh already parses,
-- so the failure-set ratchet keeps working when the gate runs nextest.
--
-- WHY (2026-11-23, yoga, 10-run soak): nextest runs the workspace set in ~28 s
-- against `cargo test`'s ~91 s and the tray,listen-vsock set in ~45 s against
-- ~97 s, 0 failures in 20 runs, because it runs test BINARIES concurrently and
-- each test in its own process. The ratchet keys a test as
-- `<binary stem>::<test name>`; this keeps those keys IDENTICAL to cargo test's,
-- so scripts/test-known-red.txt entries mean the same thing under either runner.
--
-- MAPPING (nextest binary id -> cargo's binary stem):
--   crate                -> crate with - as _        (the lib unittests)
--   crate::bin/name      -> name                     (a bin's unittests)
--   crate::target        -> target                   (an integration test)
-- Results: PASS -> ok; FAIL, SIG*, TIMEOUT, LEAK-FAIL, ABORT -> FAILED. nextest
-- repeats every failure in its closing summary, so each key is emitted once.
--
-- Usage: tillandsias-plan script run --helper scripts/lua/nextest-to-libtest.lua -- <nextest.log>
-- Output (stdout): `     Running <stem> (target/debug/deps/<stem>-0)` per binary and
--   `test <name> ... ok|FAILED` per test. A log with no result lines prints
--   nothing, which the ratchet already refuses as "no test results".

local path = arg and arg[1]
if not path or path == "" then error("usage: nextest-to-libtest.lua <nextest.log>") end
local body = fs.read(path)
if not body then error("cannot read " .. path) end

local function stem(id)
    local tgt = id:match("::(.+)$")
    if tgt then
        return (tgt:gsub("^bin/", ""))
    end
    return (id:gsub("%-", "_"))
end

local FAILED = { FAIL = true, TIMEOUT = true, ["LEAK-FAIL"] = true, ABORT = true }
local seen, current = {}, nil
for _, l in ipairs(text.lines(body)) do
    -- `        PASS [   0.004s] (   1/3565) crate::target some::test`
    local status, rest = l:match("^%s+([A-Z][A-Z-]*)%s+%[[^%]]*%]%s+(.*)$")
    if status and (status == "PASS" or FAILED[status] or status:match("^SIG")) then
        rest = rest:gsub("^%([^%)]*%)%s+", "")
        local id, name = rest:match("^(%S+)%s+(%S+)$")
        if id and name then
            local s = stem(id)
            local key = s .. "::" .. name
            local res = (status == "PASS") and "ok" or "FAILED"
            if seen[key] == nil or (res == "FAILED" and seen[key] == "ok") then
                if s ~= current then
                    out.line("     Running " .. s .. " (target/debug/deps/" .. s .. "-0)")
                    current = s
                end
                out.line("test " .. name .. " ... " .. res)
                seen[key] = res
            end
        end
    end
end
