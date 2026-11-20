-- @trace order:2080-zcur
--
-- test-podman-mock-secret-lifecycle.lua — the litmus podman mock
-- (scripts/test-support/podman-mock.sh) keeps a real secret lifecycle, so a
-- litmus that creates, inspects and removes a secret through it sees what
-- podman would answer.
--   1 inspect finds the created secret (plain and with --format)
--   2 rm removes it (rc 0 and the file is gone)
--   3 re-inspect after rm answers absent
--   4 rm of a missing secret fails; --ignore tolerates it
--   5 rm takes several names; --all removes the rest
-- Ported from scripts/test-podman-mock-secret-lifecycle.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-podman-mock-secret-lifecycle.lua
-- Verdict: ok:podman-mock-secret-lifecycle:<n> arms | violation:podman-mock-secret-lifecycle:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("podman-mock-secret-lifecycle")
local MOCK = fixture.repo_root() .. "/scripts/test-support/podman-mock.sh"
local W = T:scratch()
local SD = W.rel .. "/secrets"

local function m(args, stdin)
    local argv = { "bash", MOCK }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    argv.env = { LITMUS_PODMAN_STATE_DIR = W.abs }
    argv.stdin = stdin
    return T:run(argv).code
end
local function left()
    local names = {}
    for _, p in ipairs(fs.exists(SD) and fs.list(SD) or {}) do names[#names + 1] = p:match("([^/]+)$") end
    table.sort(names)
    return table.concat(names, " ")
end

m({ "secret", "create", "my-secret", "-" }, "hunter2")
local r1, r1b = m{ "secret", "inspect", "my-secret" }, m{ "secret", "inspect", "--format", "{{.Name}}", "my-secret" }
T:arm("1: inspect finds the created secret (plain and with --format)", r1 == 0 and r1b == 0,
    "rc=" .. tostring(r1) .. " / --format rc=" .. tostring(r1b))
local r2 = m{ "secret", "rm", "my-secret" }
T:arm("2: rm removes it (rc 0 and the file is gone)", r2 == 0 and not fs.exists(SD .. "/my-secret"),
    "rc=" .. tostring(r2) .. " file " .. (fs.exists(SD .. "/my-secret") and "SURVIVES" or "is gone"))
T:arm("3: re-inspect after rm answers absent", m{ "secret", "inspect", "my-secret" } ~= 0, "still found")
local r4, r4b = m{ "secret", "rm", "my-secret" }, m{ "secret", "rm", "--ignore", "my-secret" }
T:arm("4: rm of a missing secret fails; --ignore tolerates it", r4 ~= 0 and r4b == 0,
    "rm missing rc=" .. tostring(r4) .. ", --ignore rc=" .. tostring(r4b))
m({ "secret", "create", "s1", "-" }, "a"); m({ "secret", "create", "s2", "-" }, "b"); m({ "secret", "create", "s3", "-" }, "c")
local r5 = m{ "secret", "rm", "s1", "s2" }
local l1 = left()
local r5b = m{ "secret", "rm", "--all" }
local l2 = left()
T:arm("5: rm takes several names; --all removes the rest", r5 == 0 and l1 == "s3" and r5b == 0 and l2 == "",
    "multi rm rc=" .. tostring(r5) .. " left=[" .. l1 .. "]; --all rc=" .. tostring(r5b) .. " left=[" .. l2 .. "]")

T:finish()
