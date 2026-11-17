-- @env PATH
-- @trace order:1957-msjs, order:1941-rlim, spec:default-image
--
-- test-provider-limit-relay.lua — a provider usage limit one host's forge
-- recorded holds the forges of every fleet host (1957-msjs).
--
-- Two simulated hosts share ONE plan dir (the channel; no network, no podman):
-- host A's forge records a limit and A's relay publishes it on exit; host B's
-- launch folds the shared plan offline and its forge refuses, naming A,
-- without calling the provider. The pusher is a stub that records its call or
-- fails on demand.
--
--   publish   A's on-exit writes one event fragment naming A, and pushes it;
--   refuse    B's seed-env names A, and B's forge refuses with recorded_by=A;
--   dedupe    a second exit with the same record publishes nothing new;
--   expired   a lifted deadline seeds nothing and B goes ahead;
--   override  TILLANDSIAS_IGNORE_PROVIDER_LIMIT=1 still goes ahead on B;
--   control   a forge that recorded nothing publishes nothing;
--   deferred  a failed push leaves one deferred line and exits at once;
--             retry with a working pusher clears it;
--   wired     the tray seeds every forge launch and relays on exit (static).
-- Red on the tree before 1957-msjs: the relay does not exist, and the record
-- never leaves host A.
--
-- Usage: tillandsias-plan script run scripts/lua/test-provider-limit-relay.lua
-- Verdict: ok:provider-limit-relay:<n> arms | violation:provider-limit-relay:<n>-failed

local NAME = "provider-limit-relay"
local RELAY = "scripts/provider-limit-relay.sh"
local LIB = "images/default/lib-provider-limit.sh"

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer")
end

local passed, failed = 0, {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name)
    else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

local function readf(p) return fs.exists(p) and (fs.read(p) or "") or "" end
local REL = "target/plan-scratch/provider-limit-relay-" .. tostring(time.now_ms())
local ABS = ROOT .. "/" .. REL
fs.mkdir(REL)
local PATH0 = os.getenv and os.getenv("PATH") or "/usr/bin:/bin"

-- The pusher stub: logs each call; refuses when the FAIL file exists.
fs.write(REL .. "/push.sh", table.concat({
    "#!/usr/bin/env bash",
    'echo "$1" >> "' .. ABS .. '/pushed.log"',
    'if [ -e "' .. ABS .. '/HANG" ]; then sleep 30; fi',
    'if [ -e "' .. ABS .. '/FAIL" ]; then echo "refused:fragments-to-trunk:push:stub"; exit 1; fi',
    'echo "ok:fragments-on-trunk:0000000:1"',
}, "\n") .. "\n")
proc.run({ argv = { "chmod", "+x", ABS .. "/push.sh" } })

local function count(pattern)
    local r = proc.run({ argv = { "ls", ABS .. "/plan" } })
    local n = 0
    for _, l in ipairs(text.lines(r.stdout or "")) do
        if l:find(pattern, 1, true) then n = n + 1 end
    end
    return n
end

-- relay(host, args...) runs the relay as `host`, sharing the plan dir.
local function relay(host, args, extra)
    local argv = { "bash", ROOT .. "/" .. RELAY }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local env = {
        PATH = PATH0, HOME = ABS .. "/" .. host,
        TILLANDSIAS_PROVIDER_LIMIT_PLAN_DIR = ABS .. "/plan",
        TILLANDSIAS_PROVIDER_LIMIT_PUSH = ABS .. "/push.sh",
        TILLANDSIAS_PROVIDER_LIMIT_STATE = ABS .. "/" .. host .. "/state",
        TILLANDSIAS_PROVIDER_LIMIT_PUSH_TIMEOUT_S = "10",
    }
    for k, v in pairs(extra or {}) do env[k] = v end
    return proc.run({ argv = argv, env = env, timeout_ms = 30000 })
end

-- The forge's launch-time check, as the entrypoint runs it.
fs.write(REL .. "/forge-check.sh", table.concat({
    ". " .. ROOT .. "/" .. LIB,
    'if provider_limit_refuse "$1"; then echo REFUSED; else echo WENT; fi',
}, "\n") .. "\n")

