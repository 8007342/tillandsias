-- @trace spec:litmus-framework, order:797-p2xa, order:1073-dqtx, order:2401-prg5
-- @env PATH
--
-- test-podman-mock-refusal.lua — order 797-p2xa, the NESTED half. Ported from
-- test-podman-mock-refusal.sh (2401-prg5); same scenarios, in its order.
--
-- The top-level `case` in scripts/test-support/podman-mock.sh fails closed
-- (97cb255a9). The same fall-through was reachable one level down: an inner
-- `case` that matched nothing landed on the trailing `exit 0`, so
-- `podman image ls` or `podman secret whatever` answered SUCCESS with EMPTY
-- output. The outer instance cost about four hours across three wrong
-- diagnoses on 2026-08-17 (797-vv3n), because the symptoms named neither
-- podman nor the mock.
--
-- THREE PROPERTIES, each with the control that makes it non-vacuous:
--   1 REFUSAL — an unhandled invocation exits 97, typed diagnostic on stderr,
--     nothing on stdout, at every dispatch level. Control: two different absurd
--     verbs, each REFUSED line names its OWN subject and not the other's.
--   2 DELIBERATE NO-OPS STAY NO-OPS — network/compose/system exit 0 silently.
--   3 HANDLED ARMS ARE UNCHANGED — version/info/build/ps/inspect/exec and the
--     797-vv3n `--remote --url <u> run ... gh api user/repos` shape.
--
-- ONLY THE MOCK RUNS. It is invoked by path, and a scratch `podman` that execs
-- the mock is first on PATH as well; CONTAINER_HOST, TILLANDSIAS_PODMAN_* and
-- LITMUS_* are stripped, and the mock's state lives in this fixture's scratch.
--
-- Pinned by litmus:podman-mock-refuses-unknown-invocations.
--
-- GRAMMAR ok:podman-mock-refusal:<n> arms | violation:podman-mock-refusal:<n>-failed
--       | refused:podman-mock-refusal:mock-missing

local fixture = require "common.fixture"
local T = fixture.new("podman-mock-refusal")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local MOCK_REL = "scripts/test-support/podman-mock.sh"
local MOCK = ROOT .. "/" .. MOCK_REL
-- Asserted EXACTLY, not merely non-zero: a refusal that degraded into some
-- other failure (set -e trip, syntax error, a mocked `exit 1`) is also non-zero.
local REFUSAL_EXIT = 97

if not fs.exists(MOCK_REL) then T:refuse("mock-missing", MOCK_REL .. " is absent") end

local W = T:scratch()
local STATE = W.abs .. "/state"
fs.mkdir(W.rel .. "/state")
fs.mkdir(W.rel .. "/bin")
fs.write(W.rel .. "/bin/podman", '#!/bin/sh\nexec "' .. MOCK .. '" "$@"\n')
T:must{ "chmod", "+x", W.abs .. "/bin/podman" }
local PATHV = W.abs .. "/bin:" .. (env.get("PATH") or "/usr/bin:/bin")
local UNSET = { "CONTAINER_HOST", "TILLANDSIAS_PODMAN_*", "LITMUS_*" }

local function mock(extra, ...)
    local e = { LITMUS_PODMAN_STATE_DIR = STATE, PATH = PATHV }
    for k, v in pairs(extra or {}) do e[k] = v end
    local argv = { SH, MOCK, ... }
    argv.cwd, argv.env, argv.env_unset, argv.timeout_ms = ROOT, e, UNSET, 30000
    local r = T:run(argv)
    return r.code, r.stdout or "", r.stderr or ""
end
local function run(...) return mock(nil, ...) end
local has = text.contains
local function show(rc, o, e) return "rc=" .. tostring(rc) .. " out='" .. o .. "' err='" .. e .. "'" end

-- PREMISE: the scratch `podman` on PATH is the mock, so nothing here can reach the real one.
local w = fixture.which("podman", PATHV)
T:arm("PREMISE the first podman on PATH is the scratch mock wrapper", w == W.abs .. "/bin/podman", tostring(w))

-- 1: the absurd subcommand.
local rc, o, e = run("frobnicate-the-widget", "--with-jam")
T:arm("absurd-subcommand-refused-nonzero-and-named",
    rc == REFUSAL_EXIT and o == "" and has(e, "REFUSED: unrecognized subcommand: frobnicate-the-widget"), show(rc, o, e))

-- 2: the REFUSED line carries its own subject. Reads ONLY that line: the
-- `full argv:` line echoes the verb, so grepping all of stderr was vacuous (MC4b).
local function refused_line(s)
    for _, l in ipairs(text.lines(s)) do if has(l, "REFUSED: unrecognized") then return l end end
    return ""
end
local arc, _, ae = run("alpha-not-a-podman-verb")
local brc, _, be = run("beta-not-a-podman-verb")
local al, bl = refused_line(ae), refused_line(be)
T:arm("diagnostic-subject-is-interpolated-not-canned",
    arc == REFUSAL_EXIT and brc == REFUSAL_EXIT
        and has(al, "alpha-not-a-podman-verb") and not has(al, "beta-not-a-podman-verb")
        and has(bl, "beta-not-a-podman-verb") and not has(bl, "alpha-not-a-podman-verb"),
    "alpha: " .. al .. " | beta: " .. bl)

