-- @trace order:1506-nvqt, order:2368-efqj, openspec/changes/fleet-messaging-poc/specs/fleet-messaging/spec.md
--
-- test-fleet-msg-store.lua — the fleet message bus's LOCAL store: `tillandsias-plan msg`
-- over a scratch XDG_STATE_HOME. No daemon, no socket; where the infrastructure would ack,
-- the fixture writes the receipt. Ported from the .sh (2368-efqj).
--
--    1 shape      a 9-line body is refused:msg:shape:lines>8, outbox unchanged
--    2 secret     a github token is refused; NEGATIVE: with TILLANDSIAS_MSG_SHAPE_LAX (honoured
--                 only on an explicit TILLANDSIAS_MSG_ROOT) the same send is queued
--    3 duplicate  a repeated --id is skip:msg:duplicate:<id>, store unchanged
--    4 queued     ok:msg:queued:<id> within 1 s with no daemon; status pending
--    5 recv       twice prints the same id, --keep leaves new/, the receipt never changes
--    6 status     pending -> acked + via:local, and undelivered:expired
--    7 ttl        30 and 700000 are out of bounds; an omitted --ttl records 86400
--    8 expiry     a message past its TTL is not printed and is gone
--    9 reply      a reply to a broadcast in the LOCAL INBOX is refused with the remedy; an
--                 unknown id is unknown-reply-target
--   10 gap        a seq gap carries the gap: prefix
--   11 no-lane    whoami with no lane is refused:msg:no-lane, stdout empty
--   12 surface    capabilities lists msg, the forge-plan probe sees it, `msg ack` is unknown
--
-- Verdict: ok:fleet-msg-store:<n>/<n> | violation:fleet-msg-store:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("fleet-msg-store")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end
local W = T:scratch()
local H = "fixturehost"
for _, p in ipairs{ "home", "fleet" } do fs.mkdir(W.rel .. "/" .. p) end
local LANES = W.rel .. "/state/tillandsias/msg/lanes"
local A, B = LANES .. "/a-default", LANES .. "/b-default"
local NOW = text.trim(T:must{ "date", "-u", "+%Y-%m-%dT%H:%M:%SZ" }.stdout)
local BODY = "FYI:1506-nvqt:store fixture\n- scripts/lua/test-fleet-msg-store.lua\n"
local TO = H .. "/b-default"

-- msg(lane or nil, stdin, args...): one hermetic run.
local extra = {}
local function msg(lane, stdin, ...)
    local e = { HOME = W.abs .. "/home", XDG_STATE_HOME = W.abs .. "/state", TILLANDSIAS_MSG_HOST = H, TILLANDSIAS_MSG_LANE = lane,
        TILLANDSIAS_MSG_FORGE_MOUNT = W.abs .. "/no-forge-mount", TILLANDSIAS_MSG_FLEET_DIR = W.abs .. "/fleet" }
    for k, v in pairs(extra) do e[k] = v end
    local argv = { PLAN, "msg" }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    argv.env, argv.env_unset, argv.stdin, argv.cwd = e, { "TILLANDSIAS_*" }, stdin or "", W.abs
    local r = T:run(argv)
    local o = { rc = r.code, out = text.trim(r.stdout or ""), err = r.stderr or "" }
    o.first = o.err:match("^[^\n]*")
    o.afforded = o.err:find("  why: ", 1, true) and o.err:find("  remedy: ", 1, true)
    o.id = o.out:match("^ok:msg:queued:(.*)$")
    o.raw = "rc=" .. tostring(o.rc) .. " out=[" .. o.out .. "] err=[" .. o.first .. "]"
    return o
