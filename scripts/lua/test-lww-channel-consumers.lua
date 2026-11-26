-- @trace order:1158-y3ad, order:1156-eif4, order:980-ja2m, order:2369-8vq3
--
-- test-lww-channel-consumers.lua — every reader of the LWW channel reads BOTH spellings, `status:` and
-- `fields:`, and a new reader cannot hardcode one. An invisible write fails OPEN where offenders are
-- scanned for (closure-evidence) and LOUD where an omission is (carry-forward). Each fragment is written
-- in both spellings, after a precondition that fires. Ported from the .sh of the same name.
--
-- Usage: tillandsias-plan script run scripts/lua/test-lww-channel-consumers.lua
-- Verdict: ok:lww-channel-consumers:<n> arms | violation:...:<n>-failed | skip:...:no-runnable-plan-binary

local fixture = require "common.fixture"
local T = fixture.new("lww-channel-consumers")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:skip("no-runnable-plan-binary") end
local W = T:scratch()

local function plan(verb, name, body)
    fs.write(W.rel .. "/" .. name .. ".yaml", body)
    local r = T:run{ PLAN, verb, W.abs .. "/" .. name .. ".yaml", cwd = ROOT, env_unset = { "TILLANDSIAS_*" } }
    return r.code, "\n" .. ((r.stdout or "") .. (r.stderr or "")):gsub("\r", "") .. "\n"
end
local TOUCHED = 'events:\n  - packet_id: alpha\n    event:\n      type: note\n      ts: "2026-02-02T00:00:00Z"\n      agent_id: probe\n      summary: touched\n'
local function write(chan, field, value)
    return chan .. ":\n  - packet_id: alpha\n    field: " .. field .. "\n    value: " .. value
        .. '\n    ts: "2026-02-02T00:00:01Z"\n    host: probe\n'
end

local _, o = plan("carry-forward-check", "carry-none", TOUCHED)
T:arm("1 PRECONDITION a touched packet with no next_action raises the advisory", o:find("\nalpha\n", 1, true) ~= nil, o)
for _, chan in ipairs{ "status", "fields" } do
    _, o = plan("carry-forward-check", "carry-" .. chan, TOUCHED .. write(chan, "next_action", '"the next step is written right here"'))
    T:arm("2 a next_action under " .. chan .. ": silences it", not o:find("\nalpha\n", 1, true), o)
end
for _, chan in ipairs{ "status", "fields" } do
    local rc
    rc, o = plan("closure-evidence-check", "closure-" .. chan, write(chan, "status", "completed"))
    T:arm("3 an evidence-free closure under " .. chan .. ": is refused", rc ~= 0 and rc ~= nil and text.contains(o, "alpha"), "rc=" .. tostring(rc) .. " " .. o)
end

-- 4 the scan-side guard, over comment-stripped source.
local function offenders(body)
    local n = 0
    for l in (body:gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do
        l = l:gsub("//.*$", "")
        if l:find("as_sequence", 1, true) and (l:find('.get("status")', 1, true) or l:find('.get("fields")', 1, true)) then n = n + 1 end
    end
    return n
end
for _, f in ipairs{ "main.rs", "answer.rs" } do
    local p = "crates/tillandsias-plan/src/" .. f
    if fs.exists(p) then
        T:arm("4 " .. f .. " hardcodes no channel read (use fragments::lww_entries)", offenders(fs.read(p)) == 0, offenders(fs.read(p)))
    elseif f == "main.rs" then T:refuse("subject-missing", p) end
end
local READ = 'if let Some(x) = doc.get("status").and_then(Value::as_sequence) {'
T:arm("5 CONTROL a comment quoting the read is not one", offenders("// " .. READ .. "\n/// " .. READ .. "\nfn real() {}\n") == 0, "flagged")
T:arm("5 MUTATION the read itself is", offenders("fn real() {\n    " .. READ .. "\n") == 1
    and offenders((READ:gsub("status", "fields"))) == 1, "not flagged")

T:finish()
