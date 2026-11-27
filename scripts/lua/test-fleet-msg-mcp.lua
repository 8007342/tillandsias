-- @env PATH
-- @trace order:1506-ssb5, order:1746-4q34, order:2368-efqj, openspec/changes/fleet-messaging-poc/specs/fleet-messaging/spec.md
--
-- test-fleet-msg-mcp.lua — the fleet message bus's MCP surface: forge-plan.sh's msg_send,
-- msg_recv, msg_list and msg_status, and the Codex and OpenCode entrypoints' pending-mail
-- line. Ported from the .sh (2368-efqj), whose bash-4 coproc was a syntax error on macOS.
--
--   1 surface     tools/list carries the four and NO msg_ack (operator ruling 2026-09-29)
--   2 round-trip  msg_send prints the receipt id at once; msg_status reads pending, then
--                 acked:<host>/<lane>@<ts> + via:local from a fixture-written receipt
--   3 secret      NEGATIVE: a secret-shaped body is refused with why and remedy, and the
--                 outbox is unchanged
--   4 degraded    a binary whose capabilities omit msg: every msg tool answers
--                 confidence=unsupported, never a fake success
--   5 argv        the body never reaches argv: every "$body" in msg_send_tool is the stdin
--                 pipe, and the dispatch case emits no --body or -m
--   6, 7          the Codex and OpenCode entrypoints print the pending count and leave the
--                 inbox untouched
--   8 protocol    msg_send with no `to` is a JSON-RPC -32602, not a tool result
--   9 late-binary ONE server started before the binary exists answers degraded, then queues
--                 once it is installed (1746-4q34). One process, two requests, two fifos:
--                 a fresh server per request could never see a stale path
--
-- Verdict: ok:fleet-msg-mcp:<n>/<n> | violation:fleet-msg-mcp:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("fleet-msg-mcp")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end
local FP = "images/default/config-overlay/mcp/forge-plan.sh"
local W = T:scratch()
local H = "fixturehost"
local OUTBOX = W.rel .. "/state/tillandsias/msg/lanes/a-default/outbox"
for _, p in ipairs{ "home", "fleet", "bin" } do fs.mkdir(W.rel .. "/" .. p) end
T:must{ "ln", "-sf", PLAN, W.abs .. "/bin/tillandsias-plan" }
local NOW = text.trim(T:must{ "date", "-u", "+%Y-%m-%dT%H:%M:%SZ" }.stdout)
local DROP = { "TILLANDSIAS_*", "CARGO_TARGET_DIR", "GIT_*" }

-- The message env of one hermetic lane under `dir`.
local function lane(dir, name, extra)
    local e = { HOME = W.abs .. "/home", XDG_STATE_HOME = dir .. "/state", TILLANDSIAS_MSG_HOST = H, TILLANDSIAS_MSG_LANE = name,
        TILLANDSIAS_MSG_FORGE_MOUNT = dir .. "/no-forge-mount", TILLANDSIAS_MSG_FLEET_DIR = dir .. "/fleet" }
    for k, v in pairs(extra or {}) do e[k] = v end
    return e
end
local function parse(s) local ok, v = pcall(json.parse, s or ""); return ok and type(v) == "table" and v or {} end
local function rpc(req, e)
    local r = T:run{ SH, FP, cwd = ROOT, stdin = req .. "\n", timeout_ms = 120000, env_unset = DROP,
        env = e or lane(W.abs, "a-default", { TILLANDSIAS_PLAN_BIN = PLAN, TILLANDSIAS_PLAN_INDEX = ROOT .. "/plan/index.yaml" }) }
    return parse(text.trim(r.stdout or "")), (r.stdout or "") .. (r.stderr or "")
end
local function request(tool, args) return '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"' .. tool .. '","arguments":' .. args .. "}}" end
local function content(v) local c = v.result and v.result.content; return c and c[1] and c[1].text or "" end
local function call(tool, args, e) local v, raw = rpc(request(tool, args), e); return content(v), v, raw end
local function has(o, s) return o:find(s, 1, true) ~= nil end
local function send(body) return call("msg_send", '{"to":["' .. H .. '/b-default"],"body":' .. json.encode(body) .. "}") end

