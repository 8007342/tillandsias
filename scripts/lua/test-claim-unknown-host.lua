-- @trace order:1588-27v3
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN TILLANDSIAS_PLAN_PREFIX_BIN
--
-- test-claim-unknown-host.lua — a claim names a fleet host.
--
-- WHY THIS EXISTS. The WIP cap (1367-2sbc) counts claims per host STRING.
-- Measured on tlatoanis-macbook-air 2026-10-11: the real host was refused at
-- wip 16/3, and the same claim with `--host x` WROTE a fragment, because "x"
-- holds nothing. set-field now refuses a claim whose host is not in
-- methodology/distributed-work.yaml packet_discipline.fleet_hosts.
--
-- Arms:
--   1 UNKNOWN       `--host x` is refused with refused:set-field:unknown-host:x
--                   and writes no fragment
--   2 KNOWN         a listed host claims and writes one fragment
--   3 CAP           a listed host at the cap is still refused by the ordinary cap
--   4 NO LIST       methodology present without fleet_hosts: refused, no fragment
--   5 SCRATCH       no methodology beside the ledger: the claim is not checked
--   6 NOT A CLAIM   `status ready --host x` is not a claim and is not refused
--   7 REAL LIST     the checkout's fleet_hosts parses, names this fleet's hosts,
--                   and names no shared label (platform, host kind, forge container)
--   8 PRE-FIX       when TILLANDSIAS_PLAN_PREFIX_BIN names a pre-fix binary, it
--                   WRITES the `--host x` fragment ARM 1 refuses (the row's third
--                   exit criterion); skipped and said so when unset
--
-- Hermetic: scratch ledgers under target/plan-scratch driven through --index.
--
-- Usage: TILLANDSIAS_PLAN_BIN=<bin> tillandsias-plan script run scripts/lua/test-claim-unknown-host.lua

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 120000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
local PLAN = env.get("TILLANDSIAS_PLAN_BIN") or env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or ""
local PREFIX = env.get("TILLANDSIAS_PLAN_PREFIX_BIN") or ""
if ROOT == "" or PLAN == "" then
    verdict.could_not_run("claim-unknown-host-fixture", "needs a checkout and TILLANDSIAS_PLAN_BIN")
end

local W_REL = "target/plan-scratch/claim-unknown-host-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. W_REL

