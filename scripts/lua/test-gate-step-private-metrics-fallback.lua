-- @env PATH
-- @trace order:1966-ubsw, order:1204-3s2s, order:1916-tsel, spec:ci-release
--
-- test-gate-step-private-metrics-fallback.lua — a record some OTHER process
-- writes into the host's shared timing fallback never evicts the gate step
-- running beside it, while a step whose own children fall back is still
-- refused (1966-ubsw).
--
-- #831 (2026-11-01) and #840 (2026-11-02) were evicted on macuahuitl's gate by
-- one id-less record in /tmp/tillandsias-timing.jsonl, during two DIFFERENT
-- steps with no other gate live: a host-side writer, blamed on whichever step
-- ran. Now the gate gives its own tree a PRIVATE fallback
-- (TILLANDSIAS_METRICS_FALLBACK_DIR, honoured by scripts/metrics-log-path.sh,
-- the plan binary and cycle-metrics.sh), refuses on growth there, and only
-- WARNS, quoting the line, on an id-less record in the shared path.
--
-- Every arm EXECUTES the real step loop (`./build.sh --gate-steps <root>`)
-- over a scratch root with one stub step; the shared path is a scratch file
-- (TILLANDSIAS_GATE_SHARED_TIMING_PATH), never the host's /tmp:
--   1 FOREIGN    an id-less record lands in the shared path during a clean
--                step: the gate passes, and the warning quotes the line
--                (pre-fix: refused, unattributed=1)
--   2 LEAK       the step's child falls back (no checkout): the record lands
--                in the gate's private fallback, the gate refuses, and the
--                refusal quotes the line
--   3 OURS       a record stamped with THIS gate's run id in the shared path
--                still refuses (1916-tsel teeth)
--   4 CLEAN      a step that writes nothing passes with no warning
--
-- Usage: tillandsias-plan script run scripts/lua/test-gate-step-private-metrics-fallback.lua
-- Verdict: ok:gate-step-private-metrics-fallback:<n> arms | violation:gate-step-private-metrics-fallback:<n>-failed

local NAME = "gate-step-private-metrics-fallback"
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer")
end
local uname = text.trim(proc.run({ argv = { "uname", "-s" } }).stdout or "")
if uname ~= "Linux" and uname ~= "Darwin" then
    verdict.emit("skip:" .. NAME .. ":" .. uname .. "-re-execs-build-sh-into-wsl", 0)
end

local passed, failed = 0, {}
local function arm(name, cond, got)
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name)
    else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end
local function readf(p) return fs.exists(p) and (fs.read(p) or "") or "" end

local REL = "target/plan-scratch/gate-private-fallback-" .. tostring(time.now_ms())
local ABS = ROOT .. "/" .. REL
local SHARED = ABS .. "/shared-timing.jsonl"

-- root(name, body): a scratch root whose one step runs `body` in bash.
local function root(name, body)
    local r = REL .. "/" .. name
    fs.mkdir(r .. "/scripts/gate-steps.d")
    fs.write(r .. "/scripts/stub.sh", "#!/usr/bin/env bash\n" .. body .. "\necho ok:stub\n")
    fs.write(r .. "/scripts/gate-steps.d/500-stub.step", table.concat({
        'STEP_DESC="Stub step (private-fallback fixture)"',
        'STEP_SCRIPT="scripts/stub.sh"',
        'STEP_ERROR="stub step failed"',
        'STEP_OK="stub step passed"',
    }, "\n") .. "\n")
    return ROOT .. "/" .. r
end

-- Each inner gate gets its OWN private fallback under the scratch root. build.sh
-- keeps an inherited TILLANDSIAS_METRICS_FALLBACK_DIR, so without this the inner
-- gate reused the OUTER gate's dir and the LEAK arm's child wrote its record into
-- the real gate's fallback, which then refused this step for a leak.
local gates = 0
local function gate(r)
    proc.run({ argv = { "rm", "-f", SHARED } })
    gates = gates + 1
    local fb = ABS .. "/fallback-" .. tostring(gates)
    fs.mkdir(REL .. "/fallback-" .. tostring(gates))
    local res = proc.run({ argv = { "./build.sh", "--gate-steps", r }, timeout_ms = 300000,
        env = { TILLANDSIAS_GATE_SHARED_TIMING_PATH = SHARED, TILLANDSIAS_TIMING_RUN_ID = "gate-fixture-1966",
                TILLANDSIAS_METRICS_FALLBACK_DIR = fb } })
    return res.code, (res.stdout or "") .. (res.stderr or "")
