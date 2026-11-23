-- @trace order:1916-tsel, order:1204-3s2s, order:2233-vxu9, spec:ci-release
--
-- Fixture: the gate's shared-timing-log leak check blames a step ONLY for
-- records its own gate wrote, so two gates on one host stop evicting each
-- other's PRs (coordinator 2026-10-29: two land-queue evictions).
-- Ported from test-gate-step-metrics-attribution.sh (2233-vxu9); gate B is a
-- proc.spawn'ed writer, killed before the fixture ends.
--
-- Two CONCURRENT writers append to one scratch log (never the host's real
-- /tmp/tillandsias-timing.jsonl):
--   gate A runs step "clean"  (writes nothing)   and step "leaky" (writes)
--   gate B, a different run id, writes records the whole time.
--   1 the clean step is not named although B grew the file during it
--   2 the leaky step IS named (ours>0) although B wrote too
--   3 an id-less record WHILE another gate is live only warns
--   4 build.sh's step loop hands the helper its run id and refuses on verdict
--   5 an id-less record with NO concurrent gate still refuses (the leak gate
--     keeps its teeth for a fixture that scrubbed its env)
-- FAILS ON THE PRE-FIX TREE: the helper does not exist there, and the old
-- growth check names the clean step.
--
-- Every append, A's and B's, is a shell `>>` (a helper file), never a Lua
-- read-and-rewrite, which would drop B's concurrent lines.
--
-- Verdict: ok:gate-step-metrics-attribution:<n> | violation:gate-step-metrics-attribution:<n>-of-<m>
-- (the .sh printed FAIL:…; the runtime takes house verdict words only, and
-- build.sh reads the exit status, not the word)

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local H = root .. "/scripts/gate-step-metrics-attribution.sh"
local pass, failn = 0, 0
local function ok(n) pass = pass + 1; out.line("ok:arm-" .. n) end
local function bad(n, m) failn = failn + 1; out.line("FAIL:arm-" .. n .. " — " .. m) end
if not fs.exists("scripts/gate-step-metrics-attribution.sh") then
    verdict.emit("violation:gate-step-metrics-attribution:helper-missing — the leak check still attributes by file growth", 1)
end

local rel = "target/plan-scratch/gsma-fx-" .. tostring(time.now_ms())
local W = root .. "/" .. rel
proc.run{ argv = { "mkdir", "-p", W } }
local LOG = W .. "/shared-timing.jsonl"
fs.write(rel .. "/rec.sh",
    "if [ -n \"$3\" ]; then printf '{\"step\":\"%s\",\"duration_ms\":1,\"run_id\":\"%s\"}\\n' \"$2\" \"$3\" >> \"$1\"\n"
    .. "else printf '{\"step\":\"%s\",\"duration_ms\":1}\\n' \"$2\" >> \"$1\"; fi\n")
fs.write(rel .. "/gate-b.sh",
    "for _ in $(seq 1 400); do bash \"$2\" \"$1\" other-gate gate-B; sleep 0.005; done\n")

local function rec(step, run_id) proc.run{ argv = { "bash", W .. "/rec.sh", LOG, step, run_id or "" } } end
local function lines()
    if not fs.exists(rel .. "/shared-timing.jsonl") then return 0 end
    local _, n = fs.read(rel .. "/shared-timing.jsonl"):gsub("\n", "")
    return n
end
local function pause(s) proc.run{ argv = { "sleep", s } } end
local function attribute(before, extra_env)
    local r = proc.run{ argv = { "bash", H, LOG, tostring(before), "gate-A" }, env = extra_env, timeout_ms = 60000 }
    return text.trim(r.stdout or "")
end

-- gate B: a concurrent writer for the whole fixture
local B = proc.spawn{ argv = { "bash", W .. "/gate-b.sh", LOG, W .. "/rec.sh" }, timeout_ms = 120000 }
local b_live = true
local function stop_b() if b_live then B:kill(); b_live = false end end
local function cleanup()
    stop_b()
    proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 }
end
rec("warmup", "gate-B")

-- gate A, step "clean": writes nothing, while B keeps writing
local before = lines(); pause("0.3")
local v1 = attribute(before)
local grew = lines() - before
if grew > 0 and v1:sub(1, #"ours=0 ") ~= "ours=0 " then bad(1, "premise or verdict wrong: grew=" .. grew .. " [" .. v1 .. "]")
elseif grew > 0 then ok(1)
else bad(1, "premise: gate B did not write during the clean step, so this arm proves nothing") end

-- gate A, step "leaky": writes two records stamped with A's run id
before = lines()
rec("leaky", "gate-A"); pause("0.1"); rec("leaky", "gate-A"); pause("0.1")
local v2 = attribute(before)
if v2:sub(1, #"ours=2 foreign=") == "ours=2 foreign=" then ok(2)
else bad(2, "the leaking step was not named with its 2 records: [" .. v2 .. "]") end

-- The sibling probe is pinned to a pattern that matches nothing, so only the
-- writers in this fixture decide "concurrent" (the host may run real gates).
local PIN = { TILLANDSIAS_GATE_SIBLING_PATTERN = "no-such-gate-process-" .. tostring(time.now_ms()) .. "-x9q" }

-- 3: an id-less record while gate B is live (B writes in the window) only warns
before = lines(); rec("anonymous"); pause("0.1")
local v3 = attribute(before, PIN)
if v3:match("^ours=0 .*unattributed=[1-9].*concurrent=1 verdict=warn$") then ok(3)
else bad(3, "an id-less record beside a live gate did not warn: [" .. v3 .. "]") end

-- 5: stop gate B; an id-less record with nobody else running still refuses
stop_b()
before = lines(); rec("scrubbed-env")
local v5 = attribute(before, PIN)
if v5 == "ours=0 foreign=0 unattributed=1 concurrent=0 verdict=refuse" then ok(5)
else bad(5, "an id-less record with no concurrent gate did not refuse: [" .. v5 .. "]") end

-- 4: build.sh's step loop
local build = fs.read("build.sh")
-- 2238-3skn: the helper reads the step's WINDOW, snapshotted once before
-- attribution (so it is handed 0 lines-before), never the live shared log.
if build:find('scripts/gate-step-metrics-attribution.sh}', 1, true)
    and build:find('bash "$_metrics_attr_bin" "$_metrics_snap" 0 "${TILLANDSIAS_TIMING_RUN_ID:-none}"', 1, true)
    and build:find("verdict=refuse", 1, true) then ok(4)
else bad(4, "build.sh's step loop does not attribute shared-log records by its run id") end

cleanup()
if failn > 0 then verdict.emit("violation:gate-step-metrics-attribution:" .. failn .. "-of-" .. (pass + failn), 1) end
verdict.ok("gate-step-metrics-attribution:" .. pass)