-- 3: global flags — the 797-vv3n shape, refused on the SUBCOMMAND, argv quoted whole.
rc, o, e = run("--remote", "--url", "unix:///x", "frobnicate-the-widget")
T:arm("global-flags-skipped-refusal-names-the-verb-and-quotes-full-argv",
    rc == REFUSAL_EXIT and has(e, "REFUSED: unrecognized subcommand: frobnicate-the-widget")
        and not has(e, "REFUSED: unrecognized subcommand: --remote")
        and has(e, "full argv: podman --remote --url unix:///x frobnicate-the-widget"), show(rc, o, e))

-- 4: no subcommand at all, and only global flags.
rc, o, e = run()
T:arm("bare-invocation-refused", rc == REFUSAL_EXIT and has(e, "REFUSED: unrecognized subcommand: <empty>"), show(rc, o, e))
rc, o, e = run("--remote", "--url", "unix:///x")
T:arm("flags-without-a-verb-refused", rc == REFUSAL_EXIT and has(e, "REFUSED: unrecognized subcommand: <empty>"), show(rc, o, e))

-- 5: NESTED dispatch — the half the outer arm could not see.
rc, o, e = run("image", "frobnicate-the-widget")
T:arm("unknown-image-subcommand-refused",
    rc == REFUSAL_EXIT and o == "" and has(e, "REFUSED: unrecognized image subcommand: frobnicate-the-widget"), show(rc, o, e))
rc, o, e = run("secret", "frobnicate-the-widget")
T:arm("unknown-secret-subcommand-refused",
    rc == REFUSAL_EXIT and o == "" and has(e, "REFUSED: unrecognized secret subcommand: frobnicate-the-widget"), show(rc, o, e))

-- Bare `image inspect <tag>` (1073-dqtx): an rc with NO payload, both directions.
-- The tag is a fixture string; nothing is pulled.
local bare_tag = "localhost/tillandsias-git:0.0.0-fixture"
local bare_key = bare_tag:gsub("/", "__slash__"):gsub(":", "__colon__")
rc, o, e = run("image", "inspect", bare_tag)
T:arm("bare-image-inspect-answers-rc-with-no-payload", rc == 0 and o == "", show(rc, o, e))
fs.mkdir(W.rel .. "/state/images")
fs.write(W.rel .. "/state/images/" .. bare_key, "mock-build-id\n")
local STATEFUL = { LITMUS_PODMAN_STATEFUL_IMAGES = "1" }
rc, o, e = mock(STATEFUL, "image", "inspect", bare_tag)
T:arm("bare-image-inspect-usable-when-image-present", rc == 0 and o == "", show(rc, o, e))
-- THE ARM THAT GIVES THE OTHER THREE THEIR MEANING: an absent image is unusable, with podman's 125.
T:must{ "rm", "-f", STATE .. "/images/" .. bare_key }
rc, o, e = mock(STATEFUL, "image", "inspect", bare_tag)
T:arm("bare-image-inspect-unusable-when-image-absent", rc == 125 and o == "", show(rc, o, e))
-- CONTROL: the handled inner arm still answers.
rc, o, e = run("image", "inspect", "localhost/x:1", "--format", "{{.Size}}")
local zero = false
for _, l in ipairs(text.lines(o)) do if l == "0" then zero = true end end
T:arm("handled-image-inspect-format-unaffected", rc == 0 and zero, show(rc, o, e))

-- 6: deliberate no-ops stay silent successes.
local noop_bad = {}
for _, verb in ipairs{ { "network", "create", "tillandsias-enclave" }, { "compose", "up", "-d" }, { "system", "prune", "-f" } } do
    local vrc, vo, ve = run(table.unpack(verb))
    if vrc ~= 0 or vo ~= "" or ve ~= "" then noop_bad[#noop_bad + 1] = table.concat(verb, " ") .. " " .. show(vrc, vo, ve) end
end
T:arm("network-compose-system-remain-explicit-no-ops", #noop_bad == 0, table.concat(noop_bad, "; "))

-- 7: handled arms are unchanged.
local handled_bad = {}
local function handled(label, want, ...)
    local hrc, ho, he = run(...)
    if hrc ~= 0 or (want and not has(ho, want)) then handled_bad[#handled_bad + 1] = label .. " " .. show(hrc, ho, he) end
end
handled("version", "podman version 5.0.0-mock", "version")
handled("--version", "podman version 5.0.0-mock", "--version")
handled("info", "{}", "info")
handled("build", "mock-build-id", "build", "-t", "localhost/mock:test", ".")
handled("ps", nil, "ps", "--format", "json")
handled("inspect", "Secrets", "inspect", "some-container")
handled("exec", "authenticated", "exec", "ctr", "gh", "auth", "status")
handled("image exists", nil, "image", "exists", "localhost/x:1")
T:arm("handled-arms-still-answer", #handled_bad == 0, table.concat(handled_bad, "; "))

-- 8: the original incident shape end to end reaches the run arm and prints a JSON array.
rc, o, e = run("--remote", "--url", "unix:///x", "run", "--rm", "localhost/git:latest", "gh", "api", "user/repos")
local arr = false
for _, l in ipairs(text.lines(o)) do if l:sub(1, 16) == '[{"name":"forge"' then arr = true end end
T:arm("remote-form-run-reaches-the-run-arm", rc == 0 and arr, show(rc, o, e))

T:finish()
