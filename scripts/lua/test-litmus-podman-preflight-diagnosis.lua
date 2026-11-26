-- @trace spec:litmus-framework, order:797-5kqe, order:618-i4s6, order:1576-yqmc, order:1096-p3tn, order:2399-lrg3
-- @env PATH HOME
--
-- test-litmus-podman-preflight-diagnosis.lua — the litmus runner's podman preflight must tell a
-- podman that FAILED INSTANTLY from one that STALLED, and must fire only on tests that invoke
-- podman. Ported from test-litmus-podman-preflight-diagnosis.sh (2399-lrg3); same checks, in
-- its order.
--
--   A  an instant non-zero exit is not described as '>5s', not classified as environmental,
--      reports the observed exit status (never timeout(1)'s 124), quotes podman's own stderr,
--      and is not reported with the timeout wording
--   B  a podman sleeping past the deadline IS reported as a timeout ('within 5s', exit 124),
--      and not as an immediate failure
--   C  the scope control: a spec that MENTIONS podman but never invokes it is not ENV-FAILed
--      by a broken podman (premise guarded: it must mention podman, invoke it nowhere, and be
--      selectable), and the stub really is broken and first on PATH
--
-- Both fixtures drive the REAL runner against a REAL bound litmus test. The preflight fires on
-- LINUX HOSTS ONLY, by design (1576-yqmc); elsewhere the whole test is one named skip.
--
-- Hermetic: the only podman a child can reach is a scratch stub, first on PATH. LITMUS_PODMAN_*,
-- TILLANDSIAS_PODMAN_*, CONTAINER_HOST and TILLANDSIAS_* are stripped, so the run cannot slide
-- into the fake backend or reach a real socket. The timing log is named into scratch (1096-p3tn).
--
-- GRAMMAR ok:litmus-podman-preflight-diagnosis:<n> arms
--       | violation:litmus-podman-preflight-diagnosis:<n>-failed
--       | skip:litmus-podman-preflight-diagnosis:linux-only-preflight

local fixture = require "common.fixture"
local T = fixture.new("litmus-podman-preflight-diagnosis")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()

local os_name = text.trim(T:run{ "uname", "-s" }.stdout or "")
if os_name ~= "Linux" then T:skip("linux-only-preflight") end

local W = T:scratch()
fs.mkdir(W.rel .. "/instant-fail"); fs.mkdir(W.rel .. "/slow")
fs.write(W.rel .. "/instant-fail/podman",
    '#!/usr/bin/env bash\necho "fixture: exec target vanished (this is the 127 class)" >&2\nexit 127\n')
fs.write(W.rel .. "/slow/podman", "#!/usr/bin/env bash\nsleep 10\nexit 0\n")
T:must{ "chmod", "+x", W.abs .. "/instant-fail/podman", W.abs .. "/slow/podman" }
local BASE_PATH = env.get("PATH") or ""

local TARGET_SPEC = "podman-orchestration"
local function run_runner(bin, spec)
    local r = T:run{ SH, "scripts/run-litmus-test.sh", spec or TARGET_SPEC, "--phase", "pre-build", "--size", "instant",
        "--compact", cwd = ROOT, stdin = "", timeout_ms = 170000,
        env_unset = { "LITMUS_PODMAN_*", "TILLANDSIAS_*", "CONTAINER_HOST", "PROJECT_ROOT" },
        env = { NO_COLOR = "1", PATH = W.abs .. "/" .. bin .. ":" .. BASE_PATH,
            TILLANDSIAS_TIMING_LOG = W.abs .. "/timing-FIXTURES.jsonl" } }
    return (r.stdout or "") .. (r.stderr or "")
end
local has = text.contains

-- Fixture A — instant non-zero exit.
local a = run_runner("instant-fail")
if not T:arm("fixture A reaches the podman preflight", has(a, "[ENV-FAIL]"), a) then
    -- nothing below can be asked
else
    T:arm("instant failure is not described as '>5s'", not has(a, ">5s"))
    T:arm("instant failure is not classified as environmental", not has(a, "environmental, not a code regression"))
    -- The observed status: a number is reported, and it is not timeout(1)'s 124 (the immediate
    -- status is the runner's recording wrapper's, so no specific number is pinned).
    local st = a:match("FAILED IMMEDIATELY with exit %d+")
    T:arm("the observed exit status is reported, and it is not 124",
        st ~= nil and st ~= "FAILED IMMEDIATELY with exit 124", tostring(st))
    T:arm("podman's own stderr is quoted", has(a, "fixture: exec target vanished"))
    T:arm("instant failure is not reported with the timeout wording", not has(a, "within 5s"))
end

-- Fixture B — the genuine timeout.
local b = run_runner("slow")
if T:arm("fixture B reaches the podman preflight", has(b, "[ENV-FAIL]"), b) then
    T:arm("a real stall is reported as a timeout", has(b, "within 5s"), b)
    T:arm("the timeout is identified by timeout(1)'s own 124, not by inference", has(b, "exit 124"), b)
    T:arm("a real stall is not reported as an immediate failure", not has(b, "FAILED IMMEDIATELY"))
end

-- Fixture C — THE SCOPE CONTROL (618-i4s6). The control must MENTION podman without INVOKING
-- it, and the runner must actually select it.
local UNGATED = "enclave-network"
local carriers, mentions = 0, 0
local ls = T:must{ "git", "ls-files", "openspec/litmus-tests/*.yaml", cwd = ROOT }
local function field(s, k)
    for _, l in ipairs(text.lines(s)) do
        local v = l:match("^" .. k .. ":%s*(.-)%s*$")
        if v then return v end
    end
end
for _, f in ipairs(text.lines(ls.stdout or "")) do
    local s = f ~= "" and fs.read(f) or nil
    if s and field(s, "spec") == UNGATED and field(s, "phase") == "pre-build" and field(s, "size") == "instant" then
        local carries = false
        for _, l in ipairs(text.lines(s)) do
            local rest = l:match("^%s*command:(.*)$")
            if rest and rest:find("[ ;|&(]podman%s") then carries = true end
        end
        if carries then carriers = carriers + 1 end
        if has(s, "podman") then mentions = mentions + 1 end
    end
end
if not T:arm("fixture C's control mentions podman in its instant pre-build bucket (else it is toothless)",
    mentions > 0, UNGATED .. " mentions=0") then
    -- premise failed
elseif not T:arm("fixture C's control invokes podman on no command line (premise)", carriers == 0,
    UNGATED .. " carriers=" .. carriers) then
    -- premise drifted
else
    local c = run_runner("instant-fail", UNGATED)
    T:arm("fixture C selects something (" .. UNGATED .. " is a selectable bound spec_id)",
        not has(c, "no litmus tests matched"), c)
    T:arm("a litmus that never invokes podman is NOT gated on podman being healthy", not has(c, "[ENV-FAIL]"), c)
    -- POSITIVE HALF: the stub really was broken and first on PATH.
    local stub_path = W.abs .. "/instant-fail:" .. BASE_PATH
    local hit = fixture.which("podman", stub_path)
    local pr = hit and T:run{ hit, "ps", env = { PATH = stub_path } } or { code = -1 }
    T:arm("the stub podman really is broken and first on PATH (so C's green is scoping, not luck)",
        hit == W.abs .. "/instant-fail/podman" and pr.code ~= 0, "hit=" .. tostring(hit) .. " rc=" .. tostring(pr.code))
end

T:finish()