end

local FOREIGN_LINE = '{"step":"tray-bringup","duration_ms":7,"host":"foreign-writer-1966"}'

-- 1 FOREIGN
local rc, o = gate(root("foreign", "printf '%s\\n' '" .. FOREIGN_LINE .. "' >> \"$TILLANDSIAS_GATE_SHARED_TIMING_PATH\""))
arm("1 FOREIGN an id-less record in the shared path does not refuse the clean step", rc == 0, "rc=" .. tostring(rc) .. "\n" .. o)
arm("1 FOREIGN and the warning quotes the line", o:find("foreign-writer-1966", 1, true) ~= nil
    and o:find("1966-ubsw", 1, true) ~= nil, o)

-- 2 LEAK: the child resolves the fallback the production way, from outside a
-- checkout. If the fallback were NOT private it would be the host's /tmp file:
-- divert to the scratch shared path instead, so a regression reds this arm
-- without ever writing the host's log.
local nc = ABS .. "/not-a-checkout"
fs.mkdir(REL .. "/not-a-checkout/scripts")
fs.write(REL .. "/not-a-checkout/scripts/metrics-log-path.sh", fs.read("scripts/metrics-log-path.sh") or "")
rc, o = gate(root("leak", table.concat({
    "cd " .. nc .. " || exit 3",
    "unset PROJECT_ROOT; . " .. nc .. "/scripts/metrics-log-path.sh",
    'p="$(metrics_default_log tillandsias-timing.jsonl 2>/dev/null)"',
    'echo "resolved=$p fb=${TILLANDSIAS_METRICS_FALLBACK_DIR:-unset}"',
    'if [ "$p" = /tmp/tillandsias-timing.jsonl ]; then echo "fallback-not-private"; p="$TILLANDSIAS_GATE_SHARED_TIMING_PATH"; fi',
    "printf '%s\\n' '{\"step\":\"leaky-child-1966\",\"duration_ms\":1}' >> \"$p\"",
}, "\n")))
arm("2 LEAK a child that falls back is refused through the private fallback",
    rc ~= 0 and o:find("leaked record", 1, true) ~= nil and o:find("gate-fallback/", 1, true) ~= nil
        and o:find("fallback-not-private", 1, true) == nil, "rc=" .. tostring(rc) .. "\n" .. o)
arm("2 LEAK and the refusal quotes the leaked line", o:find("leaky-child-1966", 1, true) ~= nil, o)

-- 3 OURS
rc, o = gate(root("ours", "printf '{\"step\":\"x\",\"duration_ms\":1,\"run_id\":\"%s\"}\\n' \"$TILLANDSIAS_TIMING_RUN_ID\" >> \"$TILLANDSIAS_GATE_SHARED_TIMING_PATH\""))
arm("3 OURS a record carrying this gate's run id in the shared path still refuses",
    rc ~= 0 and o:find("leaked record", 1, true) ~= nil, "rc=" .. tostring(rc) .. "\n" .. o)

-- 4 CLEAN
rc, o = gate(root("clean", ":"))
arm("4 CLEAN a step that writes nothing passes with no leak warning",
    rc == 0 and o:find("1966-ubsw", 1, true) == nil and o:find("leaked record", 1, true) == nil, "rc=" .. tostring(rc) .. "\n" .. o)

proc.run({ argv = { "rm", "-rf", ABS } })
if #failed > 0 then
    verdict.emit("violation:" .. NAME .. ":" .. #failed .. "-failed", 1)
end
verdict.emit("ok:" .. NAME .. ":" .. passed .. " arms", 0)
