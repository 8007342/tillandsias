-- @env PATH HOME TILLANDSIAS_PLAN_BINARY
-- @trace order:641-e2qa, order:1079-qb8k, order:2387-b6v2
--
-- test-expire-claims-write-is-opt-in.lua — `tillandsias-plan expire-claims` is read-only unless
-- --write (or --apply) is given: the bare, --list-live and --dry-run forms leave the ledger
-- byte-identical yet still report the stale candidate, --write expires it and the fragment folds,
-- --write --dry-run is refused and writes nothing, and a claim inside the TTL is left alone.
-- Ported from the .sh of the same name (2387-b6v2). Each arm seeds a scratch ledger.
--
-- Usage: tillandsias-plan script run scripts/lua/test-expire-claims-write-is-opt-in.lua
-- Verdict: ok:expire-claims-write-is-opt-in:<n> arms | violation:... | skip:...:no-plan-binary

local fixture = require "common.fixture"
local T = fixture.new("expire-claims-write-is-opt-in")
local PLAN = env.get("TILLANDSIAS_PLAN_BINARY")
if not PLAN or PLAN == "" then PLAN = fixture.plan_binary() end
if not PLAN then T:skip("no-plan-binary") end
local NOW = "1787745600"
local FRESH, STALE = "2026-08-26T11:00:00Z", "2026-08-20T00:00:00Z"   -- inside / outside the 24h TTL
local w = T:scratch()
local IDX = w.abs .. "/plan/index.yaml"
local function seed(ts)
    T:must{ "rm", "-rf", w.abs .. "/plan" }
    fs.mkdir(w.rel .. "/plan/index.d")
    fs.write(w.rel .. "/plan/index.yaml", "plan_index:\n  version: v1\n  root: plan/\n  steps:\n"
        .. "    - packet_id: stale-claim\n      order: 900-aaaa\n      title: \"t\"\n      status: in_progress\n      kind: fix\n      depends_on: []\n"
        .. "      events:\n        - type: note\n          ts: \"" .. ts .. "\"\n          host: otherhost\n          summary: |\n            claimed for cycle " .. ts .. "\n")
end
-- Every file under plan/, by name and content: what the .sh's sha256 over the tree compared.
local function tree()
    local r = T:run{ "find", w.abs .. "/plan", "-type", "f" }
    local names = {}
    for f in (r.stdout or ""):gmatch("[^\n]+") do names[#names + 1] = f end
    table.sort(names)
    local parts = {}
    for _, f in ipairs(names) do parts[#parts + 1] = f .. "\0" .. fs.read(w.rel .. f:sub(#w.abs + 1)) end
    return table.concat(parts, "\0\0")
end
local function run(...)
    local r = T:run{ PLAN, "--index", IDX, "expire-claims", "--now-epoch", NOW, ... }
    return (r.stdout or "") .. (r.stderr or ""), r.code
end

seed(STALE); local before = tree(); local o, rc = run(); local after = tree()
T:arm("bare expire-claims leaves the ledger byte-identical", before == after, "bare expire-claims MUTATED the ledger (this is the defect)")
T:arm("bare expire-claims exits 0", rc == 0, "exit " .. tostring(rc))
T:arm("bare invocation reports mode=dry-run", text.contains(o, "mode=dry-run"), o)
T:arm("bare invocation still reports the stale candidate", o:find("expire%-candidate.*stale%-claim") ~= nil, "it went blind, not read-only: " .. o)
T:arm("dry-run output names --write so the reader learns it", text.contains(o, "--write"), o)
T:arm("dry-run output says nothing happened yet", text.contains(o, "nothing has been written"), o)

seed(STALE); before = tree(); run("--list-live")
T:arm("--list-live alone leaves the ledger byte-identical", before == tree(), "--list-live alone MUTATED the ledger")
seed(STALE); before = tree(); run("--dry-run")
T:arm("--dry-run leaves the ledger byte-identical", before == tree(), "--dry-run MUTATED the ledger")

seed(STALE); before = tree(); o = run("--write")
T:arm("--write mutates the ledger", before ~= tree(), "--write wrote NOTHING; 641-e2qa expiry has been weakened, not preserved")
T:arm("--write reports the claim as expired", o:find("expired%-claim.*stale%-claim") ~= nil, o)
T:arm("--write reports mode=write", text.contains(o, "mode=write"), o)
local st = T:run{ PLAN, "--index", IDX, "status", "stale-claim" }
T:arm("--write folds through to status=ready", text.contains((st.stdout or "") .. (st.stderr or ""), "ready"), (st.stdout or "") .. (st.stderr or ""))

seed(STALE); before = tree(); run("--apply")
T:arm("--apply is accepted as the write opt-in", before ~= tree(), "--apply did not write")
seed(STALE); before = tree(); o, rc = run("--write", "--dry-run")
T:arm("--write --dry-run refused with exit 2", rc == 2, "exit " .. tostring(rc))
T:arm("a refused invocation writes nothing", before == tree(), "a refused invocation MUTATED the ledger")
seed(FRESH); before = tree(); run("--write")
T:arm("--write leaves a within-TTL claim alone", before == tree(), "--write expired a FRESH claim")
-- check-plan-binary-current.sh reads this line to count the arms against a candidate binary.
out.line(("expire-claims-write-is-opt-in: %d passed, %d failed"):format(T.passed, #T.failed))
T:finish()
