-- @trace order:1080-4deb, order:2387-lrg2
-- inputs: scripts/lua/test-scorable-obligation-gate.lua Cargo.toml methodology/cheatsheets.yaml methodology/convergence.yaml plan/inbox/codex.md plan/index.yaml plan/mo-full-attestations.d/README.md README.md scripts/archive-plan-packets.sh scripts/attest-native-lint.sh scripts/check-added-test-is-referenced.sh scripts/check-append-vs-origin-fold.sh scripts/check-deslop-due.sh scripts/check-mo-full-attestations.sh scripts/check-plan-binary-current.sh scripts/check-resumable-claim-dirt.sh scripts/check-scorable-obligation-added.sh scripts/cycle-preflight.sh scripts/gate-stamp.sh scripts/hooks/pre-push-version-guard.sh scripts/land-queue.sh scripts/lib-freeze-paths.sh scripts/lua/check-added-fragments-parse.lua scripts/lua/check-carried-obligations.lua scripts/lua/check-fragment-status-loss.lua scripts/lua/check-fragment-ts-skew.lua scripts/lua/check-no-base64-script-injection.lua scripts/lua/check-portability-idioms.lua scripts/lua/check-windows-tray-clippy.lua scripts/lua/probe-remote-reachable.lua scripts/lua/test-gate-stamp-scope.lua scripts/mo-full-attest.sh scripts/plan-binary-probe.sh scripts/promote-stable.sh scripts/release-freeze.sh scripts/release-preflight.sh scripts/remote-probe-judge.sh scripts/salvage-dirty-worktree.sh scripts/stage-image-cheatsheets.sh scripts/sweep-salvage-refs.sh scripts/test-pre-push-empty-ref-list.sh scripts/unreferenced-grandfathered.txt scripts/with-wsl2-builder.sh lib/lua/common/ crates/tillandsias-plan/
-- @env PATH HOME LIVE_LANE LIVE_LANE_TRUNK
--
-- test-ledger-write-reaches-its-reader.lua — 1080-4deb, A WRITE THAT LANDED SOMEWHERE NO
-- READER CONSULTS. Ported from test-ledger-write-reaches-its-reader.sh (2387-lrg2), from the
-- version carrying #1597's fix (the plan binary resolves from the CHECKOUT, absolute, never
-- the caller's cwd); same arms, in its order.
--
-- Five writes in one day each succeeded, landed in a real place, and were invisible to the
-- reader asking the question they answered. The NEGATIVE CONTROL RUNS FIRST: a checker that
-- flags healthy packets empties the ready set, and a coordinator reading an empty queue
-- concludes the fleet is done. Every arm is VACUOUS if it does not hold, so its failure stops
-- the test before any arm reports.
--
--   control      a healthy ledger produces no ready-but-landed report; and the checker can fire
--   denominator  the reader sees all 7 fixture ready packets (`--limit` is mandatory)
--   arm3         ready-but-landed is reported; healthy stays silent; the narrowed reader counts only
--                fix(|close(|feat(<order>) subjects, and still fires on one
--   arm1         ready-but-claimed (claim event, no status move) is reported; a released claim and
--                claim-free packets are not; a TWO-claim set survives the reader (1399-wtpq)
--   arm2         a blocker marker in a ready packet's prose is reported, healthy ones are not
--   arm4         the 1071-adhj discharge label is present in test-scorable-obligation-gate.lua
--
-- LIVE LANE (opt-in, report only, never a gate): `-- --live` or LIVE_LANE=1 runs the same readers
-- over the folded plan/index.yaml and LIVE_LANE_TRUNK (default origin/linux-next).
--
-- GRAMMAR ok:ledger-write-reaches-its-reader:<n> arms | violation:ledger-write-reaches-its-reader:<n>-failed
--       | refused:ledger-write-reaches-its-reader:<reason>

local fixture = require "common.fixture"
local T = fixture.new("ledger-write-reaches-its-reader")
local ROOT = fixture.repo_root()
-- From the CHECKOUT, absolute (the kit joins a relative probe answer to repo_root, 84f37ff24).
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary", "the probe resolved nothing runnable") end

local function set(list) local s = {} for _, v in ipairs(list) do s[v] = true end return s end
local function join(list) return "[" .. table.concat(list, " ") .. "]" end

-- Rows: <rank> <epic> <order> <packet_id> <priority> <release>. `--limit` is MANDATORY: the bare
-- default returned 8 of 473 ready rows on the real ledger, a sample reported as a scan.
local function ready_rows(idx)
    local r = T:run{ PLAN, "--index", idx, "select-rows", "--status", "ready", "--limit", "2000",
        cwd = ROOT, env_unset = { "TILLANDSIAS_*" } }
    local rows = {}
    for _, l in ipairs(text.lines(r.stdout or "")) do
        local f = {}
        for w in l:gmatch("%S+") do f[#f + 1] = w end
        if f[3] then rows[#rows + 1] = { order = f[3], pid = f[4] } end
    end
    return rows
end
local function ready_orders(idx)
    local o = {}
    for _, row in ipairs(ready_rows(idx)) do o[#o + 1] = row.order end
    return o
end

-- A landing CLAIM is a subject OPENING with fix(|close(|feat(<order>): the order inside the first
-- paren group, or it is not counted. A body mention, a docs( subject, a bare token: references.
local function landed_orders_from(lines)
    local seen, out = {}, {}
    for _, l in ipairs(lines) do
        local subject = l:match("^%S+%s+(.+)$")
        if subject then
            for _, verb in ipairs({ "fix", "close", "feat" }) do
                local o = subject:match("^" .. verb .. "%((%d%d%d?%d?%d?%-[a-z0-9][a-z0-9][a-z0-9][a-z0-9])%)")
                if o and not seen[o] then seen[o] = true; out[#out + 1] = o end
            end
        end
    end
    table.sort(out)
    return out
end
local function report_ready_but_landed(idx, landed)
    local have, out = set(landed), {}
    for _, o in ipairs(ready_orders(idx)) do if have[o] then out[#out + 1] = o end end
    return out
end

-- ARM 1's reader: packet ids that are the subject of a `type: claim` event in the fragments, minus
-- those a `type: release` resolved (a released claim back at ready is the healthy case).
local function event_ids(frags_rel, kind)
    local ids = {}
    for _, f in ipairs(fs.list(frags_rel) or {}) do
        local name = f:match("[^/]+$")
        if name:match("%.yaml$") then
            local pid
            for _, l in ipairs(text.lines(fs.read(frags_rel .. "/" .. name) or "")) do
                local p = l:match("^  %- packet_id: (%S+)")
                if p then pid = p end
                if l == "      type: " .. kind and pid then ids[pid] = true end
            end
        end
    end
    return ids
end
local function report_ready_but_claimed(idx, frags_rel)
    local claimed, released = event_ids(frags_rel, "claim"), event_ids(frags_rel, "release")
    for k in pairs(released) do claimed[k] = nil end
    local out = {}
    for _, row in ipairs(ready_rows(idx)) do if claimed[row.pid] then out[#out + 1] = row.order end end
    return out
end

-- ARM 2's reader. The marker list is CLOSED and mechanical; it REPORTS, never withholds.
local MARKERS = { "blocked", "blocker", "cannot proceed", "cannot start", "no host can", "no host may",
    "requires the operator", "operator-authorised", "waiting on" }
local function marked(l) for _, m in ipairs(MARKERS) do if text.contains(l, m) then return true end end return false end
local function blocked_in_prose_orders(idx_rel)
    local seen, out, order, status = {}, {}, "", ""
    for _, l in ipairs(text.lines(fs.read(idx_rel) or "")) do
        if l:match("^  %- packet_id:") then order, status = "", ""
        else
            order = l:match("^    order: (%S+)") or order
            status = l:match("^    status: (%S+)") or status
            if status == "ready" and order ~= "" and marked(l)
                and (text.contains(l, "summary:") or l:match("^ +%- ")) and not seen[order] then
                seen[order] = true; out[#out + 1] = order
            end
        end
    end
    table.sort(out)
    return out
end

local function has(list, v) for _, x in ipairs(list) do if x == v then return true end end return false end

-- ------------------------------------------------------------------ LIVE LANE --
local live_ok, live_env = pcall(env.get, "LIVE_LANE")
if (arg and arg[1] == "--live") or (live_ok and live_env == "1") then
    if not fs.exists("plan/index.yaml") then T:refuse("live-lane-no-ledger", ROOT .. "/plan/index.yaml missing") end
    local trunk = env.get("LIVE_LANE_TRUNK")
    if not trunk or trunk == "" then trunk = "origin/linux-next" end
    local g = T:run{ "git", "-C", ROOT, "log", "--format=%h %s", "-10000", trunk }
    if g.code ~= 0 then T:refuse("live-lane-no-trunk", "cannot read " .. trunk .. " locally (fetch first)") end
    local subjects = text.lines(g.stdout or "")
    local idx = ROOT .. "/plan/index.yaml"
    out.line(string.format("live-lane: scan=%s subjects=%d denominator-ready=%d (select-rows --limit 2000)",
        trunk, #subjects, #ready_orders(idx)))
    out.line("live-lane: ready-but-landed " .. join(report_ready_but_landed(idx, landed_orders_from(subjects))))
    out.line("live-lane: ready-but-claimed " .. join(report_ready_but_claimed(idx, "plan/index.d")))
    out.line("live-lane: blocked-in-prose " .. join(blocked_in_prose_orders("plan/index.yaml")))
    T:cleanup()
    verdict.ok("ledger-write-reaches-its-reader-live")
end

-- ------------------------------------------------------------------- fixtures --
local W = T:scratch()
local LEDGER = [[
plan_index:
  default_status_values: [ready, completed, in_progress]
packets:
  - packet_id: healthy-pkt
    order: 900-heal
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p2
  - packet_id: landed-but-ready
    order: 900-land
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p2
  - packet_id: claimed-but-ready
    order: 900-clm
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p2
  - packet_id: referenced-not-landed
    order: 900-refs
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p2
  - packet_id: released-back-to-ready
    order: 900-rel
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p2
  - packet_id: blocked-in-prose-pkt
    order: 900-blk
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p2
    events:
      - type: note
        ts: "2026-09-10T00:00:00Z"
        host: fixture-host
        summary: "release cannot proceed until the integrator re-baselines; waiting on a maintainer"
  - packet_id: blocked-in-criterion-pkt
    order: 900-crt
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p2
    exit_criteria:
      - the operator-authorised override expired and no host may land this
]]
fs.write(W.rel .. "/ledger.yaml", LEDGER)
fs.mkdir(W.rel .. "/fragments.d")
fs.write(W.rel .. "/fragments.d/claim-frag.yaml", [[
events:
  - packet_id: claimed-but-ready
    event:
      type: claim
      ts: "2026-09-10T06:00:00Z"
      host: fixture-host
      summary: claimed for cycle but appended the event only
  - packet_id: released-back-to-ready
    event:
      type: claim
      ts: "2026-09-10T06:00:00Z"
      host: fixture-host
      summary: claimed, then...
  - packet_id: released-back-to-ready
    event:
      type: release
      ts: "2026-09-10T06:05:00Z"
      host: fixture-host
      summary: released deliberately, status is ready again and events match
]])
local IDX = W.abs .. "/ledger.yaml"

-- ------------------------------------------------------ NEGATIVE CONTROL (FIRST) --
local none = report_ready_but_landed(IDX, {})
if not T:arm("negative-control: healthy packets produce no report", #none == 0, join(none)) then
    out.line("  Every arm below compares against this. Stopping rather than reporting arm results that cannot mean anything.")
    T:finish()
end
-- The control must be capable of firing, or a checker reporting nothing satisfies it.
local fired = report_ready_but_landed(IDX, landed_orders_from({ "deadbeef fix(900-land): land the arm" }))
T:arm("negative-control is not vacuous: the checker can fire", #fired > 0, join(fired))

-- --------------------------------------------------------- DENOMINATOR MUST BE KNOWN --
local seen = #ready_orders(IDX)
if not T:arm("denominator: the reader sees all 7 fixture ready packets", seen == 7,
    "the reader saw " .. seen .. " — arms would measure a sample") then T:finish() end

-- ------------------------------------------------------------------------ ARM 3 --
T:arm("arm3: a ready packet with a landed commit naming its order is reported", has(fired, "900-land"), join(fired))
T:arm("arm3: the healthy packet is still not reported when another packet fires", not has(fired, "900-heal"), join(fired))
local out2 = report_ready_but_landed(IDX, landed_orders_from({
    "cafe10 docs(900-refs): reference 900-heal in the audit write-up", "baa01f 900-land" }))
T:arm("arm3-narrow: a docs(900-refs) subject does not report (prose is not a claim)", not has(out2, "900-refs"), join(out2))
T:arm("arm3-narrow: a mid-subject mention of 900-heal does not cross-report", not has(out2, "900-heal"), join(out2))
T:arm("arm3-narrow: a bare order token with no completion-shaped subject does not report", #out2 == 0, join(out2))
local out3 = report_ready_but_landed(IDX, landed_orders_from({ "00000aa fix(900-refs): close the packet" }))
T:arm("arm3-narrow: the narrowed reader fires on a genuinely landed fix(900-refs)", has(out3, "900-refs"), join(out3))

-- ------------------------------------------------------------------------ ARM 1 --
local claimed = report_ready_but_claimed(IDX, W.rel .. "/fragments.d")
T:arm("arm1: the healthy packet produces no report from the claim check", not has(claimed, "900-heal"), join(claimed))
T:arm("arm1: a ready packet with a claim event and no release is reported", has(claimed, "900-clm"), join(claimed))
T:arm("arm1: the claim check does not report on claim-free packets", not has(claimed, "900-land"), join(claimed))
-- TWO claimed packets at once (1399-wtpq): a set passed wrongly agrees with one id and loses two.
fs.mkdir(W.rel .. "/two/fragments.d")
fs.write(W.rel .. "/two/ledger.yaml", LEDGER .. [[
  - packet_id: claimed-but-ready-two
    order: 900-cl2
    status: ready
    desired_release: v0.5
    pickup_role: linux
    priority: p2
]])
fs.write(W.rel .. "/two/fragments.d/claim-frag.yaml", [[
events:
  - packet_id: claimed-but-ready
    event:
      type: claim
      ts: "2026-09-10T06:00:00Z"
      host: fixture-host
      summary: first of two claims in one set
  - packet_id: claimed-but-ready-two
    event:
      type: claim
      ts: "2026-09-10T06:01:00Z"
      host: fixture-host
      summary: second of two claims in one set
]])
local two = report_ready_but_claimed(W.abs .. "/two/ledger.yaml", W.rel .. "/two/fragments.d")
T:arm("arm1-two: both packets of a two-claim set are reported (multi-line set survives the reader)",
    has(two, "900-clm") and has(two, "900-cl2"), join(two))
T:arm("arm1: a released claim is not reported (status matches its events)", not has(claimed, "900-rel"), join(claimed))

-- ------------------------------------------------------------------------ ARM 2 --
local prose = blocked_in_prose_orders(W.rel .. "/ledger.yaml")
T:arm("arm2: blocker-in-note-summary (900-blk) is reported", has(prose, "900-blk"), join(prose))
T:arm("arm2: blocker-in-exit-criterion (900-crt) is reported", has(prose, "900-crt"), join(prose))
T:arm("arm2: the prose scan does not report healthy packets", not has(prose, "900-heal"), join(prose))
T:arm("arm2: the prose scan does not report marker-free ready packets", not has(prose, "900-land"), join(prose))
T:arm("arm2: the prose scan is independent of the claim check (900-clm silent)", not has(prose, "900-clm"), join(prose))

-- ------------------------------------------------------------------------ ARM 4 --
T:arm("arm4: the 1071-adhj discharge label is present in test-scorable-obligation-gate.lua",
    text.contains(fs.read("scripts/lua/test-scorable-obligation-gate.lua") or "",
        "obligation in a correction fragment satisfies the FOLDED packet"), "label missing")

T:finish()
