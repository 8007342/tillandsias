-- @trace order:1198-7q95, order:2375-ch7i
--
-- test-expire-claims-reads-the-status-write.lua — the expiry sweep ages and attributes a
-- claim from the STATUS WRITE that set in_progress, not the row's newest event. On
-- 2026-09-15 it reported a 35-minute-old claim as a two-week-old one of another host's.
-- Scratch ledgers, a fixed --now-epoch. Ported from the .sh (2375-ch7i).
--
-- Verdict: ok:expire-claims-reads-the-status-write:<n> | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("expire-claims-reads-the-status-write")
local PLAN = fixture.plan_binary()
if PLAN == "" then T:skip("no-validator") end
local NOW, OLD, RECENT = "1800000000", "2026-09-01T23:04:53Z", "2027-01-15T07:36:36Z" -- 24 minutes before NOW
local function row(id, order, kind, host, why)
    return ([[
  - packet_id: %s
    order: %s
    status: in_progress
    kind: bug
    priority: p2
    desired_release: v0.5
    pickup_role: linux
    title: fixture row
    unscoreable: "fixture packet; not scored"
    events:
      - type: %s
        ts: "%s"
        agent_id: "linux-%s-claude-20260901t225307z"
        host: %s
        summary: |-
          %s
]]):format(id, order, kind, OLD, host, host, why)
end
local function ledger(tag)
    local d = T:scratch(tag)
    fs.mkdir(d.rel .. "/plan/index.d")
    fs.write(d.rel .. "/plan/index.yaml", "packets:\n" .. row("leased-fresh", "1-aaaa", "progress", "hosta", "an unrelated note from a host that never claimed this row")
        .. row("leased-stale", "2-bbbb", "progress", "hosta", "an old note beside an old claim")
        .. row("unleased-old", "3-cccc", "claim", "hostc", "claimed for cycle 2026-09-01 by hostc"))
    return d
end
local function lease(d, stem, id, ts, host)
    fs.write(d.rel .. "/plan/index.d/" .. stem .. ".yaml", ('status:\n  - packet_id: %s\n    field: status\n    value: in_progress\n    ts: "%s"\n    host: %s\n'):format(id, ts, host))
end
local function sweep(d)
    local o = T:run{ PLAN, "--index", d.abs .. "/plan/index.yaml", "expire-claims", "--now-epoch", NOW, env_unset = { "TILLANDSIAS_*" } }.stdout or ""
    local by = {}
    for _, l in ipairs(text.lines(o)) do for _, id in ipairs{ "leased-fresh", "leased-stale", "unleased-old" } do if l:find(id, 1, true) then by[id] = l end end end
    return o, by
end
local d = ledger("a")
lease(d, "20270115t073636z-fresh", "leased-fresh", RECENT, "hostb")
lease(d, "20260901t230453z-stale", "leased-stale", OLD, "hostb")
local o, by = sweep(d)
T:arm("1 a recent status write beside an ancient event is no candidate", o:find("unknown_age=", 1, true) and not by["leased-fresh"], o)
T:arm("2 an old claim is listed, attributed to the host that wrote the status", (by["leased-stale"] or ""):find("claimant:hostb", 1, true), o)
-- Deliberate (672-bz7u): with no status write the event channel is the only evidence.
T:arm("3 with no status write the event fallback still attributes the row", (by["unleased-old"] or ""):find("claimant:hostc", 1, true), o)
d = ledger("b")
lease(d, "20270115t073636z-plat", "leased-fresh", RECENT, "linux")
o, by = sweep(d)
T:arm("4 a fresh claim whose host matches no event is neither expired nor unknown-age", not by["leased-fresh"] and o:find("unknown_age=0", 1, true), o)
local SRC = "crates/tillandsias-plan/src/main.rs"
if not fs.exists(SRC) then out.line("skip: arm 5 — crate source not present")
else T:arm("5 traceability: the crate cites 1198-7q95", fs.read(SRC):find("ORDER 1198-7q95", 1, true), SRC) end
T:finish({ ok = function(n) return "ok:expire-claims-reads-the-status-write:" .. n end })
