-- @trace order:798-9xpq, order:2375-ch7i, spec:litmus-framework
--
-- test-litmus-fake-backend-under-remote-podman.lua — a `backend: fake` litmus test is
-- REFUSED up front when a remote podman is configured: common.sh's remote mode pins
-- TILLANDSIAS_PODMAN_BIN ahead of the harness's fake, and the fixture would silently drive
-- the real podman. Ported from the .sh (2375-ch7i).
--
--   1 under TILLANDSIAS_PODMAN_REMOTE_URL it is refused, naming the variable
--   1b under CONTAINER_HOST likewise
--   2 NEGATIVE: with neither set the same test runs and passes
--   3 a non-fake test under a remote URL is untouched
-- Each arm runs run-litmus-test.sh over a one-test bindings file. The probe's name is
-- built, so check-litmus-pin-claims does not read it as a claim on a real litmus test.
--
-- Verdict: PASS: litmus-fake-backend-under-remote-podman <n>/<n> (the litmus reads it), then
--          ok:litmus-fake-backend-under-remote-podman:<n> | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("litmus-fake-backend-under-remote-podman")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local W = T:scratch()
fs.mkdir(W.rel .. "/lt")
local LIT = "litmus"
fs.write(W.rel .. "/bindings.yaml", "version: '1.0'\ndescription: fixture for 798-9xpq\nspecs:\n- spec_id: spec-traceability\n  status: active\n  "
    .. LIT .. "_tests:\n  - " .. LIT .. ":x9xpq-probe\n  coverage_ratio: 100\n  last_verified: '2026-09-29'\n")
local function probe(backend, extra)
    fs.write(W.rel .. "/lt/" .. LIT .. "-x9xpq-probe.yaml", "name: " .. LIT .. ":x9xpq-probe\nspec: spec-traceability\nphase: pre-build\nseverity: high\nsize: instant\n" .. backend
        .. "\ndescription: >\n  probe for 798-9xpq\ncritical_path:\n  - step: \"probe\"\n    command: \"echo probe-done\"\n    timeout_ms: 20000\n    expected_behavior: \"probe-done\"\n")
    local e = { TILLANDSIAS_LITMUS_BINDINGS = W.abs .. "/bindings.yaml", TILLANDSIAS_LITMUS_TESTS_DIR = W.abs .. "/lt", TILLANDSIAS_PLAN_BIN = fixture.plan_binary() }
    for k, v in pairs(extra or {}) do e[k] = v end
    local r = T:run{ SH, "scripts/run-litmus-test.sh", "spec-traceability", "--phase", "pre-build", "--size", "instant", cwd = ROOT, env = e,
        env_unset = { "TILLANDSIAS_*", "CONTAINER_HOST" }, timeout_ms = 180000 }
    return (((r.stdout or "") .. (r.stderr or "")):gsub("\27%[[0-9;]*m", ""))
end
local RULE = "refused:litmus-gate:fake-backend-under-remote-podman"
local function refused(o, var) local i = o:find(RULE, 1, true); return i and o:find(var .. " is set", i, true) ~= nil end
local function passed(o) return o:find("Status: [PASS]", 1, true) ~= nil end
local REMOTE = "unix:///nonexistent/podman.sock"
local o = probe("backend: fake", { TILLANDSIAS_PODMAN_REMOTE_URL = REMOTE })
T:arm("1 a fake-backend test under TILLANDSIAS_PODMAN_REMOTE_URL is refused by name", refused(o, "TILLANDSIAS_PODMAN_REMOTE_URL") and not passed(o), o:sub(-600))
o = probe("backend: fake", { CONTAINER_HOST = REMOTE })
T:arm("1b the same under CONTAINER_HOST, naming it", refused(o, "CONTAINER_HOST") and not passed(o), o:sub(-600))
o = probe("backend: fake")
T:arm("2 NEGATIVE the fake test with no remote configured runs and passes", passed(o) and not o:find("fake-backend-under-remote-podman", 1, true), o:sub(-600))
o = probe("", { TILLANDSIAS_PODMAN_REMOTE_URL = REMOTE })
T:arm("3 a non-fake test under a remote URL is untouched", passed(o) and not o:find("fake-backend-under-remote-podman", 1, true), o:sub(-600))
if #T.failed == 0 then out.line("PASS: litmus-fake-backend-under-remote-podman " .. T.passed .. "/" .. T.passed) end
T:finish({ ok = function(n) return "ok:litmus-fake-backend-under-remote-podman:" .. n end })