-- forge(host, shared, extra, provider) runs host's forge check with the seeded value.
local function forge(host, shared, extra, provider)
    local env = {
        PATH = PATH0, HOME = ABS .. "/" .. host,
        TILLANDSIAS_PROVIDER_LIMIT_DIR = ABS .. "/" .. host .. "/forge-limits",
        TILLANDSIAS_PROVIDER_LIMIT_SHARED = shared,
    }
    for k, v in pairs(extra or {}) do env[k] = v end
    return proc.run({ argv = { "bash", ABS .. "/forge-check.sh", provider or "opencode" },
        env = env, timeout_ms = 30000 })
end

local now = tonumber(text.trim(proc.run({ argv = { "date", "-u", "+%s" } }).stdout or "0"))
local function record(host, until_epoch)
    fs.mkdir(REL .. "/" .. host .. "/cache/provider-limits")
    fs.write(REL .. "/" .. host .. "/cache/provider-limits/opencode",
        tostring(until_epoch) .. " 2026-11-03T03:00:00Z 2026-11-02T03:00:00Z\n")
end

-- publish
record("hostA", now + 3600)
local r = relay("hostA", { "on-exit", "--record-dir", ABS .. "/hostA/cache/provider-limits", "--host", "hostA" })
local o = text.trim(r.stdout or "")
arm("publish: host A's exit publishes the limit", o:find("ok:provider-limit-relay:published:opencode:", 1, true) ~= nil, o)
arm("publish: one event fragment naming host A", count("provider-limit-opencode-hostA") == 1, count("provider-limit-opencode-hostA"))
local pushed = readf(REL .. "/pushed.log")
arm("publish: the fragment was handed to the plan-lane pusher", pushed:find("provider-limit-opencode-hostA", 1, true) ~= nil, pushed)

-- refuse on host B
r = relay("hostB", { "seed-env" })
local shared = text.trim(r.stdout or "")
arm("refuse: host B's offline fold names host A", shared:find("^opencode " .. (now + 3600) .. " 2026%-11%-03T03:00:00Z hostA$") ~= nil, shared)
r = forge("hostB", shared)
o = r.stdout or ""
arm("refuse: host B's forge refuses without calling the provider", o:find("REFUSED", 1, true) ~= nil and o:find("WENT", 1, true) == nil, o)
arm("refuse: with the same verdict line, naming host A",
    o:find("blocked:provider-usage-limit:provider=opencode:retry_after=2026-11-03T03:00:00Z:recorded_by=hostA", 1, true) ~= nil, o)

-- dedupe
r = relay("hostA", { "on-exit", "--record-dir", ABS .. "/hostA/cache/provider-limits", "--host", "hostA" })
arm("dedupe: a second exit with the same record publishes nothing new",
    (r.stdout or ""):find("already-published", 1, true) ~= nil and count("provider-limit-opencode") == 1, r.stdout)

-- override
r = forge("hostB", shared, { TILLANDSIAS_IGNORE_PROVIDER_LIMIT = "1" })
arm("override: TILLANDSIAS_IGNORE_PROVIDER_LIMIT=1 still goes ahead", (r.stdout or ""):find("WENT", 1, true) ~= nil, r.stdout)

-- expired: a past deadline in the plan seeds nothing and B goes ahead
fs.write(REL .. "/plan/20261101t000000z-provider-limit-claude-hostC.yaml", table.concat({
    "events:", "  - packet_id: x", "    event:", "      type: note",
    "      summary: |-",
    "        provider-usage-limit provider=claude retry_after=2026-11-01T00:00:00Z retry_after_epoch=" .. (now - 5)
        .. " recorded_by=hostC recorded=2026-10-31T00:00:00Z",
}, "\n") .. "\n")
r = relay("hostB", { "seed-env" })
local s2 = text.trim(r.stdout or "")
arm("expired: a lifted deadline is not seeded", s2:find("claude", 1, true) == nil and s2:find("hostA", 1, true) ~= nil, s2)
r = forge("hostB", "claude " .. (now - 5) .. " 2026-11-01T00:00:00Z hostC", nil, "claude")
arm("expired: an expired shared entry holds nothing", (r.stdout or ""):find("WENT", 1, true) ~= nil, r.stdout)