end
local function send(stdin, ...) return msg("a-default", stdin, "send", "--to", TO, ...) end
local function snap(dir)
    local r = T:run{ SH, "-s", "--", W.abs .. dir:sub(#W.rel + 1), stdin = '[ -d "$1" ] || exit 0\ncd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf "%s " "$f"; cksum <"$f"; done\n' }
    return r.stdout or ""
end
local function has(o, s) return o:find(s, 1, true) ~= nil end
local function envelope(box, id, from, to, seq, ts, ttl, broadcast, body)
    fs.mkdir(box .. "/inbox/new"); fs.mkdir(box .. "/inbox/cur")
    fs.write(box .. "/inbox/new/" .. id, "id: " .. id .. "\nfrom: " .. H .. "/" .. from .. "\nto:\n- " .. H .. "/" .. to .. "\nfrom_agent: fixture\nseq: " .. seq
        .. "\nts: " .. ts .. "\nttl_s: " .. ttl .. "\nbroadcast: " .. broadcast .. "\nkind: FYI\nbody: '" .. body .. "'\n")
end

-- 1
local before = snap(A .. "/outbox")
local o = send("FYI:x:nine lines\n" .. ("- 1506-nvqt\n"):rep(8))
T:arm("1 shape: a 9-line body is refused, outbox unchanged", o.first == "refused:msg:shape:lines>8" and o.rc == 1 and o.out == "" and o.afforded and snap(A .. "/outbox") == before, o.raw)

-- 2: the body is otherwise well shaped, so with the check off the send SUCCEEDS.
local SECRET = "FYI:creds:leak\n- 1506-nvqt " .. "ghp_" .. ("a"):rep(36) .. "\n"
before = snap(A .. "/outbox")
o = send(SECRET)
T:arm("2 secret: a github token is refused, outbox unchanged", o.first == "refused:msg:secret-shaped:github-token" and o.rc == 1 and o.afforded and snap(A .. "/outbox") == before, o.raw)
extra = { TILLANDSIAS_MSG_SHAPE_LAX = "1", TILLANDSIAS_MSG_ROOT = W.abs .. "/state/tillandsias/msg" }
o = send(SECRET)
extra = {}
T:arm("2 NEGATIVE: the LAX seam queues the same send, so the arm discriminates", o.id ~= nil, o.raw)

-- 3
o = send(BODY, "--id", "fixture-dup-1")
before = snap(A)
local o2 = send("ASK:other:body\n- 1506-nvqt\n", "--id", "fixture-dup-1")
T:arm("3 duplicate: a repeated --id is skipped and writes nothing", o.id == "fixture-dup-1" and o2.out == "skip:msg:duplicate:fixture-dup-1" and o2.rc == 0 and snap(A) == before, o.raw .. " then " .. o2.raw)

-- 4
local t0 = time.now_ms()
o = send(BODY)
local took = time.now_ms() - t0
local ID = o.id or "none"
local st = msg("a-default", nil, "status", ID)
T:arm("4 queued: within 1 s with no daemon, then pending", ID:find("^m%-%d%w*t%d%w*z%-%x+") and took <= 1000 and fs.exists(A .. "/outbox/new/" .. ID) and st.out == "pending" and st.rc == 0,
    took .. "ms " .. o.raw .. " then " .. st.raw)

-- 5: the fixture plays the mover.
fs.mkdir(B .. "/inbox/new"); fs.mkdir(B .. "/inbox/cur")
fs.write(B .. "/inbox/new/" .. ID, fs.read(A .. "/outbox/new/" .. ID))
local receipt = fs.read(A .. "/receipts/" .. ID)
local keep = msg("b-default", nil, "recv", "--keep")
local kept = fs.exists(B .. "/inbox/new/" .. ID)
local r1, r2 = msg("b-default", nil, "recv"), msg("b-default", nil, "recv")
T:arm("5 recv: twice the same id, --keep leaves new/, the sender's receipt byte-identical", has(keep.out, "msg:" .. ID .. " from=" .. H .. "/a-default") and kept and has(r1.out, "msg:" .. ID .. " ")
    and r1.out == r2.out and not fs.exists(B .. "/inbox/new/" .. ID) and fs.exists(B .. "/inbox/cur/" .. ID) and fs.read(A .. "/receipts/" .. ID) == receipt, keep.raw .. " / " .. r1.raw .. " / " .. r2.raw)

-- 6
local function write_receipt(tail)
    fs.write(A .. "/receipts/" .. ID, "id: " .. ID .. "\nfrom: " .. H .. "/a-default\nts: " .. NOW .. "\nttl_s: 86400\nbroadcast: false\nrecipients:\n- to: " .. TO .. "\n" .. tail)
end
local s0 = msg("a-default", nil, "status", ID).out
write_receipt("  state: acked\n  at: " .. NOW .. "\n  via: local\n")
local s1 = msg("a-default", nil, "status", ID).out
write_receipt("  state: undelivered\n  at: " .. NOW .. "\n  reason: expired\n")
local s2 = msg("a-default", nil, "status", ID).out
T:arm("6 status: pending, acked via local, undelivered:expired", s0 == "pending" and s1 == "acked:" .. TO .. "@" .. NOW .. "\nvia:local" and s2 == "undelivered:expired", s0 .. " / " .. s1 .. " / " .. s2)

-- 7
before = snap(A)
local lo, hi = send(BODY, "--ttl", "30"), send(BODY, "--ttl", "700000")
local same = snap(A) == before
o = send(BODY)
local env_out = o.id and fs.read(A .. "/outbox/new/" .. o.id) or ""
local function oob(v) return "refused:msg:ttl-out-of-bounds:" .. v .. ":min=60:max=604800" end
T:arm("7 ttl: out of bounds is refused and writes nothing; the default is 86400", lo.first == oob(30) and lo.rc == 1 and lo.afforded and hi.first == oob(700000) and hi.rc == 1 and same
    and has("\n" .. env_out, "\nttl_s: 86400\n"), lo.raw .. " / " .. hi.raw .. " same=" .. tostring(same))

-- 8
envelope(B, "m-fixture-expired", "z-default", "b-default", 1, "2000-01-01T00:00:00Z", 60, "false", "FYI:old:long expired")
o = msg("b-default", nil, "recv")
T:arm("8 expiry: a message past its TTL is not printed and is gone", o.rc == 0 and not has(o.out, "m-fixture-expired") and not fs.exists(B .. "/inbox/new/m-fixture-expired")
    and not fs.exists(B .. "/inbox/cur/m-fixture-expired"), o.raw)

-- 9
envelope(A, "m-fixture-bcast", "z-default", "a-default", 0, NOW, 86400, "true", "FYI:all:to everyone")
before = snap(A .. "/outbox")
o = msg("a-default", BODY, "send", "--to", H .. "/z-default", "--in-reply-to", "m-fixture-bcast")
o2 = msg("a-default", BODY, "send", "--to", H .. "/z-default", "--in-reply-to", "m-never-seen")
T:arm("9 reply: to a local broadcast is refused naming the remedy; an unknown id is unknown-reply-target",
    o.first == "refused:msg:reply-to-broadcast:m-fixture-bcast:a broadcast has no single counterpart; send a new message to " .. H .. "/z-default instead" and o.rc == 1 and o.afforded
    and not fs.exists(A .. "/receipts/m-fixture-bcast") and o2.first == "refused:msg:unknown-reply-target:m-never-seen" and o2.rc == 1 and snap(A .. "/outbox") == before, o.raw .. " / " .. o2.raw)

-- 10
for _, s in ipairs{ 1, 3 } do envelope(B, "m-fixture-seq" .. s, "y-default", "b-default", s, NOW, 86400, "false", "FYI:seq:number " .. s) end
o = msg("b-default", nil, "recv")
T:arm("10 gap: seq 3 after seq 1 carries gap:, seq 1 does not", has(o.out, "msg:m-fixture-seq1 ") and not has(o.out, "gap:msg:m-fixture-seq1 ") and has(o.out, "gap:msg:m-fixture-seq3 "), o.raw)

-- 11
o, o2 = msg(nil, nil, "whoami"), msg("a-default", nil, "whoami")
T:arm("11 no-lane: refused with an empty stdout; with a lane it prints <host>/<lane>", o.out == "" and o.first == "refused:msg:no-lane" and o.rc == 1 and o.afforded and o2.out == H .. "/a-default", o.raw .. " / " .. o2.raw)

-- 12
local caps = T:run{ PLAN, "capabilities", cwd = ROOT }.stdout or ""
local probe = T:run{ SH, "-s", "--", PLAN, cwd = ROOT, stdin = [[
. images/default/lib-expert-capability.sh && tillandsias_expert_capability "$1" "" || exit 1
case ",${TILLANDSIAS_EXPERT_CAP_NOW:-}," in (*,msg,*) exit 0 ;; (*) exit 1 ;; esac
]] }
before = snap(LANES)
o = msg("a-default", nil, "ack", ID)
T:arm("12 surface: capabilities lists msg, the forge-plan probe sees it, msg ack is unknown and changes nothing", has("\n" .. caps, "\nmsg\n") and probe.code == 0
    and o.first == "refused:msg:unknown-verb:ack" and o.rc == 1 and o.afforded and snap(LANES) == before, "probe=" .. tostring(probe.code) .. " " .. o.raw)
T:finish({ ok = function(n) return "ok:fleet-msg-store:" .. n .. "/" .. n end })
