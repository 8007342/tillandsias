-- @env PATH HOME
-- @trace spec:spec-traceability, order:642-fedr, order:2324-xme7
--
-- test-lww-channel-alias.lua — the `fields:` channel and its `status:` alias fold IDENTICALLY.
-- Ported from the .sh of the same name (2324-xme7). The register is keyed on packet and field
-- and has always corrected any field; only the channel was named `status:`.
--
--   1 APPLIES  a non-status correction changes the fold (else 2 passes on two no-ops)
--   2 ALIAS    the two channels fold to the same thing
--   3 BOTH     a fragment carrying both keeps BOTH halves (the .sh could not read the second)
--   4 ANCHOR   the channel (column 0) and the declaration (4 spaces) stay distinguishable
--   5 ORPHAN   an entry for no packet is named by check, through EITHER channel
--
-- Usage: tillandsias-plan script run scripts/lua/test-lww-channel-alias.lua
-- Verdict: ok:lww-channel-alias:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("lww-channel-alias")
local PLAN = fixture.plan_binary()
if PLAN == "" then T:skip("no-plan-binary") end

local function ledger(fragment)
    local d = T:scratch()
    fs.mkdir(d.rel .. "/plan/index.d")
    fs.write(d.rel .. "/plan/index.yaml", "packets:\n  - packet_id: fixture-642\n    order: 999-f642\n    status: ready\n    pickup_role: any\n"
        .. "    desired_release: v0.5\n    capability_tags:\n      - plan\n")
    if fragment then fs.write(d.rel .. "/plan/index.d/a.yaml", fragment) end
    return d
end
local function plan(d, ...)
    local r = proc.run{ argv = { PLAN, "--index", d.abs .. "/plan/index.yaml", ... }, cwd = d.abs, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    return r.code, (r.stdout or ""), (r.stderr or "")
end
-- The fold's answer for the one packet, as JSON, and the parsed record.
local function fold(fragment)
    local d = ledger(fragment)
    local rc, o = plan(d, "query", "--json", "--limit", "0")
    local ok, v = pcall(json.parse, o)
    return text.trim(o), (rc == 0 and ok and type(v) == "table" and v[1]) or {}, d
end
local function entry(id, field, value)
    return "  - packet_id: " .. id .. "\n    field: " .. field .. "\n    value: " .. value .. '\n    ts: "2026-08-26T00:00:00Z"\n    host: h1\n'
end
local REL = entry("fixture-642", "desired_release", "v0.9")

local before, b = fold(nil)
local via_fields, f = fold("fields:\n" .. REL)
T:arm("1 APPLIES a non-status correction through fields: changes the fold", b.desired_release == "v0.5" and f.desired_release == "v0.9", before .. " -> " .. via_fields)
local via_status = fold("status:\n" .. REL)
T:arm("2 ALIAS fields: and status: fold identically", via_fields == via_status and via_fields ~= before, via_fields .. " vs " .. via_status)
local both, x, d = fold("fields:\n" .. REL .. "status:\n" .. entry("fixture-642", "pickup_role", "windows"))
local rc, _, why = plan(d, "check")
T:arm("3 BOTH halves of a both-channel fragment fold and the ledger stays sound", x.desired_release == "v0.9" and x.pickup_role == "windows" and rc == 0,
    both .. " check=" .. tostring(rc) .. " " .. why:sub(1, 200))
local a, any, channel, decl = "status:\n  - packet_id: p\n    field: status\n    value: ready\npackets:\n  - packet_id: p\n    status: ready\n", 0, 0, 0
for l in a:gmatch("[^\n]+") do
    if text.contains(l, "status:") then any = any + 1 end
    if l:find("^status:") then channel = channel + 1 end
    if l:find("^    status:") then decl = decl + 1 end
end
T:arm("4 ANCHOR column 0 is the channel and four spaces the declaration", any == 2 and channel == 1 and decl == 1, any .. " " .. channel .. " " .. decl)
local named = {}
for _, ch in ipairs{ "fields", "status" } do
    local _, o, e = plan(ledger(ch .. ":\n" .. entry("no-such-packet", "desired_release", "v9.9")), "check")
    named[#named + 1] = text.contains(o .. e, "no-such-packet") and "named" or ch .. ":" .. (o .. e):sub(1, 200)
end
T:arm("5 ORPHAN an entry for no packet is named through either channel", table.concat(named, " ") == "named named", table.concat(named, " "))
T:finish()
