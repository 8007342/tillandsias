-- @trace order:833-fpe7, spec:meta-orchestration, order:2360-psb8
-- @env PATH HOME
--
-- test-resumable-claim-dirt.lua — hermetic fixture for scripts/check-resumable-claim-dirt.sh.
-- Ported from test-resumable-claim-dirt.sh (2360-psb8); same six cases.
--
-- A detector that only ever says `resumable:` is the deadlock with extra steps; the
-- negative controls are the point. Each case is a throwaway git repo with its own minimal
-- ledger, driven through the REAL plan binary, so the fold, the claim-convention match and
-- the TTL arithmetic are the production ones. Fixed clock: 1787446800 (2026-08-23T01:00Z), TTL 24h.
--
--   1  clean tree names itself (ok:clean-tree, rc 4)
--   2  NEGATIVE an untracked file refuses
--   3  NEGATIVE tracked dirt OLDER than the claim refuses
--   4  NEGATIVE a live claim held by ANOTHER host refuses
--   5  NEGATIVE this host's claim past the TTL refuses
--   6  own live claims with attributable dirt: resumable, naming BOTH orders
--
-- GRAMMAR ok:resumable-claim-dirt:<n> arms | violation:resumable-claim-dirt:<n>-failed
--       | refused:resumable-claim-dirt:no-plan-binary

local fixture = require "common.fixture"
local T = fixture.new("resumable-claim-dirt")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary", "build one: cargo build --release -p tillandsias-plan") end
if not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
-- The detector and what it sources (859-b2zc: agent-identity.sh joined its dependencies).
local SHIPPED = { "check-resumable-claim-dirt.sh", "plan-binary-probe.sh", "agent-identity.sh" }

local LIVE = [[
packets:
  - packet_id: fix-a
    order: 901-aaaa
    title: "a"
    status: in_progress
    desired_release: v0.5
    events:
      - type: note
        ts: "2026-08-23T00:00:00Z"
        host: fixturehost
        summary: claimed for cycle 2026-08-23T00:00Z
]]

-- A repo with the ledger and the detector committed clean, so each case's dirt is
-- exactly what it creates.
local function scaffold(ledger)
    local d = T:git_repo()
    fs.mkdir(d.rel .. "/plan"); fs.mkdir(d.rel .. "/scripts")
    fs.write(d.rel .. "/plan/index.yaml", ledger)
    for _, s in ipairs(SHIPPED) do fs.write(d.rel .. "/scripts/" .. s, fs.read("scripts/" .. s)) end
    T:must{ "git", "-C", d.abs, "add", "-A" }
    T:must{ "git", "-C", d.abs, "commit", "-q", "-m", "scaffold" }
    return d
end
local function run(d)
    local r = T:run{ SH, "scripts/check-resumable-claim-dirt.sh", cwd = d.abs, env_unset = { "TILLANDSIAS_*" },
        env = { TILLANDSIAS_PLAN_BIN = PLAN, TILLANDSIAS_WORKSTATION = "fixturehost", TILLANDSIAS_RESUME_NOW_EPOCH = "1787446800" },
        timeout_ms = 60000 }
    return text.trim(r.stdout or "") .. "\nrc=" .. tostring(r.code)
end
local function dirt(d, name, body, stamp)
    fs.write(d.rel .. "/" .. name, body .. "\n")
    if stamp then T:must{ "touch", "-t", stamp, d.abs .. "/" .. name, env = { TZ = "UTC" } } end
end

local d = scaffold(LIVE)
local o = run(d)
T:arm("1 a clean tree names itself", o == "ok:clean-tree\nrc=4", o)

d = scaffold(LIVE)
dirt(d, "stray.txt", "stray")
o = run(d)
T:arm("2 NEGATIVE untracked dirt is refused", o == "unattributable:untracked-paths:stray.txt\nrc=3", o)

d = scaffold(LIVE)
dirt(d, "old.txt", "work", "202608222300.00")   -- 2026-08-22T23:00Z, before the claim
T:must{ "git", "-C", d.abs, "add", "old.txt" }
o = run(d)
T:arm("3 NEGATIVE dirt older than the claim is refused", o == "unattributable:paths-predate-claim:old.txt\nrc=3", o)

d = scaffold((LIVE:gsub("fixturehost", "otherhost")))
dirt(d, "new.txt", "work"); T:must{ "git", "-C", d.abs, "add", "new.txt" }
o = run(d)
T:arm("4 NEGATIVE another host's claim is not ours", o == "unattributable:no-live-claim-by-this-host\nrc=3", o)

d = scaffold((LIVE:gsub("2026%-08%-23T00:00", "2026-08-20T00:00")))
dirt(d, "new.txt", "work"); T:must{ "git", "-C", d.abs, "add", "new.txt" }
o = run(d)
T:arm("5 NEGATIVE a claim past the TTL is not a resume anchor", o == "unattributable:no-live-claim-by-this-host\nrc=3", o)

d = scaffold(LIVE .. [[
  - packet_id: fix-b
    order: 902-bbbb
    title: "b"
    status: in_progress
    desired_release: v0.5
    events:
      - type: note
        ts: "2026-08-23T00:30:00Z"
        host: fixturehost
        summary: claimed for cycle 2026-08-23T00:30Z
]])
dirt(d, "a.txt", "work-a"); dirt(d, "b.txt", "work-b")
T:must{ "git", "-C", d.abs, "add", "a.txt", "b.txt" }
T:must{ "touch", "-t", "202608230045.00", d.abs .. "/a.txt", d.abs .. "/b.txt", env = { TZ = "UTC" } }   -- after both claims
o = run(d)
T:arm("6 own live claims with attributable dirt: resumable, both orders named", o == "resumable:901-aaaa,902-bbbb\nrc=0", o)

T:finish()
