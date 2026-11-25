-- @env PATH TMPDIR
-- @trace order:1443-r4cj, spec:command-runtime, spec:forge-environment-discoverability, order:2369-8vq3
--
-- test-mcp-run-command-tool.lua — project-info's `run_command`, the MCP door onto `tillandsias-plan run`,
-- driven over stdio: its schema; the verb's own object as the result, audited as caller=mcp; a denial is
-- a RESULT; hostile argv executes nothing; bad params are -32602 and a stale binary -32603.
-- The audit log, the usage log and HOME are scratch. Ported from the .sh of the same name.
--
-- Usage: tillandsias-plan script run scripts/lua/test-mcp-run-command-tool.lua
-- Verdict: ok:mcp-run-command-tool:<n> arms | violation:...:<n>-failed | skip:...:no-jq

local fixture = require "common.fixture"
local T = fixture.new("mcp-run-command-tool")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
local SERVER = "images/default/config-overlay/mcp/project-info.sh"
if not fs.exists(SERVER) then T:refuse("subject-missing") end
if PLAN == "" then T:refuse("no-plan-binary") end
if not fixture.which("jq") then T:skip("no-jq") end -- the server's own dependency
local R = T:git_repo()
local W = T:scratch("home")
fs.write(R.rel .. "/untracked.txt", "")
local AUDIT = W.abs .. "/audit.jsonl"
local function environ(plan)
    return { PATH = env.get("PATH"), HOME = W.abs, TMPDIR = env.get("TMPDIR"), TILLANDSIAS_PLAN_BIN = plan or PLAN, TILLANDSIAS_POLICY_AUDIT_LOG = AUDIT }
end
local function parse(s)
    local ok, j = pcall(json.parse, s or "")
    return ok and type(j) == "table" and j or {}
end
-- A native Windows jq writes CRLF; the server is Linux content. Asked once, so nowhere else forgives a CR.
local probe = T:run{ SH, "-s", stdin = "jq -j '.a' <<<'{\"a\":\"x\\ny\"}'\n", env = { PATH = env.get("PATH") } }
local CRLF_JQ = text.contains(probe.stdout or "", "\r")
local function bytes(s)
    if type(s) == "string" and CRLF_JQ then return (s:gsub("\r", "")) end
    return s
end