local ROWS = { "1-aaaa", "2-bbbb", "3-cccc" }
-- mk(name, methodology): a scratch ledger of three ready rows; methodology is
-- the distributed-work.yaml body, or nil for none.
local function mk(name, methodology)
    local d = W_REL .. "/" .. name
    fs.mkdir(d .. "/plan/index.d")
    if methodology then
        fs.mkdir(d .. "/methodology")
        fs.write(d .. "/methodology/distributed-work.yaml", methodology)
    end
    local body = { "packets:" }
    for i, o in ipairs(ROWS) do
        body[#body + 1] = ("  - packet_id: fixture-row-%d\n    order: %s\n    status: ready\n    kind: bug\n    priority: p2\n    desired_release: v0.5\n    pickup_role: linux\n    title: fixture row %d\n    unscoreable: \"fixture packet; not scored\"\n    events: []"):format(i, o, i)
    end
    fs.write(d .. "/plan/index.yaml", table.concat(body, "\n") .. "\n")
    return ROOT .. "/" .. d
end
local LISTED = "distributed_work:\n  packet_discipline:\n    wip_limit: 1\n    fleet_hosts: [hosta, hostb]\n"
local UNLISTED = "distributed_work:\n  packet_discipline:\n    wip_limit: 1\n"

local function frags(d)
    local n = 0
    for _, p in ipairs(fs.walk(d .. "/plan/index.d")) do
        if p:match("%.yaml$") then n = n + 1 end
    end
    return n
end
local function set_field(bin, d, args)
    local argv = { bin, "--index", d .. "/plan/index.yaml", "set-field" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = run(argv, { env = { TILLANDSIAS_HOST_KIND = "", TILLANDSIAS_AGENT_ID = "linux-fixture-fixture-20200101t000000z" } })
    return (r.status == "exited" and r.code or -1), (r.stdout or "") .. (r.stderr or "")
end
local function claim(bin, d, order, host)
    return set_field(bin, d, { order, "status", "in_progress", "--host", host, "--reason", "fixture" })
end
local function has(s, sub) return s:find(sub, 1, true) ~= nil end
local function first(s) return (s:match("[^\n]*") or ""):sub(1, 160) end

local passed, failed = {}, {}
local function check(name, cond, detail)
    if cond then passed[#passed + 1] = name; out.line("  [OK]   " .. name)
    else failed[#failed + 1] = name; out.line("  [FAIL] " .. name .. (detail and (" — " .. detail) or "")) end
end

-- ── ARM 1: UNKNOWN ───────────────────────────────────────────────────────
local d1 = mk("unknown", LISTED)
local rc, o = claim(PLAN, d1, "1-aaaa", "x")
check("ARM 1: --host x is refused by name and writes no fragment",
    rc == 2 and has(o, "refused:set-field:unknown-host:x") and has(o, "hosta, hostb") and frags(d1) == 0,
    ("rc=%s frags=%d out=%s"):format(rc, frags(d1), first(o)))

-- ── ARM 2: KNOWN ─────────────────────────────────────────────────────────
rc, o = claim(PLAN, d1, "1-aaaa", "hosta")
check("ARM 2: a listed host claims and writes one fragment",
    rc == 0 and frags(d1) == 1, ("rc=%s frags=%d out=%s"):format(rc, frags(d1), first(o)))

-- ── ARM 3: CAP ───────────────────────────────────────────────────────────
rc, o = claim(PLAN, d1, "2-bbbb", "hosta")
check("ARM 3: a listed host at the cap is still refused by the ordinary cap",
    rc == 2 and has(o, "refused:set-field:wip-limit:1/1") and frags(d1) == 1,
    ("rc=%s frags=%d out=%s"):format(rc, frags(d1), first(o)))

-- ── ARM 4: NO LIST ───────────────────────────────────────────────────────
local d4 = mk("no-list", UNLISTED)
rc, o = claim(PLAN, d4, "1-aaaa", "hosta")
check("ARM 4: methodology without fleet_hosts refuses the claim and writes nothing",
    rc == 2 and has(o, "refused:set-field:no-fleet-host-list") and frags(d4) == 0,
    ("rc=%s frags=%d out=%s"):format(rc, frags(d4), first(o)))

-- ── ARM 5: SCRATCH ───────────────────────────────────────────────────────
local d5 = mk("scratch", nil)
rc, o = claim(PLAN, d5, "1-aaaa", "x")
check("ARM 5: a ledger with no methodology beside it is not checked",
    rc == 0 and frags(d5) == 1, ("rc=%s frags=%d out=%s"):format(rc, frags(d5), first(o)))

-- ── ARM 6: NOT A CLAIM ───────────────────────────────────────────────────
rc, o = set_field(PLAN, d1, { "3-cccc", "status", "blocked", "--host", "x", "--reason", "fixture" })
check("ARM 6: a non-claim status write by an unlisted host is not refused",
    rc == 0 and not has(o, "refused:set-field:unknown-host"), ("rc=%s out=%s"):format(rc, first(o)))

-- ── ARM 7: REAL LIST ─────────────────────────────────────────────────────
local real = fs.read("methodology/distributed-work.yaml") or ""
local block = real:match("\n    fleet_hosts:\n(.-)\n    [%a_]+:") or ""
local hosts = {}
for h in block:gmatch("\n?%s*%- ([%w_%-]+)") do hosts[h] = true end
local shared = {}
for _, s in ipairs({ "linux", "macos", "windows", "forge", "forge-tillandsias", "linux_mutable", "linux_immutable", "linux-mutable", "linux-immutable", "x" }) do
    if hosts[s] then shared[#shared + 1] = s end
end
check("ARM 7: the checkout's fleet_hosts names the fleet's hosts and no shared label",
    hosts["macuahuitl"] and hosts["yoga"] and hosts["tlatoanis-macbook-air"] and #shared == 0,
    "shared=" .. table.concat(shared, ","))

-- ── ARM 8: PRE-FIX ───────────────────────────────────────────────────────
if PREFIX ~= "" then
    local d8 = mk("prefix", LISTED)
    rc, o = claim(PREFIX, d8, "1-aaaa", "x")
    check("ARM 8: the pre-fix binary WRITES the --host x claim fragment ARM 1 refuses",
        rc == 0 and frags(d8) == 1, ("rc=%s frags=%d out=%s"):format(rc, frags(d8), first(o)))
else
    out.line("  [SKIP] ARM 8: TILLANDSIAS_PLAN_PREFIX_BIN unset; no pre-fix binary to show")
end

run({ "rm", "-rf", W })
local total = #passed + #failed
if #failed > 0 then
    verdict.emit(("violation:claim-unknown-host-fixture:%d/%d"):format(#passed, total), 1, table.concat(failed, "; "))
end
verdict.emit(("ok:claim-unknown-host-fixture:%d/%d"):format(#passed, total), 0)
