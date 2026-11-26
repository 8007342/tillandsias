-- @trace spec:methodology-accountability, order:832-q4mn, order:2400-prg4
--
-- test-plan-orders-fragment-fold.lua — `tillandsias-policy plan-orders` must check the FOLDED
-- ledger (plan/index.yaml + plan/index.d/), not the base alone (832-q4mn). Ported from
-- test-plan-orders-fragment-fold.sh (2400-prg4); same six cases, in its order.
--
-- New order tokens arrive as FRAGMENTS (582-nqw5), so a gate that read only the base could not
-- see a collision until someone compacted.
--
--   1  a fragment re-using a base order is caught            (THE DEFECT)
--   2  CONTROL: a fresh-order fragment passes and is counted
--   3  two fragments colliding with each other are caught    (the multi-host shape)
--   4  the status LWW channel is applied before the open-member test (grandfathers)
--   5  NEGATIVE CONTROL for 4: without the override the same tree violates
--   6  a quoted and an unquoted spelling of one order collide (1283-tpd5)
--
-- Hermetic: tiny synthetic ledgers in kit scratch, checked with --index; never the live plan/.
--
-- GRAMMAR ok:plan-orders-fragment-fold:<n> arms | violation:plan-orders-fragment-fold:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("plan-orders-fragment-fold")
local ROOT = fixture.repo_root()
local W = T:scratch()

local BASE = table.concat({ "plan_index:", "  steps:",
    "    - packet_id: alpha", "      order: 700-aaaa", "      status: ready",
    "    - packet_id: beta", "      order: 701-bbbb", "      status: ready", "" }, "\n")

local function tree(leaf, base, frags)
    local d = W.rel .. "/" .. leaf
    fs.mkdir(d .. "/plan/index.d")
    fs.write(d .. "/plan/index.yaml", base or BASE)
    for name, body in pairs(frags or {}) do fs.write(d .. "/plan/index.d/" .. name, body) end
    return d, W.abs .. "/" .. leaf
end
local function frag(pkt, order)
    return table.concat({ "packets:", "  - packet_id: " .. pkt, "    order: " .. order, "    status: ready", "" }, "\n")
end
-- cargo prints its own noise on stderr; the verdict tokens are looked for in both.
local function run_orders(abs)
    local r = T:run{ "cargo", "run", "-q", "--manifest-path", ROOT .. "/Cargo.toml", "-p", "tillandsias-policy",
        "--", "plan-orders", "--index", "plan/index.yaml", cwd = abs, timeout_ms = 900000 }
    return (r.stdout or "") .. (r.stderr or "")
end

local _, a1 = tree("c1", nil, { ["collide.yaml"] = frag("gamma", "700-aaaa") })
local o = run_orders(a1)
T:arm("case 1: a fragment colliding with a base order is caught", text.contains(o, "duplicate-order:700-aaaa"), o)

local _, a2 = tree("c2", nil, { ["fresh.yaml"] = frag("gamma", "702-cccc") })
o = run_orders(a2)
T:arm("case 2: a non-colliding fragment passes and is counted",
    text.contains(o, "ok: plan orders unique") and text.contains(o, "1 from fragments"), o)

local _, a3 = tree("c3", nil, { ["host-a.yaml"] = frag("from-host-a", "800-dupe"), ["host-b.yaml"] = frag("from-host-b", "800-dupe") })
o = run_orders(a3)
T:arm("case 3: two fragments colliding with each other are caught", text.contains(o, "duplicate-order:800-dupe"), o)

local BASE4 = table.concat({ "plan_index:", "  steps:",
    "    - packet_id: alpha", "      order: 700-aaaa", "      status: completed",
    "    - packet_id: alpha-old", "      order: 700-aaaa", "      status: ready", "" }, "\n")
local _, a4 = tree("c4", BASE4, { ["close-old.yaml"] = table.concat({ "status:",
    "  - packet_id: alpha-old", "    field: status", "    value: completed", '    ts: "2026-08-19T10:00:00Z"', "" }, "\n") })
o = run_orders(a4)
T:arm("case 4: the status LWW channel is applied before the open-member test",
    text.contains(o, "ok: plan orders unique") and text.contains(o, "1 grandfathered"), o)

-- The same tree without the override (a fresh copy: the kit has no file removal).
local _, a5 = tree("c5", BASE4, {})
o = run_orders(a5)
T:arm("case 5: removing the override restores the violation", text.contains(o, "duplicate-order:700-aaaa"), o)

local _, a6 = tree("c6", nil, { ["quoted.yaml"] = frag("gamma", '"700-aaaa"') })
o = run_orders(a6)
T:arm("case 6: a quoted and an unquoted spelling of one order collide", text.contains(o, "duplicate-order:700-aaaa"), o)

T:finish()
