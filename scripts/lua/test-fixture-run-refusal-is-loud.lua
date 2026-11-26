-- @env PATH HOME
-- @trace order:2392-2gm8
--
-- test-fixture-run-refusal-is-loud.lua — a fixture's T:run / T:must of a command the door refuses
-- ends the fixture with a refused: verdict naming the command, the rule and the remedy, so an
-- unchecked cleanup can never read as done; a caller that passes refusal_ok = true (a fixture whose
-- subject IS the refusal) still gets the refusal back as a result.
--
-- MEASURED 2026-11-26: proc.run of `rm -rf <a path outside the workspace>` returns
-- status=policy_consent_required, ok=false, code=nil and raises nothing. In 2387-b6v2 a port's
-- snapshot cleanup was refused that way, the run was green, and the checkout's gate stamp read
-- stale:fixture-borrowed-stamp until someone looked.
--
-- Each arm runs a child fixture through the real door. The rm names a path that does not exist,
-- outside the workspace, so even a door that allowed it would remove nothing.
--
-- Usage: tillandsias-plan script run scripts/lua/test-fixture-run-refusal-is-loud.lua
-- Verdict: ok:fixture-run-refusal-is-loud:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("fixture-run-refusal-is-loud")
local PLAN = fixture.plan_binary()
if not PLAN then T:refuse("no-plan-binary", "the children run through the plan binary's door") end
local w = T:scratch()
local GONE = "/nonexistent-2392-2gm8-" .. tostring(time.now_ms()) .. "/x"
local HEAD = 'local fixture = require "common.fixture"\nlocal C = fixture.new("child")\n'
local function child(name, body)
    fs.write(w.rel .. "/" .. name .. ".lua", HEAD .. body)
    local r = proc.run{ argv = { PLAN, "script", "run", w.abs .. "/" .. name .. ".lua" }, env = { PATH = env.get("PATH"), HOME = env.get("HOME") }, timeout_ms = 60000 }
    return (r.stdout or "") .. (r.stderr or ""), r.code
end

-- PREMISE: the door refuses this rm, with a status and no exit code.
local p = proc.run{ argv = { "rm", "-rf", GONE }, timeout_ms = 10000 }
T:arm("PREMISE the door refuses an rm -rf outside the workspace, with no exit code", p.ok == false and p.code == nil and (p.status or ""):match("^policy_") ~= nil,
    tostring(p.status) .. " code=" .. tostring(p.code))

local o, rc = child("run", 'C:run{ "rm", "-rf", "' .. GONE .. '" }\nout.line("carried-on")\nC:finish()\n')
T:arm("1 T:run of a refused command ends the fixture: it does not carry on", not text.contains(o, "carried-on") and rc ~= 0, "rc=" .. tostring(rc) .. " " .. o:sub(1, 300))
T:arm("1 and its verdict is refused:, naming the command and the rule", o:find("\nrefused:child:door%-refused") ~= nil or o:find("^refused:child:door%-refused") ~= nil, o:sub(1, 400))
T:arm("1 and the detail carries the door's remedy", text.contains(o, "rm -rf " .. GONE) and text.contains(o, "workspace-destroy"), o:sub(1, 400))

o, rc = child("must", 'C:must{ "rm", "-rf", "' .. GONE .. '" }\nout.line("carried-on")\nC:finish()\n')
T:arm("2 T:must of a refused command is refused as a door refusal, not as a nil exit", not text.contains(o, "carried-on") and text.contains(o, "door-refused") and text.contains(o, "workspace-destroy"), o:sub(1, 400))

o, rc = child("ok", 'local r = C:run{ "rm", "-rf", "' .. GONE .. '", refusal_ok = true }\nout.line("got:" .. tostring(r.status) .. ":" .. tostring(r.rule_id))\nC:finish()\n')
T:arm("3 refusal_ok = true hands the refusal back as a result, and the fixture carries on", text.contains(o, "got:policy_consent_required:workspace-destroy") and rc == 0, "rc=" .. tostring(rc) .. " " .. o:sub(1, 300))

o, rc = child("plain", 'local r = C:run{ "true" }\nout.line("ran:" .. tostring(r.code))\nC:finish()\n')
T:arm("4 CONTROL an allowed command runs as before", text.contains(o, "ran:0") and rc == 0, "rc=" .. tostring(rc) .. " " .. o:sub(1, 300))
T:finish()
