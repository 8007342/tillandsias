-- @env PATH HOME
-- @trace order:1443-8pur, order:2371-knda, order:2386-zxgc
--
-- test-run-verb-agent-door.lua — `tillandsias-plan run` is the agent door: an argv (never a command
-- string), the policy before the spawn, an audit line, a reaped process tree, a one-object --json
-- report. Ported from the .sh of the same name (2386-zxgc). Every child is a scratch script or a
-- coreutil; the audit log is scratch.
--
--   1 --json: one object, eleven keys, a code or a signal, never an invented one
--   2 an argument with a space, a quote and * is one entry   3 --argv-json, and what it refuses
--   3a/3b a grandchild holding stdout does not stall the report, and does not outlive the door
--   4 a refusal spawns nothing, is audited without a run_id   5 the child's environment
--   6 --capture-bytes truncates and says so   7 exit codes, stdin, cwd, no command string
--   8 plain form cannot tell a refusal from exit 1; --json can   9 --caller
--
-- Usage: tillandsias-plan script run scripts/lua/test-run-verb-agent-door.lua
-- Verdict: ok:run-verb-agent-door:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("run-verb-agent-door")
local SH, PLAN = fixture.posix_shell(), fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end
local w = T:scratch()
local AUDIT = w.abs .. "/audit.jsonl"
fs.write(w.rel .. "/argc.sh", '#!/bin/sh\nprintf "argc=%s\\n" "$#"\nprintf "argv1=[%s]\\n" "$1"\n')
fs.write(w.rel .. "/keep.sh", "#!/bin/sh\nsleep 30 &\necho started\nexit 0\n")
fs.write(w.rel .. "/detach.sh", "#!/bin/sh\nsleep 30 >/dev/null 2>&1 </dev/null &\necho $!\nexit 0\n")
fs.write(w.rel .. "/self-term.sh", "#!/usr/bin/env bash\nkill -TERM $$\n")
fs.write(w.rel .. "/in.txt", "hello-from-stdin")
T:must{ "chmod", "+x", w.abs .. "/self-term.sh" }
-- The verb, through a shell: the door would judge `bash -c` in this argv itself, before the verb could.
-- more: extra environment, set by the shell (the door gives a child no GH_TOKEN).
-- shell: a command line appended in the shell, for an argv this door would refuse to pass on.
local function run(args, stdin, more, shell)
    local pre = "export TILLANDSIAS_POLICY_AUDIT_LOG='" .. AUDIT .. "'\n" .. (more or "")
    local a = { SH, "-s", "--", PLAN, "run" }
    for _, v in ipairs(args) do a[#a + 1] = v end
    fs.write(w.rel .. "/stdin", stdin or "")
    local t0 = time.now_ms()
    local r = proc.run{ argv = a, cwd = w.abs, stdin = pre .. 'exec "$@" ' .. (shell or "") .. ' <"' .. w.abs .. '/stdin"\n', env_unset = { "TILLANDSIAS_*", "GH_TOKEN" }, timeout_ms = 60000 }
    local o = (r.stdout or ""):gsub("\r", "")
    local ok, j = pcall(json.parse, o)
    return { rc = r.code, out = o, err = r.stderr or "", j = ok and type(j) == "table" and j or {}, ms = time.now_ms() - t0,
        why = "rc=" .. tostring(r.code) .. " [" .. o:sub(1, 300) .. "] " .. (r.stderr or ""):sub(1, 200) }
end
-- JSON null parses to a userdata, never to nil.
local function null(v) return v == nil or type(v) == "userdata" end
local function has(x, line) return text.contains("\n" .. x.out .. "\n" .. x.err .. "\n", "\n" .. line .. "\n") end
local function audit()
    local l = {}
    for line in ((fs.exists(w.rel .. "/audit.jsonl") and fs.read(w.rel .. "/audit.jsonl") or "") .. "\n"):gmatch("([^\n]*)\n") do
        local ok, j = pcall(json.parse, line)
        if ok and type(j) == "table" then l[#l + 1] = j end
    end
    return l
end
local MARK = w.abs .. "/marker"

local x = run{ "--", "sh", w.abs .. "/argc.sh", 'a "b" *', "second" }
T:arm("2 an argument with a space, a quote and * reaches the child as one entry", x.rc == 0 and has(x, "argc=2") and has(x, 'argv1=[a "b" *]'), x.why)
x = run({}, nil, nil, "-- bash -c 'touch " .. MARK .. "'")
T:arm("4 a refusal prints why and remedy, exits 1, and spawns nothing", x.rc == 1 and not fs.exists(w.rel .. "/marker") and has(x, "refused:policy:no-shell-strings")
    and text.contains("\n" .. x.err, "\nwhy: ") and text.contains("\n" .. x.err, "\nremedy: "), x.why)
local refused, ran
for _, j in ipairs(audit()) do
    if j.rule_id == "no-shell-strings" then refused = j end
    if j.caller == "run" and j.decision == "allow" and not ran then ran = j end
end
T:arm("4 the audit records the refusal with no run_id, and a run with one", refused ~= nil and null(refused.run_id) and refused.caller == "run" and ran ~= nil and not null(ran.run_id), json.encode and json.encode(refused or {}) or "?")
x = run({ "--env", "ADDED=yes", "--", "env" }, nil, "export GH_TOKEN=leak-me TILLANDSIAS_RUN_FIXTURE=1\n")
T:arm("5 the child gets the base set, TILLANDSIAS_* and --env, and never GH_TOKEN", x.rc == 0 and not text.contains("\n" .. x.out, "\nGH_TOKEN=") and has(x, "ADDED=yes") and has(x, "TILLANDSIAS_RUN_FIXTURE=1") and has(x, "LC_ALL=C"), x.why)
x = run{ "--", "false" }
T:arm("7 a child's non-zero exit is the verb's", x.rc == 1, x.why)
x = run({ "--stdin-file", w.abs .. "/in.txt", "--", "cat" })
T:arm("7 --stdin-file feeds the child", x.out == "hello-from-stdin", x.why)
x = run{ "--timeout-ms", "300", "--", "sleep", "5" }
T:arm("7 a deadline is exit 124", x.rc == 124, x.why)
x = run{ "--", "no-such-program-8pur" }
T:arm("7 an unknown program is exit 127", x.rc == 127, x.why)
x = run{ "--cwd", w.abs, "--", "pwd", "-P" }
local real = text.trim(T:run{ SH, "-s", "--", w.abs, stdin = 'cd "$1" && pwd -P\n' }.stdout or "")
T:arm("7 --cwd sets the child's working directory", text.trim(x.out) == real, x.why)
x = run{ "echo hi" }
T:arm("7 there is no command-string form (a usage error)", x.rc == 2, x.why)
x = run{ "--timeout-ms", "10000", "--", "sh", w.abs .. "/keep.sh" }
T:arm("3a a grandchild holding stdout: the leader's exit 0 is 0, promptly", x.rc == 0 and text.trim(x.out) == "started" and x.ms < 4000, x.why .. " " .. x.ms .. " ms")
x = run{ "--json", "--timeout-ms", "10000", "--", "sh", w.abs .. "/keep.sh" }
T:arm("3a and --json says exited", x.j.status == "exited", x.why)
x = run{ "--timeout-ms", "10000", "--", "sh", w.abs .. "/detach.sh" }
local gpid = text.trim(x.out)
local alive = gpid:match("^%d+$") and T:run{ SH, "-s", "--", gpid, stdin = 'kill -0 "$1" 2>/dev/null || exit 1\ns="$(ps -o stat= -p "$1" 2>/dev/null | tr -d " ")"\ncase "$s" in Z*|"") exit 1 ;; esac\n' }.code == 0
if alive then T:run{ "kill", gpid } end
T:arm("3b a grandchild that detached its stdio does not outlive the door", gpid:match("^%d+$") ~= nil and not alive, gpid)
x = run{ "--json", "--timeout-ms", "5000", "--", "printf", "a b" }
local keys = {}
for k in pairs(x.j) do keys[#keys + 1] = k end
table.sort(keys)
T:arm("1 --json prints one object with the eleven keys", x.rc == 0 and select(2, x.out:gsub("\n", "")) <= 1 and table.concat(keys, ",") == "argv,code,ok,policy,run_id,signal,status,stderr,stdout,truncated,wall_ms"
    and x.j.stdout == "a b" and x.j.status == "exited" and x.j.ok == true and not null(x.j.run_id), table.concat(keys, ",") .. " " .. x.why)
x = run{ "--json", "--", "false" }
T:arm("1 a non-zero exit is a code, the verb exiting 0", x.rc == 0 and x.j.code == 1 and x.j.ok == false and x.j.status == "exited", x.why)
T:arm("1 an exited child carries no signal", null(x.j.signal), x.why)
x = run{ "--json", "--timeout-ms", "300", "--", "sleep", "5" }
T:arm("1 a deadline is timed_out with no invented code", x.rc == 0 and x.j.status == "timed_out" and null(x.j.code), x.why)
x = run{ "--json", "--timeout-ms", "5000", "--", w.abs .. "/self-term.sh" }
T:arm("1 a signalled child carries signal 15 and no code", x.rc == 0 and x.j.status == "signaled" and x.j.signal == 15 and null(x.j.code), x.why)
x = run{ "--json", "--", "no-such-program-8pur" }
T:arm("1 an unknown program is spawn_failed", x.rc == 0 and x.j.status == "spawn_failed", x.why)
x = run({ "--json" }, nil, nil, "-- bash -c 'touch " .. w.abs .. "/marker2'")
local p = type(x.j.policy) == "table" and x.j.policy or {}
T:arm("4 a --json refusal is policy_denied with rule, why and remedy, nothing spawned", x.rc == 1 and not fs.exists(w.rel .. "/marker2") and x.j.status == "policy_denied" and null(x.j.run_id)
    and p.rule_id == "no-shell-strings" and (p.why or "") ~= "" and (p.remedy or "") ~= "", x.why)
x = run({ "--json", "--capture-bytes", "1024", "--argv-json", "-" }, '["head","-c","4096","/dev/zero"]')
T:arm("6 output past --capture-bytes is truncated, and not ok", x.rc == 0 and x.j.truncated == true and x.j.ok == false and x.j.code == 0, x.why:sub(1, 200))
local c1, c2 = run{ "--", "false" }, run({}, nil, nil, "-- bash -c true")
local s1, s2 = run{ "--json", "--", "false" }, run({ "--json" }, nil, nil, "-- bash -c true")
T:arm("8 plain form cannot tell a refusal from exit 1; --json can", c1.rc == 1 and c2.rc == 1 and s1.j.status == "exited" and s2.j.status == "policy_denied", c1.why .. c2.why)
x = run{ "--bogus-flag", "--", "true" }
T:arm("8 a usage error is 2", x.rc == 2, x.why)
x = run({ "--json", "--argv-json", "-" }, '["printf","%s","C:\\\\x\\\\."]')
T:arm("3 --argv-json delivers a backslash path unconverted", x.rc == 0 and x.j.stdout == "C:\\x\\." and x.j.status == "exited", x.why)
x = run({ "--argv-json", "-" }, '["sh","' .. w.abs .. '/argc.sh","a \\"b\\" *"]')
T:arm("3 --argv-json keeps a space, a quote and * in one entry", x.rc == 0 and has(x, "argc=1") and has(x, 'argv1=[a "b" *]'), x.why)
x = run({ "--argv-json", "-" }, '["bash","-c","touch ' .. w.abs .. '/marker3"]')
T:arm("3 --argv-json goes through the same policy", x.rc == 1 and not fs.exists(w.rel .. "/marker3"), x.why)
for _, bad in ipairs{ '"git status"', "[]", '["git",1]', "not json" } do
    x = run({ "--argv-json", "-" }, bad)
    T:arm("3 --argv-json rejects " .. bad .. " (2)", x.rc == 2, x.why)
end
x = run({ "--argv-json", "-", "--", "echo", "also" }, '["true"]')
T:arm("3 argv from both --argv-json and -- is a usage error", x.rc == 2, x.why)
run{ "--json", "--caller", "mcp", "--", "true" }
local a1 = audit()
local last = a1[#a1]
local b1, b2 = run{ "--json", "--caller", "pretooluse", "--", "true" }, run{ "--json", "--caller", "", "--", "true" }
T:arm("9 --caller mcp is audited; pretooluse and empty are usage errors that audit nothing", last ~= nil and last.caller == "mcp" and b1.rc == 2 and b2.rc == 2 and #audit() == #a1, b1.why .. b2.why)
T:finish()
