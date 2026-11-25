-- @trace order:905-wjfj, order:2375-ch7i
--
-- test-expire-claims-list-live-rows.lua — `expire-claims --list-live` NAMES every
-- in_progress packet it counts. The count covered every packet and the rows only those
-- with a claim event, so a fresh unclaimed packet was counted and never named (measured on
-- two hosts, 2026-08-26). Arm 3 is the regression arm. Ported from the .sh (2375-ch7i).
--
-- Verdict: ok:expire-claims-list-live-rows:<n> | violation:expire-claims-list-live-rows:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("expire-claims-list-live-rows")
local PLAN = fixture.plan_binary()
if PLAN == "" then T:skip("no-validator") end
local W = T:scratch()
fs.mkdir(W.rel .. "/plan/index.d")
local NOW, FRESH, STALE = "1787745600", "2026-08-26T11:00:00Z", "2026-08-20T00:00:00Z" -- NOW is 2026-08-26T12:00:00Z
local HEAD = '    - packet_id: %s\n      order: %d\n      title: "t"\n      status: %s\n      kind: fix\n      depends_on: []\n'
local EVENT = '      events:\n        - type: %s\n          ts: "%s"\n          host: %s\n          summary: |\n            %s\n'
local function claimed(id, n, ts, host) return HEAD:format(id, n, "in_progress") .. EVENT:format("note", ts, host, "claimed for cycle " .. ts) end
local function unclaimed(id, n, ts) return HEAD:format(id, n, "in_progress") .. EVENT:format("progress", ts, "somebody", "work happened, nobody claimed the row") end
local function done(id, n) return HEAD:format(id, n, "completed") end
local function sweep(...)
    fs.write(W.rel .. "/plan/index.yaml", "plan_index:\n  version: v1\n  root: plan/\n  steps:\n" .. table.concat({ ... }))
    local r = T:run{ PLAN, "--index", W.abs .. "/plan/index.yaml", "expire-claims", "--dry-run", "--list-live", "--now-epoch", NOW, env_unset = { "TILLANDSIAS_*" } }
    local o = "\n" .. (r.stdout or "") .. (r.stderr or "") .. "\n"
    local n = { live = 0, unc = 0 }
    for _, l in ipairs(text.lines(o)) do
        if l:find("^live%-claim\t") then n.live = n.live + 1 elseif l:find("^unclaimed%-in%-progress\t") then n.unc = n.unc + 1 end
        n.inprog = n.inprog or tonumber(l:match("^summary: .*in_progress=(%d+)"))
        n.total = n.total or tonumber(l:match("^rows: .*total=(%d+)"))
    end
    return o, n
end
local o, n = sweep(done("only-finished", 1))
T:arm("1 NEGATIVE zero in progress: no rows, and rows total=0 says so", n.live == 0 and n.unc == 0 and n.total == 0, o)
o, n = sweep(claimed("held-by-a-host", 2, FRESH, "hosta"))
T:arm("2 a claimed packet yields one live-claim row naming its host", n.live == 1 and o:find("hosta", 1, true), o)
o, n = sweep(unclaimed("nobody-claimed-me", 3, FRESH))
T:arm("3 a fresh unclaimed packet is NAMED, not only counted", n.unc == 1 and n.total == 1 and n.inprog == 1, o)
T:arm("3 the unclaimed row keeps the live-claim field positions", o:find("\nunclaimed-in-progress\t3\tnobody-claimed-me\t-\t-\t", 1, true), o)
o, n = sweep(claimed("mixed-claimed", 10, FRESH, "hostb"), unclaimed("mixed-unclaimed", 11, FRESH), claimed("mixed-expired", 12, STALE, "hostc"), done("mixed-done", 13))
T:arm("4 rows total equals summary in_progress across every bucket", n.inprog and n.total == n.inprog, o)
T:arm("4 the rows line is present and reports no partition mismatch", n.total and not o:find("\nattention:list-live-partition-mismatch", 1, true), o)
T:arm("4 NEGATIVE the stale claim is still an expire-candidate", o:find("\nexpire-candidate\t12\tmixed-expired", 1, true), o)
local sum = o:match("\n(summary: [^\n]*)") or ""
local mode = sum:match("^summary: in_progress=%d+ expired=%d+ held=%d+ unknown_age=%d+ ttl_hours=%d+ mode=([%a-]+)$")
T:arm("5 NEGATIVE the summary grammar did not move", mode == "dry-run" or mode == "write", sum)
T:arm("6 --list-live wrote no fragment", #fs.list(W.rel .. "/plan/index.d") == 0, "fragments written")
T:finish({ ok = function(c) return "ok:expire-claims-list-live-rows:" .. c end })
