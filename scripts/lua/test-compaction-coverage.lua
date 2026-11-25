-- @env PATH HOME
-- @trace order:843-624y, order:2314-ktxt
--
-- test-compaction-coverage.lua — compaction deletes only the fragments it FOLDED, never merely
-- the ones it LOADED. Ported from the .sh of the same name (2314-ktxt). `compact` deleted
-- every fragment that loaded; one the fold does not absorb contributed nothing and went
-- anyway (a v0.4 release-gate closure was lost at 9d12276ca). It also ignored every argument,
-- so `compact --help` performed the compaction.
--
-- HERMETIC: tiny scratch ledgers. The thing under test deletes files.
--
-- Usage: tillandsias-plan script run scripts/lua/test-compaction-coverage.lua
-- Verdict: ok:compaction-coverage:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("compaction-coverage")
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-runnable-plan-binary") end
-- The pre-existing event keeps `events:` block-style: against a flow-style `events: []` the
-- renderer appends a second key and the candidate does not parse.
local BASE = [==[
plan_index:
  steps:
    - packet_id: fixture/alpha
      order: 900-aaaa
      title: "A fixture packet"
      status: ready
      kind: fix
      events:
        - type: note
          ts: "2025-12-31T00:00:00Z"
          agent_id: seed
          host: fixture
          summary: |
            A pre-existing event.
]==]
local GOOD, MISPLACED, CAPS = "20260101t000000z-good", "20260101t000001z-misplaced", "20260101t000002z-capabilities"
local FRAGMENTS = {
    -- FOLDED: a well-formed event on a packet that exists.
    [GOOD] = 'events:\n  - packet_id: fixture/alpha\n    event:\n      type: note\n      ts: "2026-01-01T00:00:00Z"\n      agent_id: fixture\n'
        .. "      host: fixture\n      summary: |\n        A well-formed event that the fold absorbs.\n",
    -- NOT FOLDED: a definition under `events:` with no `event:` block (801-kqme lost three).
    [MISPLACED] = 'events:\n  - packet_id: fixture/beta\n    order: 900-bbbb\n    title: "A definition written under the wrong key"\n    status: ready\n    kind: fix\n',
    -- NOT FOLDED: fold_capabilities reads this channel and no writer serialises it.
    [CAPS] = "capabilities:\n  - host_id: fixture-host\n    schema_version: 2\n    devices:\n      - device_class: cpu\n        usable: true\n",
}
local function world(...)
    local d = T:scratch()
    fs.mkdir(d.rel .. "/index.d")
    fs.write(d.rel .. "/index.yaml", BASE)
    for _, f in ipairs{ ... } do fs.write(d.rel .. "/index.d/" .. f .. ".yaml", FRAGMENTS[f]) end
    return d
end
local function compact(d, ...)
    local r = proc.run{ argv = { PLAN, "--index", d.abs .. "/index.yaml", "compact", ... }, cwd = d.abs,
        env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    return r.code, ((r.stdout or "") .. (r.stderr or "")):gsub("\r", "")
end
local function there(d, f) return fs.exists(d.rel .. "/index.d/" .. f .. ".yaml") end
local function base(d) return fs.read(d.rel .. "/index.yaml") end

local a = world(GOOD, MISPLACED, CAPS)
local rc, o = compact(a)
T:arm("1 compact exits 0 when there is folded work", rc == 0, tostring(rc) .. " " .. o)
T:arm("2 the folded fragment was consumed and its event reached the base", not there(a, GOOD) and text.contains(base(a), "A well-formed event that the fold absorbs"), base(a))
T:arm("3 the misplaced definition survived", there(a, MISPLACED), o)
T:arm("4 the capabilities fragment survived", there(a, CAPS), o)
T:arm("5 the refusal is reported", text.contains(o, "NOT consumed"), o)
T:arm("6 the report names the misplaced definition", o:find("no .event:. block") ~= nil, o)
T:arm("7 the report names the capabilities channel", text.contains(o, "capabilities"), o)

local b = world(MISPLACED)
rc, o = compact(b)
T:arm("8 an all-refused run says so and leaves the fragment", text.contains(o, "all 1 fragment(s) refused") and there(b, MISPLACED), o)

local c = world(GOOD)
local function untouched() return there(c, GOOD) and base(c) == BASE end
rc, o = compact(c, "--help")
T:arm("9 --help prints usage that says the command mutates, exit 0", rc == 0 and ("\n" .. o):find("\nusage: tillandsias%-plan compact") ~= nil and text.contains(o, "MUTATING"), tostring(rc) .. " " .. o)
T:arm("10 --help touched nothing", untouched(), base(c))
rc, o = compact(c, "--bogus")
T:arm("11 an unknown argument refuses with exit 2 and names it", rc == 2 and text.contains(o, "--bogus"), tostring(rc) .. " " .. o)
T:arm("12 an unknown argument touched nothing", untouched(), base(c))
rc, o = compact(c, "--dry-run")
T:arm("13 --dry-run reports what it would fold, exit 0", rc == 0 and text.contains(o, "dry-run — would fold 1 fragment"), tostring(rc) .. " " .. o)
T:arm("14 --dry-run touched nothing", untouched(), base(c))
compact(c)
T:arm("15 CONTROL a bare compact still consumes that same fragment", not there(c, GOOD), base(c))
T:finish()