-- Each line of requests is answered by one line. o: {server=, plan=}
local function rpc(requests, o)
    o = o or {}
    local r = T:run{ SH, o.server or (ROOT .. "/" .. SERVER), cwd = R.abs, stdin = table.concat(requests, "\n") .. "\n",
        env = environ(o.plan), env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    local answers = {}
    for l in (r.stdout or ""):gmatch("[^\r\n]+") do answers[#answers + 1] = parse(l) end
    return answers, (r.stdout or ""):sub(1, 500) .. " " .. (r.stderr or ""):sub(1, 200)
end
local LIST = '{"jsonrpc":"2.0","id":9,"method":"tools/list"}'
local function request(args)
    return '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"run_command","arguments":' .. args .. "}}"
end
-- The tool's result object, the raw answer and what to print.
local function call(args, o)
    local a, got = rpc({ request(args) }, o)
    local ans = a[1] or {}
    local c = ans.result and ans.result.content and ans.result.content[1]
    return parse(c and c.text), ans, got
end
local function keys(t)
    local k = {}
    for n in pairs(t) do k[#k + 1] = n end
    table.sort(k)
    return table.concat(k, ",")
end

local a, got = rpc{ LIST }
local schema
for _, t in ipairs(a[1] and a[1].result and a[1].result.tools or {}) do if t.name == "run_command" then schema = t.inputSchema end end
T:arm("1 tools/list has run_command with its six parameters, argv required", schema ~= nil
    and keys(schema.properties) == "argv,capture_bytes,cwd,env,stdin,timeout_ms" and #schema.required == 1 and schema.required[1] == "argv"
    and schema.properties.argv.items.type == "string", got)

local obj, ans
obj, ans, got = call('{"argv":["git","status","--porcelain"]}')
local mcp_line = parse((fs.read(W.rel .. "/audit.jsonl"):match("([^\r\n]+)[\r\n]*$")))
local d = T:run{ PLAN, "run", "--json", "--", "git", "status", "--porcelain", cwd = R.abs, env = environ(), env_unset = { "TILLANDSIAS_*" } }
local direct = parse(d.stdout)
local run_line = parse((fs.read(W.rel .. "/audit.jsonl"):match("([^\r\n]+)[\r\n]*$")))
T:arm("2 it returns the object the verb prints", ans.error == nil and keys(obj) ~= "" and keys(obj) == keys(direct) and obj.status == "exited"
    and type(obj.run_id) == "string" and obj.policy and obj.policy.decision == "allow" and obj.stdout == direct.stdout
    and text.trim(obj.stdout or "") == "?? untracked.txt", got)
T:arm("2 audited as caller=mcp, and the direct run as caller=run", mcp_line.caller == "mcp" and mcp_line.program == "git" and run_line.caller == "run",
    tostring(mcp_line.caller) .. "/" .. tostring(run_line.caller))

obj, ans, got = call('{"argv":["gh","auth","token"]}')
T:arm("3 a denial is a result with a why and a remedy, not an error", ans.error == nil and obj.status == "policy_denied" and obj.policy
    and obj.policy.rule_id == "no-credential-mutation" and (obj.policy.why or "") ~= "" and (obj.policy.remedy or "") ~= "", got)

local src = fs.read(SERVER):gsub("\r\n", "\n")
local block = src:match('\n                "run_command"%)\n(.-)\n                    ;;\n') or ""
T:arm("4 the arm has no eval and no bash -c, and argv travels as --argv-json -", block ~= "" and not block:find("eval ", 1, true)
    and not block:find("bash -c", 1, true) and text.contains(block, "--argv-json -"), #block)

local function marks() for i = 1, 3 do if fs.exists(R.rel .. "/MARK" .. i) then return true end end return false end
obj, ans, got = call([[{"argv":["printf","%s|%s|%s","$(touch MARK1)","`touch MARK2`","; touch MARK3 | cat"]}]])
T:arm("5 hostile argv entries arrive literally and execute nothing", obj.stdout == "$(touch MARK1)|`touch MARK2`|; touch MARK3 | cat" and not marks(), got)
obj, ans, got = call([[{"argv":["cat"],"stdin":"line one\n$(x) `y` \"q\""}]])
T:arm("5 stdin arrives byte for byte", bytes(obj.stdout) == 'line one\n$(x) `y` "q"', got)
obj, ans, got = call([[{"argv":["printenv","R4CJ_VALUE"],"env":{"R4CJ_VALUE":"a b\nc"}}]])
T:arm("5 an env value holding a newline arrives intact", bytes(obj.stdout) == "a b\nc\n", got)

obj, ans, got = call('{"argv":["sleep","5"],"timeout_ms":300}')
T:arm("6 a deadline is a result, timed_out with no code", ans.error == nil and obj.status == "timed_out" and type(obj.code) ~= "number", got)
local reqs = {}
for _, p in ipairs{ '{"argv":"git status"}', '{"argv":[]}', '{"argv":["git",1]}', '{"argv":["true"],"env":{"A B":"x"}}',
    '{"argv":["true"],"timeout_ms":-1}', "{}" } do reqs[#reqs + 1] = request(p) end
a, got = rpc(reqs)
local refused = 0
for _, x in ipairs(a) do if x.error and x.error.code == -32602 then refused = refused + 1 end end
T:arm("6 six malformed calls are six -32602", refused == 6 and #a == 6, refused .. " of " .. #a .. " " .. got)
fs.write(W.rel .. "/stale-plan", "#!/bin/sh\n[ \"$1\" = capabilities ] && { echo query; exit 0; }\necho \"error: unknown subcommand 'run'\" >&2\nexit 2\n")
T:must{ SH, "-s", "--", W.abs .. "/stale-plan", stdin = 'chmod +x "$1"\n' }
a, got = rpc({ request('{"argv":["true"]}'), LIST }, { plan = W.abs .. "/stale-plan" })
T:arm("6 a binary without run is -32603 naming it, and the server keeps serving", a[1] and a[1].error and a[1].error.code == -32603
    and text.contains(a[1].error.message, "unknown subcommand 'run'") and a[2] ~= nil and a[2].id == 9, got)

-- MUTATION. The server finds its siblings by its own path, so a mutant runs beside them in a scratch copy.
local M = T:scratch("mutant")
T:must{ SH, "-s", "--", ROOT .. "/images/default/config-overlay/mcp", M.abs, stdin = 'cp -R "$1/." "$2/"\n' }
local function mutant(name, from, to)
    local x, y = src:find(from, 1, true)
    if not x then T:refuse("mutation-anchor-missing", name) end
    fs.write(M.rel .. "/" .. name .. ".sh", src:sub(1, x - 1) .. to .. src:sub(y + 1))
    return { server = M.abs .. "/" .. name .. ".sh" }
end
obj = call('{"argv":["git","status","--porcelain"]}', mutant("nocaller", "run --json --caller mcp", "run --json"))
mcp_line = parse((fs.read(W.rel .. "/audit.jsonl"):match("([^\r\n]+)[\r\n]*$")))
T:arm("7 MUTATION a door that does not name itself fails arm 2's audit", obj.status == "exited" and mcp_line.caller ~= "mcp", tostring(mcp_line.caller))
obj, ans, got = call('{"argv":["true"],"env":{"A B":"x"}}', mutant("anykey", 'test("^[A-Za-z_][A-Za-z0-9_]*$")', "true"))
T:arm("7 MUTATION a door that takes any env key fails arm 6", not (ans.error and ans.error.code == -32602) and (ans.result or ans.error) ~= nil, got)

T:finish()