-- 1
local v, raw = rpc('{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
local names = {}
for _, t in ipairs((v.result or {}).tools or {}) do names[t.name] = true end
T:arm("1 surface: the four msg tools, and no msg_ack", names.msg_send and names.msg_recv and names.msg_list and names.msg_status and not names.msg_ack, raw:sub(1, 300))

-- 2
local got = send("FYI:1506-ssb5:mcp round trip\n- 1506-ssb5")
local id = got:match("^ok:msg:queued:(m%-%S+)$")
local s1, s2 = "", ""
if id then
    s1 = call("msg_status", '{"id":"' .. id .. '"}')
    fs.write(W.rel .. "/state/tillandsias/msg/lanes/a-default/receipts/" .. id, "id: " .. id .. "\nfrom: " .. H .. "/a-default\nts: " .. NOW
        .. "\nttl_s: 86400\nbroadcast: false\nrecipients:\n- to: " .. H .. "/b-default\n  state: acked\n  at: " .. NOW .. "\n  via: local\n")
    s2 = call("msg_status", '{"id":"' .. id .. '"}')
end
T:arm("2 round-trip: queued at once, pending, then acked via local", id and s1 == "pending" and s2 == "acked:" .. H .. "/b-default@" .. NOW .. "\nvia:local",
    "send=[" .. got .. "] " .. s1 .. " / " .. s2)

-- 3
local function snap(dir)
    local t = {}
    if fs.exists(dir) then
        for _, p in ipairs(fs.walk(dir)) do t[#t + 1] = tostring(p) .. "=" .. (pcall(fs.read, tostring(p)) and fs.read(tostring(p)) or "dir") end
    end
    table.sort(t)
    return table.concat(t, "\n")
end
local before = snap(OUTBOX)
got = send("FYI:creds:leak\n- 1506-ssb5 " .. "ghp_" .. ("a"):rep(36))
T:arm("3 secret: NEGATIVE refused with why and remedy, nothing written", has(got, "refused:msg:secret-shaped:github-token") and has(got, "why:") and has(got, "remedy:")
    and before ~= "" and snap(OUTBOX) == before, got)

-- 4
fs.write(W.rel .. "/bin/stub-plan", "#!/usr/bin/env bash\ncase \"${1:-}\" in\n    capabilities) printf 'answer\\ncheck\\nstatus\\n' ;;\n    *) exit 1 ;;\nesac\n")
T:must{ "chmod", "+x", W.abs .. "/bin/stub-plan" }
local bad = {}
for tool, args in pairs{ msg_send = '{"to":["h/b"],"body":"FYI:x:y"}', msg_recv = "{}", msg_list = "{}", msg_status = '{"id":"m-x"}' } do
    local t = call(tool, args, lane(W.abs, "a-default", { TILLANDSIAS_PLAN_BIN = W.abs .. "/bin/stub-plan", TILLANDSIAS_PLAN_INDEX = ROOT .. "/plan/index.yaml" }))
    if parse(t).confidence ~= "unsupported" then bad[#bad + 1] = tool .. "=[" .. t .. "]" end
end
T:arm("4 degraded: without the msg capability every msg tool answers confidence=unsupported", #bad == 0, table.concat(bad, " "))

-- 5
local src = fs.read(FP)
local fn = src:match("\n(msg_send_tool%(%) {\n.-\n}\n)") or ""
local case = src:match('\n                "msg_send"%)\n(.-)\n                    ;;\n') or ""
local _, refs = fn:gsub('"%$body"', "")
local _, pipes = fn:gsub("printf '%%s' \"%$body\" |", "")
T:arm("5 argv: every $body in msg_send_tool is the stdin pipe, and the dispatch emits no --body or -m",
    fn ~= "" and case ~= "" and refs > 0 and refs == pipes and not has(case, "--body") and not (" " .. case):find("[^-]%-m "), "refs=" .. refs .. " pipes=" .. pipes .. " case=" .. #case)

-- 6, 7
for i, who in ipairs{ "codex", "opencode" } do
    local dir = W.abs .. "/entry-" .. who
    local box = W.rel .. "/entry-" .. who .. "/state/tillandsias/msg/lanes/b-default/inbox"
    fs.mkdir(box .. "/new"); fs.mkdir(box .. "/cur")
    fs.write(box .. "/new/m-fixture-1", "id: m-fixture-1\nfrom: yoga/host\nto:\n- " .. H .. "/b-default\nfrom_agent: fixture\nseq: 1\nts: " .. NOW
        .. "\nttl_s: 86400\nbroadcast: false\nkind: FYI\nbody: 'FYI:test:hello'\n")
    local r = T:run{ SH, "images/default/entrypoint-forge-" .. who .. ".sh", cwd = ROOT, env_unset = DROP,
        env = lane(dir, "b-default", { PATH = W.abs .. "/bin:" .. env.get("PATH"), TILLANDSIAS_FORGE_MSG_DRY_RUN = "1" }) }
    local o = (r.stdout or "") .. (r.stderr or "")
    T:arm((5 + i) .. " " .. who .. ": the entrypoint prints the pending count and the inbox is untouched", r.code == 0 and has(o, "1 pending message(s)") and fs.exists(box .. "/new/m-fixture-1"),
        "rc=" .. tostring(r.code) .. " " .. o)
end

-- 8
local _, v8, raw8 = call("msg_send", '{"body":"FYI:x:y"}')
T:arm("8 protocol: msg_send with no `to` is -32602, not a tool result", v8.error and v8.error.code == -32602 and v8.result == nil, raw8)

-- 9: the canonical install is created between the two requests, outside any checkout.
local pre = {}
for _, p in ipairs{ "/usr/local/bin/tillandsias-plan", "/usr/bin/tillandsias-plan" } do if T:run{ "test", "-e", p }.code == 0 then pre[#pre + 1] = p end end
if #pre > 0 then
    T:arm("9 late-binary", false, "could-not-run: a system tillandsias-plan exists (" .. table.concat(pre, " ") .. "), so no server can start without one")
else
    fs.mkdir(W.rel .. "/late/home"); fs.mkdir(W.rel .. "/late/cwd")
    fs.write(W.rel .. "/late/request", request("msg_send", '{"to":["' .. H .. '/b-default"],"body":' .. json.encode("FYI:1746-4q34:late binary\n- 1746-4q34") .. "}") .. "\n")
    local e = lane(W.abs .. "/late", "a-default", { HOME = W.abs .. "/late/home", GIT_CEILING_DIRECTORIES = W.abs .. "/late", FP = ROOT .. "/" .. FP, REAL = PLAN, D = W.abs .. "/late" })
    fs.write(W.rel .. "/late/drive.sh", [[
mkfifo "$D/in" "$D/out" || exit 3
bash "$FP" <"$D/in" >"$D/out" 2>"$D/err" &
server=$!
exec 3>"$D/in" 4<"$D/out"
cat "$D/request" >&3
IFS= read -r -t 60 early <&4
mkdir -p "$HOME/.local/bin" && cp "$REAL" "$HOME/.local/bin/tillandsias-plan"
cat "$D/request" >&3
IFS= read -r -t 60 later <&4
exec 3>&-
kill "$server" 2>/dev/null; wait "$server" 2>/dev/null
printf '%s\n%s\n' "$early" "$later"
]])
    local r = T:run{ SH, W.abs .. "/late/drive.sh", cwd = W.abs .. "/late/cwd", env = e, env_unset = DROP, timeout_ms = 150000 }
    local early, later = (r.stdout or ""):match("^([^\n]*)\n([^\n]*)\n")
    local c1, c2 = parse(content(parse(early))).confidence, content(parse(later))
    T:arm("9 late-binary: degraded while no binary exists, queued once it is installed, in one server", c1 == "unsupported" and c2:find("^ok:msg:queued:m%-"),
        "early=" .. tostring(c1) .. " later=[" .. c2 .. "] rc=" .. tostring(r.code) .. " " .. (r.stderr or ""):sub(1, 300))
end
T:finish({ ok = function(n) return "ok:fleet-msg-mcp:" .. n .. "/" .. n end })
