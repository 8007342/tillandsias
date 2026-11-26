-- @env PATH HOME CARGO_TARGET_DIR TILLANDSIAS_MSG_SERVE_BIN TILLANDSIAS_PLAN_BIN
-- @trace order:1506-q7ab, order:2387-b6v2
--
-- test-fleet-msg-same-host.lua — the fleet message bus's SAME-HOST rung: the REAL
-- `tillandsias --msg-serve` (the resident mover) and the REAL `tillandsias-plan msg` CLI over a
-- scratch store (TILLANDSIAS_MSG_ROOT), scratch HOME, XDG dirs and wake socket. No container, no
-- network, nothing under the real $HOME. Ported from the .sh of the same name (2387-b6v2).
--
--   1 ack       a->b: a's status reads acked:<host>/b-default@<ts> + via:local with no recv in b
--   2 mount     an envelope in a's outbox claiming from b lands in a's dead/, from-lane-mismatch
--               logged, b byte-identical, status undelivered:refused:from-lane-mismatch
--   3 secret    hvs.+24 refused at `msg send` AND, written straight into outbox/new, by the mover
--   4 reply     a reply to a broadcast refused at `msg send` AND by the mover
--   5 ttl       a --ttl 60 message acked into b is gone from b's inbox 61 s after the send
--   6 wake      recv --wait in c-default returns within 2 s of a delivery
--   7 wildcard  host -> @<host>/* reaches a and b (not the sender) with two acked lines
--   8 plain     an outbox/new symlinked onto b's inbox is refused:msg:lane-not-plain, b untouched
--   9 leak      the recorded pid is the server, it holds no caller fd 9, none is left after the stop
--   NEG-LAX     TILLANDSIAS_MSG_MOVER_LAX=1 makes arm 3's direct-write predicate fail (delivered)
--   NEG-FSYNC   TILLANDSIAS_MSG_SKIP_FSYNC=1 makes arm 1 fail: receipt pending, ack-without-fsync
--   GUARD       the LAX seam without an explicit TILLANDSIAS_MSG_ROOT is ignored
--
-- The mover is a proc.spawn handle whose shell writes its pid and then execs the binary (so the
-- pid IS the server), closing the fd 9 that stands for a caller's lock; it is killed by its
-- handle at the end, also on a refusal. Arm 5 waits in real time: about 65 s after the build.
-- TILLANDSIAS_MSG_SERVE_BIN / TILLANDSIAS_PLAN_BIN run another pair (a pre-1506-q7ab tillandsias
-- fails every arm: "--msg-serve is an unknown flag").
--
-- Usage: tillandsias-plan script run scripts/lua/test-fleet-msg-same-host.lua
-- Verdict: ok:fleet-msg-same-host:<n> arms | violation:... | skip:...:no-cargo, no-linker

local fixture = require "common.fixture"
local T = fixture.new("fleet-msg-same-host")
local SH = fixture.posix_shell()
local BIN, PLAN = env.get("TILLANDSIAS_MSG_SERVE_BIN") or "", env.get("TILLANDSIAS_PLAN_BIN") or ""
if BIN == "" then
    local C = require("common.cargotest").new(T)
    BIN = C:build("tillandsias-headless", "tillandsias")
    if PLAN == "" then PLAN = C:build("tillandsias-plan", "tillandsias-plan") end
elseif PLAN == "" then
    T:refuse("setup-failed", "TILLANDSIAS_MSG_SERVE_BIN set without TILLANDSIAS_PLAN_BIN")
end

local w = T:short_scratch()
local W, WR = w.abs, w.rel
local H = "fixturehost"
local S = W .. "/store"
local WAKE = W .. "/run/tillandsias/msg.sock"
local LANES, LR = S .. "/lanes", WR .. "/store/lanes"
T:must{ "mkdir", "-p", W .. "/home", W .. "/state", W .. "/run", W .. "/fleet" }
T:must{ "chmod", "700", W .. "/run" }
local BODY = "FYI:1506-q7ab:same-host fixture\n- scripts/test-fleet-msg-same-host.sh"
local SECRET_BODY = "FYI:creds:leak\n- 1506-q7ab hvs." .. string.rep("a", 24)

local mover_h
local refuse = T.refuse
function T:refuse(...)
    if mover_h then pcall(function() mover_h:kill() end); mover_h = nil end
    return refuse(self, ...)
end

local function sleep(s) T:run{ "sleep", tostring(s) } end
local function lines(s)
    local l = {}
    for x in (s or ""):gsub("\r", ""):gmatch("[^\n]+") do l[#l + 1] = x end
    return l
end
local function exists(p) return T:run{ "test", "-e", p }.code == 0 end
local function isfile(p) return T:run{ "test", "-f", p }.code == 0 end
local function empty(p) return text.trim(T:run{ "ls", "-A", p }.stdout or "") == "" end
local function ls(p) return text.trim(T:run{ "ls", p }.stdout or "") end

-- m(lane, args, stdin, store): the CLI against the store; {out=, err=, rc=}.
local function m(lane, args, stdin, store)
    local a = { PLAN, "msg" }
    for _, v in ipairs(args) do a[#a + 1] = v end
    local r = proc.run{ argv = a, stdin = stdin and (stdin .. "\n") or "", timeout_ms = 60000,
        env_unset = { "TILLANDSIAS_*" },
        env = { HOME = W .. "/home", XDG_STATE_HOME = W .. "/state", XDG_RUNTIME_DIR = W .. "/run",
            TILLANDSIAS_MSG_ROOT = store or S, TILLANDSIAS_MSG_HOST = H, TILLANDSIAS_MSG_WAKE_SOCK = WAKE,
            TILLANDSIAS_MSG_FORGE_MOUNT = W .. "/no-forge-mount", TILLANDSIAS_MSG_FLEET_DIR = W .. "/fleet",
            TILLANDSIAS_MSG_LANE = lane } }
    local o = text.trim((r.stdout or ""):gsub("\r", ""))
    return { out = o, err = (r.stderr or ""):gsub("\r", ""), rc = r.code }
end
local function mover_env(extra)
    local e = { HOME = W .. "/home", XDG_STATE_HOME = W .. "/state", XDG_RUNTIME_DIR = W .. "/run",
        TILLANDSIAS_MSG_HOST = H, TILLANDSIAS_MSG_POLL_MS = "100", TILLANDSIAS_MSG_SWEEP_MS = "250" }
    for k, v in pairs(extra or {}) do e[k] = v end
    return e
end
-- One pass of the mover; returns its stderr.
local function once(extra)
    local r = proc.run{ argv = { BIN, "--msg-serve", "--once" }, env_unset = { "TILLANDSIAS_*" },
        env = mover_env(extra), timeout_ms = 60000 }
    return ((r.stdout or "") .. (r.stderr or "")):gsub("\r", "")
end
local function qid(x) return (x.out:gsub("^ok:msg:queued:", "")) end
local function snap(dir)
    return T:run{ SH, "-s", "--", dir, stdin = '[ -d "$1" ] || exit 0\ncd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf "%s " "$f"; cksum <"$f"; done\n' }.stdout or ""
end
local function wait_for(tenths, f)
    for _ = 1, tenths do
        if f() then return true end
        sleep(0.1)
    end
    return f()
end
local function log() return fs.exists(WR .. "/mover.log") and fs.read(WR .. "/mover.log") or "" end
local function acked_by(lane, id, box) return text.contains(m(lane, { "status", id }).out, "acked:" .. box .. "@") end
-- An envelope written STRAIGHT into outbox/new (tmp then mv), bypassing the CLI.
local function put(st, lane, id, from, to, body, extra)
    local d = st .. "/lanes/" .. lane .. "/outbox"
    T:must{ "mkdir", "-p", d .. "/tmp", d .. "/new" }
    local ts = text.trim(T:run{ "date", "-u", "+%Y-%m-%dT%H:%M:%SZ" }.stdout or "")
    local y = "id: " .. id .. "\nfrom: " .. from .. "\nto:\n- " .. to .. "\nfrom_agent: fixture\nseq: 0\nts: " .. ts
        .. "\nttl_s: 3600\nbroadcast: false\nkind: FYI\n" .. (extra and (extra .. "\n") or "") .. "body: |-\n"
    for l in (body .. "\n"):gmatch("([^\n]*)\n") do y = y .. "  " .. l .. "\n" end
    local rel = d:sub(#W + 2)
    fs.write(WR .. "/" .. rel .. "/tmp/." .. id, y)
    T:must{ "mv", d .. "/tmp/." .. id, d .. "/new/" .. id }
end

-- ── pre-fix probe ──
if text.contains(once{ TILLANDSIAS_MSG_ROOT = W .. "/probe" }, "Unsupported option") then
    T:arm("every arm — --msg-serve is an unknown flag in " .. BIN .. " (pre-fix)", false, "pre-fix binary")
    T:finish()
end

-- ── the resident ──
T:must{ "mkdir", "-p", LANES .. "/a-default", LANES .. "/b-default" }
mover_h = proc.spawn{ argv = { SH, "-s", "--", BIN, W },
    stdin = 'exec 9>"$2/caller-lock"\nprintf "%s\\n" "$$" >"$2/mover.pid"\nexec "$1" --msg-serve >"$2/mover.out" 2>"$2/mover.log" 9>&- </dev/null\n',
    env_unset = { "TILLANDSIAS_*" }, env = mover_env{ TILLANDSIAS_MSG_ROOT = S, TILLANDSIAS_MSG_WAKE_SOCK = WAKE },
    timeout_ms = 900000 }
if not wait_for(100, function() return T:run{ "test", "-S", WAKE }.code == 0 end) then
    T:refuse("setup-failed", "the mover never bound its wake socket: " .. log())
end
local SPID = text.trim(fs.read(WR .. "/mover.pid"))

-- ── arm 5, first half ──
local x = m("a-default", { "send", "--to", H .. "/b-default", "--ttl", "60" }, BODY)
local TTL_ID, TTL_T0 = qid(x), time.now_ms()
local ttl_acked = wait_for(50, function() return acked_by("a-default", TTL_ID, H .. "/b-default") end)

-- ── arm 1 ──
local A1 = qid(m("a-default", { "send", "--to", H .. "/b-default" }, BODY))
wait_for(50, function() return acked_by("a-default", A1, H .. "/b-default") end)
x = m("a-default", { "status", A1 })
local l = lines(x.out)
T:arm("1 ack: acked:" .. H .. "/b-default@<ts> + via:local with NO recv run in b-default",
    x.rc == 0 and text.contains(l[1] or "", "acked:" .. H .. "/b-default@") and l[2] == "via:local"
    and isfile(LANES .. "/b-default/inbox/new/" .. A1) and empty(LANES .. "/b-default/inbox/cur")
    and not exists(LANES .. "/b-default/recv-state"),
    "status=[" .. x.out .. "] rc=" .. tostring(x.rc) .. " b_new=[" .. ls(LANES .. "/b-default/inbox/new") .. "]")

-- ── arm 2 ──
local b_before = snap(LANES .. "/b-default")
put(S, "a-default", "m-fixture-liar", H .. "/b-default", H .. "/b-default", BODY)
wait_for(50, function() return isfile(LANES .. "/a-default/dead/m-fixture-liar") end)
sleep(0.5)
x = m("a-default", { "status", "m-fixture-liar" })
T:arm("2 mount: a lane claiming b-default is refused:msg:from-lane-mismatch to its own dead/, b-default untouched",
    isfile(LANES .. "/a-default/dead/m-fixture-liar") and text.contains(log(), "refused:msg:from-lane-mismatch:m-fixture-liar")
    and b_before == snap(LANES .. "/b-default") and x.out == "undelivered:refused:from-lane-mismatch", "status=[" .. x.out .. "]")

-- ── arm 3 ──
local function secret_direct(st, id, logtext)
    return isfile(st .. "/lanes/a-default/dead/" .. id) and not exists(st .. "/lanes/b-default/inbox/new/" .. id)
        and text.contains(logtext, "refused:msg:secret-shaped:vault-token:" .. id)
end
x = m("a-default", { "send", "--to", H .. "/b-default" }, SECRET_BODY)
local cli_ok = lines(x.err)[1] == "refused:msg:secret-shaped:vault-token" and x.rc == 1
put(S, "a-default", "m-fixture-secret", H .. "/a-default", H .. "/b-default", SECRET_BODY)
wait_for(50, function() return isfile(LANES .. "/a-default/dead/m-fixture-secret") end)
x = m("a-default", { "status", "m-fixture-secret" })
T:arm("3 secret: hvs.+24 refused at msg send AND, written straight into outbox/new, by the mover",
    cli_ok and secret_direct(S, "m-fixture-secret", log()) and x.out == "undelivered:refused:secret-shaped:vault-token",
    "cli=" .. tostring(cli_ok) .. " status=[" .. x.out .. "]")

-- ── arm 7 ──
local BID = qid(m("host", { "send", "--to", "@" .. H .. "/*" }, BODY))
wait_for(50, function() return acked_by("host", BID, H .. "/b-default") end)
wait_for(50, function() return acked_by("host", BID, H .. "/a-default") end)
x = m("host", { "status", BID })
local n_acked = 0
for _, s in ipairs(lines(x.out)) do if s:find("^acked:") then n_acked = n_acked + 1 end end
T:arm("7 wildcard: @" .. H .. "/* reached a-default and b-default with two acked lines (broadcast:2)",
    lines(x.out)[1] == "broadcast:2" and text.contains(x.out, "acked:" .. H .. "/a-default@") and text.contains(x.out, "acked:" .. H .. "/b-default@")
    and n_acked == 2 and isfile(LANES .. "/a-default/inbox/new/" .. BID) and isfile(LANES .. "/b-default/inbox/new/" .. BID)
    and not exists(LANES .. "/host/inbox/new/" .. BID), "status=[" .. x.out .. "]")

-- ── arm 4 ──
x = m("b-default", { "send", "--to", H .. "/host", "--in-reply-to", BID }, BODY)
cli_ok = text.contains(lines(x.err)[1] or "", "refused:msg:reply-to-broadcast:" .. BID) and x.rc == 1
put(S, "b-default", "m-fixture-reply", H .. "/b-default", H .. "/host", BODY, "in_reply_to: " .. BID)
wait_for(50, function() return isfile(LANES .. "/b-default/dead/m-fixture-reply") end)
x = m("b-default", { "status", "m-fixture-reply" })
T:arm("4 reply: a reply to a broadcast is refused at msg send AND, written straight into an outbox, by the mover",
    cli_ok and isfile(LANES .. "/b-default/dead/m-fixture-reply") and not exists(LANES .. "/host/inbox/new/m-fixture-reply")
    and text.contains(log(), "refused:msg:reply-to-broadcast:" .. BID .. ":m-fixture-reply")
    and x.out == "undelivered:refused:reply-to-broadcast", "cli=" .. tostring(cli_ok) .. " status=[" .. x.out .. "]")

-- ── arm 6 ──
T:must{ "mkdir", "-p", LANES .. "/c-default" }
sleep(0.5)
local recv = proc.spawn{ argv = { PLAN, "msg", "recv", "--wait", "20" }, stdin = "", timeout_ms = 60000,
    env_unset = { "TILLANDSIAS_*" },
    env = { HOME = W .. "/home", XDG_STATE_HOME = W .. "/state", XDG_RUNTIME_DIR = W .. "/run",
        TILLANDSIAS_MSG_ROOT = S, TILLANDSIAS_MSG_HOST = H, TILLANDSIAS_MSG_WAKE_SOCK = WAKE,
        TILLANDSIAS_MSG_FORGE_MOUNT = W .. "/no-forge-mount", TILLANDSIAS_MSG_FLEET_DIR = W .. "/fleet",
        TILLANDSIAS_MSG_LANE = "c-default" } }
sleep(1)
local w0 = time.now_ms()
local W_ID = qid(m("a-default", { "send", "--to", H .. "/c-default" }, BODY))
local rr = recv:wait()
local el = time.now_ms() - w0
-- The .sh measured whole seconds (date +%s), so <= 2 there is < 3000 ms here at most; keep 2 s.
T:arm("6 wake: recv --wait returned within 2 s of the send, printing the message",
    text.contains(rr.stdout or "", "msg:" .. W_ID .. " ") and el <= 2000, "elapsed_ms=" .. el .. " recv=[" .. tostring(rr.stdout) .. "]")

-- ── arm 8 ──
b_before = snap(LANES .. "/b-default")
T:must{ "mkdir", "-p", LANES .. "/d-default/outbox" }
T:must{ "ln", "-s", "../../b-default/inbox/new", LANES .. "/d-default/outbox/new" }
wait_for(50, function() return text.contains(log(), "refused:msg:lane-not-plain:d-default") end)
sleep(0.5)
T:arm("8 plain: an outbox symlinked onto b-default's inbox is refused:msg:lane-not-plain; b's mail unread and unmoved",
    text.contains(log(), "refused:msg:lane-not-plain:d-default") and b_before == snap(LANES .. "/b-default")
    and empty(LANES .. "/d-default/dead"), "d_dead=[" .. ls(LANES .. "/d-default/dead") .. "]")
T:must{ "rm", "-rf", LANES .. "/d-default" }

-- ── controls ──
local S2 = W .. "/store-lax"
T:must{ "mkdir", "-p", S2 .. "/lanes/a-default", S2 .. "/lanes/b-default" }
put(S2, "a-default", "m-fixture-secret", H .. "/a-default", H .. "/b-default", SECRET_BODY)
local laxlog = once{ TILLANDSIAS_MSG_ROOT = S2, TILLANDSIAS_MSG_MOVER_LAX = "1" }
T:arm("NEG-LAX: with the mover's second check off, arm 3's direct write is DELIVERED (the arm fails)",
    not secret_direct(S2, "m-fixture-secret", laxlog) and isfile(S2 .. "/lanes/b-default/inbox/new/m-fixture-secret"), laxlog:sub(1, 300))

local S3 = W .. "/store-nofsync"
T:must{ "mkdir", "-p", S3 .. "/lanes/a-default", S3 .. "/lanes/b-default" }
local F_ID = qid(m("a-default", { "send", "--to", H .. "/b-default" }, BODY, S3))
local fslog = once{ TILLANDSIAS_MSG_ROOT = S3, TILLANDSIAS_MSG_SKIP_FSYNC = "1" }
x = m("a-default", { "status", F_ID }, nil, S3)
T:arm("NEG-FSYNC: with fsync skipped the receipt stays pending and the mover says why (arm 1 fails)",
    x.out == "pending" and text.contains(fslog, "refused:msg:ack-without-fsync:" .. F_ID), "status=[" .. x.out .. "]")

local S4 = W .. "/state/tillandsias/msg"
T:must{ "mkdir", "-p", S4 .. "/lanes/a-default", S4 .. "/lanes/b-default" }
put(S4, "a-default", "m-fixture-secret", H .. "/a-default", H .. "/b-default", SECRET_BODY)
local glog = once{ TILLANDSIAS_MSG_MOVER_LAX = "1" }
T:arm("GUARD: without an explicit TILLANDSIAS_MSG_ROOT the LAX seam is ignored and the secret is refused",
    secret_direct(S4, "m-fixture-secret", glog), glog:sub(1, 300))

-- ── arm 5, second half ──
while time.now_ms() < TTL_T0 + 61000 do sleep(0.5) end
x = m("a-default", { "status", TTL_ID })
T:arm("5 ttl: the --ttl 60 message acked into b-default is gone from its inbox 61 s later; the sender still reads acked:",
    ttl_acked and not exists(LANES .. "/b-default/inbox/new/" .. TTL_ID) and not exists(LANES .. "/b-default/inbox/cur/" .. TTL_ID)
    and text.contains(lines(x.out)[1] or "", "acked:" .. H .. "/b-default@"), "acked_first=" .. tostring(ttl_acked) .. " status=[" .. x.out .. "]")

-- ── arm 9 ──
local sargs = T:run{ "ps", "-o", "args=", "-p", SPID }.stdout or ""
local held = T:run{ SH, "-s", "--", SPID, W .. "/caller-lock", stdin = 'for l in /proc/"$1"/fd/*; do [ "$(readlink "$l")" = "$2" ] && echo y; done; exit 0\n' }.stdout or ""
mover_h:kill(); mover_h = nil
local alive = T:run{ "kill", "-0", SPID }.code == 0
local left = T:run{ SH, "-s", "--", "HOME=" .. W .. "/home", stdin = '[ -d /proc/self ] || exit 0\nfor e in /proc/[0-9]*/environ; do tr "\\0" "\\n" <"$e" 2>/dev/null | grep -qxF "$1" && printf " %s" "${e%/environ}"; done 2>/dev/null; exit 0\n' }.stdout or ""
T:arm("9 leak: the recorded pid is the server, it held no caller fd 9, and none is left under the throwaway HOME",
    text.contains(sargs, "--msg-serve") and text.trim(held) == "" and not alive and text.trim(left) == "",
    "args=[" .. text.trim(sargs) .. "] fd9_held=[" .. text.trim(held) .. "] alive=" .. tostring(alive) .. " left=[" .. left .. "]")

if #T.failed > 0 then out.line("--- mover log ---"); out.line(log():sub(-3000)) end
T:finish()
