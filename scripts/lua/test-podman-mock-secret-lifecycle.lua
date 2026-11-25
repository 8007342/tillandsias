-- @trace order:813-frih, order:2302-pspt, spec:litmus-framework
-- @env TILLANDSIAS_TEST_MOCK
--
-- test-podman-mock-secret-lifecycle.lua — the podman mock's `secret rm` and
-- `secret inspect` act on the secret NAMED, at its real argv position. Before
-- 813-frih both read $2 (the sub-subcommand): rm deleted a file named "rm" and
-- exited 0 with the secret still on disk, and inspect always answered absent.
-- Ported from test-podman-mock-secret-lifecycle.sh (2302-pspt).
--
--   1 inspect finds a created secret (also with --format X before the name)
--   2 rm removes it: rc 0 AND the file is gone
--   3 re-inspect answers absent
--   4 rm of a missing secret fails like podman; --ignore tolerates it
--   5 rm takes several names; --all removes everything
--
-- GRAMMAR ok:podman-mock-secret-lifecycle:5 arms | violation:podman-mock-secret-lifecycle:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("podman-mock-secret-lifecycle")
local ROOT = fixture.repo_root()
local MOCK = env.get("TILLANDSIAS_TEST_MOCK") or (ROOT .. "/scripts/test-support/podman-mock.sh")
local W = T:scratch()
local SD = W.abs .. "/secrets"
local SH = fixture.posix_shell()

local function m(stdin, ...)
    local argv = { SH, MOCK, ... }
    local r = proc.run{ argv = argv, env = { LITMUS_PODMAN_STATE_DIR = W.abs }, stdin = stdin, timeout_ms = 30000 }
    return (r.status == "exited") and r.code or -1
end
local function exists(p) return proc.run{ argv = { "test", "-e", p } }.code == 0 end
local function listing()
    local r = proc.run{ argv = { "ls", SD } }
    local names = {}
    for _, l in ipairs(text.lines(r.stdout or "")) do if l ~= "" then names[#names + 1] = l end end
    return names
end

m("hunter2", "secret", "create", "my-secret", "-")
local r1 = m(nil, "secret", "inspect", "my-secret")
local r1b = m(nil, "secret", "inspect", "--format", "{{.Name}}", "my-secret")
T:arm("1: inspect finds the created secret (plain and with --format)", r1 == 0 and r1b == 0,
    "rc=" .. r1 .. " / --format rc=" .. r1b)

local r2 = m(nil, "secret", "rm", "my-secret")
local gone = not exists(SD .. "/my-secret")
T:arm("2: rm removes it (rc 0 and the file is gone)", r2 == 0 and gone,
    "rc=" .. r2 .. " and the file " .. (gone and "is gone" or "SURVIVES"))

local r3 = m(nil, "secret", "inspect", "my-secret")
T:arm("3: re-inspect after rm answers absent", r3 ~= 0, "re-inspect still finds the removed secret")

local r4 = m(nil, "secret", "rm", "my-secret")
local r4b = m(nil, "secret", "rm", "--ignore", "my-secret")
T:arm("4: rm of a missing secret fails; --ignore tolerates it", r4 ~= 0 and r4b == 0,
    "rm missing rc=" .. r4 .. " (want non-zero), --ignore rc=" .. r4b .. " (want 0)")

m("a", "secret", "create", "s1", "-"); m("b", "secret", "create", "s2", "-"); m("c", "secret", "create", "s3", "-")
local r5 = m(nil, "secret", "rm", "s1", "s2")
local left = table.concat(listing(), " ")
local r5b = m(nil, "secret", "rm", "--all")
local left2 = #listing()
T:arm("5: rm takes several names; --all removes the rest", r5 == 0 and left == "s3" and r5b == 0 and left2 == 0,
    "multi rm rc=" .. r5 .. " left=[" .. left .. "]; --all rc=" .. r5b .. " left=" .. left2)

T:finish()
