-- @env PATH HOME
-- @trace order:1443-w9hf, order:1443-we89, spec:command-policies, order:2311-xca3
--
-- test-command-policy-audit.lua — every policy decision lands in the per-host audit log with
-- token-shaped literals redacted, and `policy audit` summarises it. Ported from the .sh of the
-- same name (2311-xca3). HOME is scratch and the cwd a scratch repo without
-- scripts/metrics-log-path.sh, so the log is $HOME/.cache/tillandsias/metrics/…; the
-- checkout's own audit is never written.
--
--   1 a denied `gh auth token` is audited: rule, program, sha256 argv_digest
--   2 a token is <redacted:token> and appears nowhere; AWS key ids and PEM blocks likewise
--   3 `policy audit --since` prints one line per (rule_id, decision), a total, and empty
--     when there is no log or nothing recent
--   4 NEGATIVE CONTROL: a hundred evaluations do not grow the timing log
--   5 the Bash-tool bridge writes to the SAME audit, with no raw command
--
-- Usage: tillandsias-plan script run scripts/lua/test-command-policy-audit.lua
-- Verdict: ok:command-policy-audit:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("command-policy-audit")
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end
local home, cwd = T:scratch("home"), T:git_repo("cwd")
local LOG = home.rel .. "/.cache/tillandsias/metrics/command-policy-audit.jsonl"
fs.write(home.rel .. "/timing.jsonl", "")

local function policy(args, stdin, timing)
    local argv = { PLAN, "policy" }
    for _, x in ipairs(args) do argv[#argv + 1] = x end
    local r = proc.run{ argv = argv, cwd = cwd.abs, stdin = stdin, timeout_ms = 60000, env = { PATH = env.get("PATH"), HOME = home.abs,
        TILLANDSIAS_POLICY_AUDIT_LOG = "", TILLANDSIAS_POLICY_AUDIT = "", TILLANDSIAS_TIMING_LOG = timing or "" } }
    return r.code, text.trim(r.stdout or ""), r.stderr or ""
end
local function log() return fs.exists(LOG) and fs.read(LOG) or "" end
local function rows()
    local t = {}
    for l in log():gmatch("[^\r\n]+") do t[#t + 1] = l end
    return t
end
local function last()
    local t = rows()
    local ok, v = pcall(json.parse, t[#t] or "")
    return ok and type(v) == "table" and v or {}, t[#t] or ""
end

local rc, o, e = policy{ "audit", "--since", "24h" }
T:arm("3a with no log policy audit is ok:policy-audit:empty", rc == 0 and o == "ok:policy-audit:empty" and log() == "", tostring(rc) .. " " .. o)

policy{ "eval", "--", "gh", "auth", "token" }
local v, raw = last()
T:arm("1 a denied gh auth token is audited with rule, program and sha256 digest",
    v.decision == "deny" and v.rule_id == "no-credential-mutation" and v.program == "gh"
    and type(v.argv_digest) == "string" and #v.argv_digest == 64 and not v.argv_digest:find("[^0-9a-f]"), raw)

-- Split, so no scanner reads these as credentials in the source.
local TOKEN = "gh" .. "p_" .. "abcdefghijklmnopqrstuvwxyz0123456789"
local AKID, KEYBODY, DASH = "AKIA" .. "ABCDEFGHIJKLMNOP", "b3BlbnNzaC1r" .. "ZXktdjEAAAAA", "-----"
rc, o, e = policy{ "eval", "--", "curl", "-H", "Authorization: token " .. TOKEN }
v, raw = last()
T:arm("2a a token is redacted in the log and absent from the log and the output", text.contains(raw, "<redacted:token>")
    and not text.contains(log() .. o .. e, "gh" .. "p_"), o .. " " .. raw)
policy{ "eval", "--", "aws", "configure", "set", "aws_access_key_id", AKID }
local n_aws = #rows()
policy{ "eval", "--", "printf", "%s", DASH .. "BEGIN OPENSSH PRIVATE KEY" .. DASH .. "\n" .. KEYBODY .. "\n" .. DASH .. "END OPENSSH PRIVATE KEY" .. DASH }
v, raw = last()
T:arm("2b AWS key ids and PEM blocks are redacted too", n_aws == 3 and #rows() == 4 and not text.contains(log(), AKID)
    and not text.contains(log(), KEYBODY) and text.contains(raw, "<redacted:pem>"), n_aws .. " " .. raw)

rc, o = policy{ "audit", "--since", "24h" }
local lines = "\n" .. o:gsub("\r", "") .. "\n"
T:arm("3b the summary is one line per (rule_id, decision) and a total", rc == 0 and text.contains(lines, "\n1 no-credential-mutation deny\n")
    and lines:find("\n%d+ default allow\n") ~= nil and text.contains(lines, "\ntotal=" .. #rows() .. "\n"), tostring(rc) .. " " .. o .. " rows=" .. #rows())
T:must{ "sleep", "2" }
rc, o = policy{ "audit", "--since", "1s" }
T:arm("3c --since excludes older decisions", rc == 0 and o == "ok:policy-audit:empty", o)

local n = #rows()
for _ = 1, 100 do policy({ "eval", "--", "git", "status" }, nil, home.abs .. "/timing.jsonl") end
T:arm("4 CONTROL a hundred evaluations grow the audit by a hundred and leave the timing log empty",
    #rows() == n + 100 and fs.read(home.rel .. "/timing.jsonl") == "", n .. "->" .. #rows() .. " timing=" .. #fs.read(home.rel .. "/timing.jsonl"))

policy({ "classify-bash", "--hook" }, json.encode{ tool_name = "Bash", cwd = cwd.abs, tool_input = { command = "gh auth refresh --token " .. TOKEN } })
v, raw = last()
T:arm("5a the Bash-tool bridge audits as pretooluse, digest only", v.caller == "pretooluse" and v.decision == "deny"
    and text.contains(raw, '"argv_shown":null') and not text.contains(log(), "gh" .. "p_"), raw)
rc, o = policy{ "classify-bash", "--status" }
T:arm("5b the bridge's --status counts only its own decisions", o:find("^decisions=1/0/0 ") ~= nil, o)
T:finish()
