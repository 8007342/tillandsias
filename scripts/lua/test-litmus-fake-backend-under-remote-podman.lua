-- @trace order:798-9xpq, order:2219-27uv, spec:litmus-framework
--
-- test-litmus-fake-backend-under-remote-podman.lua — PORTED from
-- test-litmus-fake-backend-under-remote-podman.sh (2219-27uv), same arms, same
-- lines. A `backend: fake` litmus test is REFUSED up front when a remote
-- podman is configured, because common.sh's remote mode pins
-- TILLANDSIAS_PODMAN_BIN ahead of the harness's fake and the fixture would
-- silently drive the real podman.
--   1  backend: fake + TILLANDSIAS_PODMAN_REMOTE_URL set -> [ENV-FAIL]
--      refused:litmus-gate:fake-backend-under-remote-podman naming the variable
--   1b the same with CONTAINER_HOST set instead -> refused, naming CONTAINER_HOST
--   2  NEGATIVE CONTROL: the same fake test with neither set RUNS and PASSES
--   3  a non-fake test under a remote URL is not touched by this refusal
-- Pre-fix: FAILS at arm 1 (the fake test ran and passed).
--
-- Each arm runs scripts/run-litmus-test.sh against a one-test bindings file
-- and tests dir under target/plan-scratch. Both remote variables are unset for
-- every arm (`env -u`: TILLANDSIAS_PODMAN_REMOTE_URL passes through the runner)
-- and set only by the arm that is about them.
--
-- Verdict: `PASS: litmus-fake-backend-under-remote-podman <n>/<n>` (the litmus
-- reads it) then ok:litmus-fake-backend-under-remote-podman:<n> |
-- `FAIL: ...` then violation:litmus-fake-backend-under-remote-podman:<f>

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local rel = "target/plan-scratch/fake-under-remote-" .. tostring(time.now_ms())
local W = root .. "/" .. rel
proc.run{ argv = { "mkdir", "-p", W .. "/lt" } }
local function cleanup() proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 } end

local pass, fail = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) log.raw("FAIL: " .. m); fail = fail + 1 end

local LIT = "litmus"
fs.write(rel .. "/bindings.yaml", "version: '1.0'\ndescription: fixture for 798-9xpq\nspecs:\n- spec_id: spec-traceability\n"
    .. "  status: active\n  " .. LIT .. "_tests:\n  - " .. LIT .. ":x9xpq-probe\n  coverage_ratio: 100\n"
    .. "  last_verified: '2026-09-29'\n")

-- probe(<backend line or "">, {NAME=value...}) -> runner output, colour stripped
local function probe(backend, extra)
    fs.write(rel .. "/lt/" .. LIT .. "-x9xpq-probe.yaml", "name: " .. LIT .. ":x9xpq-probe\nspec: spec-traceability\n"
        .. "phase: pre-build\nseverity: high\nsize: instant\n" .. backend .. "\ndescription: >\n  probe for 798-9xpq\n"
        .. "critical_path:\n  - step: \"probe\"\n    command: \"echo probe-done\"\n    timeout_ms: 20000\n"
        .. "    expected_behavior: \"probe-done\"\n")
    local a = { "env", "-u", "TILLANDSIAS_PODMAN_REMOTE_URL", "-u", "CONTAINER_HOST" }
    for k, v in pairs(extra or {}) do a[#a + 1] = k .. "=" .. v end
    for _, x in ipairs({ "TILLANDSIAS_LITMUS_BINDINGS=" .. W .. "/bindings.yaml", "TILLANDSIAS_LITMUS_TESTS_DIR=" .. W .. "/lt",
            "timeout", "120", "bash", "scripts/run-litmus-test.sh", "spec-traceability", "--phase", "pre-build",
            "--size", "instant" }) do a[#a + 1] = x end
    local r = proc.run{ argv = a, timeout_ms = 180000 }
    local o = (r.stdout or "") .. (r.stderr or "")
    return (o:gsub("\27%[[0-9;]*m", ""))
end
local function has(s, p) return s:find(p, 1, true) ~= nil end
local function passed(s) return has(s, "Status: [PASS]") end
-- `grep -E 'ENV-FAIL|Status' | head -3`, joined the way $(...) inside [..] showed it.
local function status_lines(s)
    local t = {}
    for _, l in ipairs(text.lines(s)) do
        if #t < 3 and (has(l, "ENV-FAIL") or has(l, "Status")) then t[#t + 1] = l end
    end
    return table.concat(t, "\n")
end
local REMOTE = "unix:///nonexistent/podman.sock"

local o = probe("backend: fake", { TILLANDSIAS_PODMAN_REMOTE_URL = REMOTE })
if o:find("refused:litmus%-gate:fake%-backend%-under%-remote%-podman.*TILLANDSIAS_PODMAN_REMOTE_URL is set") and not passed(o) then
    ok("1: a fake-backend test under TILLANDSIAS_PODMAN_REMOTE_URL is refused by name")
else bad("1: [" .. status_lines(o) .. "]") end

o = probe("backend: fake", { CONTAINER_HOST = REMOTE })
if o:find("refused:litmus%-gate:fake%-backend%-under%-remote%-podman.*CONTAINER_HOST is set") then
    ok("1b: the same under CONTAINER_HOST is refused, naming CONTAINER_HOST")
else bad("1b: [" .. status_lines(o) .. "]") end

o = probe("backend: fake", {})
if passed(o) and not has(o, "fake-backend-under-remote-podman") then
    ok("2: NEGATIVE CONTROL: the fake test with no remote configured runs and passes")
else bad("2: [" .. status_lines(o) .. "]") end

o = probe("", { TILLANDSIAS_PODMAN_REMOTE_URL = REMOTE })
if not has(o, "fake-backend-under-remote-podman") and passed(o) then
    ok("3: a non-fake test under a remote URL is not touched by this refusal")
else bad("3: [" .. status_lines(o) .. "]") end

cleanup()
local total = pass + fail
if fail == 0 then
    out.line("PASS: litmus-fake-backend-under-remote-podman " .. pass .. "/" .. total)
    verdict.ok("litmus-fake-backend-under-remote-podman:" .. pass)
end
out.line("FAIL: litmus-fake-backend-under-remote-podman " .. pass .. "/" .. total)
verdict.emit("violation:litmus-fake-backend-under-remote-podman:" .. fail, 1)
