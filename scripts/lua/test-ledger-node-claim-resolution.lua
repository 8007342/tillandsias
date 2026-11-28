-- @trace spec:meta-orchestration, plan 790-u8x6, order:2386-lrg1
-- @env PATH HOME
--
-- test-ledger-node-claim-resolution.lua — hermetic fixtures for the claim probe's ID RESOLUTION
-- half (order 790-u8x6): does the id name a real packet at all? Ported from
-- test-ledger-node-claim-resolution.sh (2386-lrg1); same eleven arms (the .sh printed eleven
-- ok lines under a verdict that said 10).
--
-- `claim` once answered `claimed:<id>` for any string: a cycle held two phantom leases while
-- the real packets stayed claimable (2026-08-17). Every case runs the REAL
-- scripts/claim-ledger-node.sh against a FIXTURE ledger (TILLANDSIAS_LEDGER_CLAIM_INDEX).
--
--    1  NEGATIVE CONTROL a real packet_id still claims
--    2  a real order token claims
--    3  a slashed real packet_id claims
--    4  MUTATION a near-miss id is refused as unknown (rc=2)
--    4b a refused claim leaves no lease behind
--    5  release stays permissive for an unresolvable id
--    6  status stays permissive for an unresolvable id
--    7  an unverifiable ledger degrades LOUDLY and still leases
--    8  every verdict line matches the grammar (5/5)
--    9  an orphaned lease dir past its TTL is reclaimed (1553-kvmf, BSD stat)
--   10  CONTROL a fresh holderless lease dir is still live
--
-- ENV. The probe reads TILLANDSIAS_LEDGER_LEASE_{ROOT,TTL_SECS,ID} and _CLAIM_INDEX; all
-- TILLANDSIAS_* are dropped and only the fixture's own are passed, plus TILLANDSIAS_PLAN_BIN
-- (this checkout's plan binary, absolute), so an ambient TTL or lease id cannot leak in.
--
-- GRAMMAR ok:ledger-node-claim-resolution:<n> arms | violation:ledger-node-claim-resolution:<n>-failed
--       | refused:ledger-node-claim-resolution:<reason>

local fixture = require "common.fixture"
local T = fixture.new("ledger-node-claim-resolution")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local CLAIM = ROOT .. "/scripts/claim-ledger-node.sh"
if not fs.exists("scripts/claim-ledger-node.sh") then T:refuse("subject-missing", CLAIM) end
local PLAN = fixture.plan_binary()
if PLAN ~= "" and not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end

local W = T:scratch()
fs.mkdir(W.rel .. "/fixture/plan")
fs.write(W.rel .. "/fixture/plan/index.yaml", [[
plan_index:
  packets:
    - packet_id: fixture-real-node
      order: 900-aaaa
      status: ready
      title: A real fixture packet
    - packet_id: fixture-parent/fixture-child
      order: 900-bbbb
      status: ready
      title: A real fixture packet with a slashed id
]])
local INDEX = W.abs .. "/fixture/plan/index.yaml"

local function claim(root, index, extra, ...)
    local e = { TILLANDSIAS_LEDGER_LEASE_ROOT = root, TILLANDSIAS_LEDGER_CLAIM_INDEX = index }
    if PLAN ~= "" then e.TILLANDSIAS_PLAN_BIN = PLAN end
    for k, v in pairs(extra or {}) do e[k] = v end
    local spec = { SH, CLAIM, ... }
    spec.cwd, spec.env, spec.env_unset, spec.timeout_ms = ROOT, e, { "TILLANDSIAS_*" }, 30000
    local r = T:run(spec)
    return text.trim(r.stdout or ""), r.code, r.stderr or ""
end
local function run_claim(root, ...) return claim(root, INDEX, nil, ...) end
local function L(n) return W.abs .. "/l" .. n end
local function got(o, rc) return "out=" .. o .. " rc=" .. tostring(rc) end

local o, rc = run_claim(L(1), "claim", "fixture-real-node")
T:arm("1 NEGATIVE CONTROL a real packet_id still claims (rc=0)", o == "claimed:fixture-real-node" and rc == 0, got(o, rc))

o, rc = run_claim(L(2), "claim", "900-aaaa")
T:arm("2 a real order token claims (rc=0)", o == "claimed:900-aaaa" and rc == 0, got(o, rc))

o, rc = run_claim(L(3), "claim", "fixture-parent/fixture-child")
T:arm("3 a slashed real packet_id claims (rc=0)", o == "claimed:fixture-parent/fixture-child" and rc == 0, got(o, rc))

o, rc = run_claim(L(4), "claim", "fixture-reel-node")
T:arm("4 MUTATION a near-miss id is refused as unknown (rc=2)", o == "unknown:fixture-reel-node" and rc == 2, got(o, rc))
local ls = text.trim(T:run{ "ls", "-A", L(4) }.stdout or "")
T:arm("4b a refused claim leaves no lease behind", ls == "", ls)

T:must{ "mkdir", "-p", L(5) }
o, rc = run_claim(L(5), "release", "fixture-obsoleted-node")
T:arm("5 release stays permissive for an unresolvable id (rc=0)", o == "released:fixture-obsoleted-node" and rc == 0, got(o, rc))

o, rc = run_claim(L(6), "status", "fixture-obsoleted-node")
T:arm("6 status stays permissive for an unresolvable id", o == "free:fixture-obsoleted-node" and rc == 1, got(o, rc))

local err
o, rc, err = claim(L(7), W.abs .. "/nonexistent/plan/index.yaml", nil, "claim", "some-node")
T:arm("7 an unverifiable ledger degrades LOUDLY and still leases (rc=0)",
    o == "claimed:some-node" and rc == 0 and text.contains(err, "could not verify"), got(o, rc) .. " err=" .. err)

local all = {}
for _, a in ipairs{ { "claim", "fixture-real-node" }, { "claim", "fixture-real-node" }, { "claim", "fixture-nope" },
    { "status", "fixture-real-node" }, { "release", "fixture-real-node" } } do
    local x = run_claim(L(8), a[1], a[2])
    for _, l in ipairs(text.lines(x)) do if l ~= "" then all[#all + 1] = l end end
end
local good = 0
for _, l in ipairs(all) do
    if text.is_match(l, "^(claimed|reclaimed|in-flight|released|free|unknown):[a-z0-9._/-]+$") then good = good + 1 end
end
T:arm("8 every verdict line matches the grammar (5/5)", #all == 5 and good == 5, good .. "/" .. #all .. " well-formed")

-- 9: aged with touch -t, the aging CHECKED with find -mmin before the verdict counts.
local lease9 = L(9) .. "/fixture-real-node.lease"
T:must{ "mkdir", "-p", lease9 }
T:must{ "touch", "-t", "202001010000", lease9 }
local aged = text.trim(T:run{ "find", lease9, "-maxdepth", "0", "-mmin", "+60" }.stdout or "")
if aged == "" then
    T:arm("9 an orphaned lease dir past its TTL is reclaimed (rc=0)", false, "orphan setup: the lease dir was not aged")
else
    o, rc = claim(L(9), INDEX, { TILLANDSIAS_LEDGER_LEASE_TTL_SECS = "60" }, "claim", "fixture-real-node")
    T:arm("9 an orphaned lease dir past its TTL is reclaimed (rc=0)", o == "reclaimed:fixture-real-node" and rc == 0,
        got(o, rc) .. " (pre-1553-kvmf darwin: in-flight forever)")
end

T:must{ "mkdir", "-p", L(10) .. "/fixture-real-node.lease" }
o, rc = claim(L(10), INDEX, { TILLANDSIAS_LEDGER_LEASE_TTL_SECS = "3600" }, "claim", "fixture-real-node")
T:arm("10 CONTROL a fresh holderless lease dir is still live (the write window holds)",
    o == "in-flight:fixture-real-node" and rc == 1, got(o, rc))

T:finish()