-- control
fs.mkdir(REL .. "/hostD/cache/provider-limits")
r = relay("hostD", { "on-exit", "--record-dir", ABS .. "/hostD/cache/provider-limits", "--host", "hostD" })
arm("control: a forge that recorded nothing publishes nothing",
    text.trim(r.stdout or "") == "ok:provider-limit-relay:nothing-recorded" and count("hostD") == 0, r.stdout)

-- deferred, then retry
fs.write(REL .. "/FAIL", "x\n")
record("hostE", now + 7200)
local t0 = time.now_ms()
r = relay("hostE", { "on-exit", "--record-dir", ABS .. "/hostE/cache/provider-limits", "--host", "hostE" })
local took = time.now_ms() - t0
o = text.trim(r.stdout or "")
local deferred = readf(REL .. "/hostE/state/provider-limit-deferred")
arm("deferred: a failed push leaves one deferred line and exits 0",
    r.code == 0 and o:find("ok:provider-limit-relay:deferred:opencode:", 1, true) ~= nil
        and select(2, deferred:gsub("\n", "")) == 1, o .. " / " .. deferred)
arm("deferred: and does not hang on the failure", took < 10000, took)
proc.run({ argv = { "rm", "-f", ABS .. "/FAIL" } })
r = relay("hostE", { "retry" })
arm("deferred: retry with a working pusher clears it",
    text.trim(r.stdout or "") == "ok:provider-limit-relay:retried:1/1"
        and (readf(REL .. "/hostE/state/provider-limit-deferred")) == "", r.stdout)

-- bounded: a pusher that hangs is killed at the deadline (no GNU timeout
-- needed, so macOS hosts are bounded too) and the record is deferred.
fs.write(REL .. "/HANG", "x\n")
record("hostF", now + 7300)
t0 = time.now_ms()
r = relay("hostF", { "on-exit", "--record-dir", ABS .. "/hostF/cache/provider-limits", "--host", "hostF" },
    { TILLANDSIAS_PROVIDER_LIMIT_PUSH_TIMEOUT_S = "2" })
took = time.now_ms() - t0
proc.run({ argv = { "rm", "-f", ABS .. "/HANG" } })
arm("bounded: a hung push is cut off at its deadline and deferred",
    took < 8000 and (r.stdout or ""):find("ok:provider-limit-relay:deferred:opencode:", 1, true) ~= nil,
    tostring(took) .. "ms " .. tostring(r.stdout))

-- wired (static): the tray seeds every launch and relays on exit.

local relay_rs = readf("crates/tillandsias-headless/src/provider_limit_relay.rs")
local main_rs = readf("crates/tillandsias-headless/src/main.rs")
local _, seeded = main_rs:gsub("provider_limit_relay::launch_env%(", "")
local _, relayed = main_rs:gsub("provider_limit_relay::relay_on_exit%(", "")
arm("wired: the tray module calls the relay's seed-env and on-exit",
    relay_rs:find('"seed-env"', 1, true) ~= nil and relay_rs:find('"on-exit"', 1, true) ~= nil, #relay_rs)
arm("wired: forge launches are seeded and forge exits relayed", seeded >= 2 and relayed >= 2,
    "seeded=" .. seeded .. " relayed=" .. relayed)
local fm = readf("scripts/check-fleet-membership.sh")
arm("wired: the slot run retries deferred pushes", fm:find("provider-limit-relay.sh retry", 1, true) ~= nil, "")

proc.run({ argv = { "rm", "-rf", ABS } })
if #failed > 0 then
    verdict.emit("violation:" .. NAME .. ":" .. #failed .. "-failed", 1)
end
verdict.emit("ok:" .. NAME .. ":" .. passed .. " arms", 0)
