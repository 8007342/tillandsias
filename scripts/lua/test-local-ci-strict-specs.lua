-- @trace order:2220-yj8f, spec:ci-release
-- @env TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-local-ci-strict-specs.lua — pins scripts/lua/local-ci-strict-specs.lua,
-- local-ci.sh's --strict-all spec selection (2220-yj8f). Expectations are
-- written out by hand over a fixture bindings file, so the fixture keeps its
-- meaning after the bash functions it replaced (get_all_active_specs,
-- spec_in_list, normalize_spec_list) are gone. At port time the helper was
-- also compared line for line with those functions over the real bindings
-- file, with four ignore lists (recorded on the PR).
--
--   1 only ACTIVE specs, in file order (obsolete, draft and status-less skipped)
--   2 --ignore with a colon, a comma and whitespace removes exactly those
--   3 an --ignore entry naming no spec changes nothing
--   4 ignoring every active spec gives an EMPTY list, not a blank line
--   5 stdout is the list alone: no verdict line (local-ci.sh captures it)
--
-- Verdict: ok:local-ci-strict-specs:5 arms | violation:local-ci-strict-specs:<n> failed

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local failn = 0
local function ok(m) out.line("ok:   " .. m) end
local function bad(m) out.line("FAIL: " .. m); failn = failn + 1 end

local rel = "target/plan-scratch/local-ci-strict-specs-" .. tostring(time.now_ms())
proc.run{ argv = { "mkdir", "-p", root .. "/" .. rel } }
local function cleanup() proc.run{ argv = { "find", root .. "/" .. rel, "-delete" }, timeout_ms = 60000 } end

local RUNNER = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or ""
if RUNNER == "" then
    fs.write(rel .. "/resolve.sh", ". scripts/plan-binary-probe.sh && resolve_plan_binary\n")
    RUNNER = text.trim(proc.run{ argv = { "bash", root .. "/" .. rel .. "/resolve.sh" } }.stdout or "")
    if RUNNER:sub(1, 2) == "./" then RUNNER = root .. "/" .. RUNNER:sub(3) end
end
if RUNNER == "" then cleanup(); verdict.could_not_run("local-ci-strict-specs:no-runner") end

local B = rel .. "/bindings.yaml"
fs.write(B, "version: '1.0'\nspecs:\n"
    .. "- spec_id: alpha\n  status: active\n  litmus_tests: []\n"
    .. "- spec_id: retired\n  status: obsolete\n  litmus_tests: []\n"
    .. "- spec_id: beta\n  status: active\n  litmus_tests: []\n"
    .. "- spec_id: sketch\n  status: draft\n  litmus_tests: []\n"
    .. "- spec_id: nostatus\n  litmus_tests: []\n"
    .. "- spec_id: gamma\n  status: active\n  litmus_tests: []\n"
    .. "- spec_id: delta\n  status: active\n  litmus_tests: []\n")

local function select(ignore)
    local a = { RUNNER, "script", "run", "--helper", root .. "/scripts/lua/local-ci-strict-specs.lua", "--", "--bindings", B }
    if ignore then a[#a + 1] = "--ignore"; a[#a + 1] = ignore end
    local r = proc.run{ argv = a, timeout_ms = 60000 }
    return r.stdout or "", r.code
end
local function shown(s) return "[" .. s:gsub("\n", "|") .. "]" end

local o, rc = select(nil)
if rc == 0 and o == "alpha\nbeta\ngamma\ndelta\n" then ok("1 only active specs, in file order")
else bad("1 rc=" .. tostring(rc) .. " " .. shown(o)) end

o, rc = select("beta:gamma, alpha")
if rc == 0 and o == "delta\n" then ok("2 an ignore list in colons, commas and whitespace removes exactly those specs")
else bad("2 rc=" .. tostring(rc) .. " " .. shown(o)) end

o, rc = select("no-such-spec")
if rc == 0 and o == "alpha\nbeta\ngamma\ndelta\n" then ok("3 an ignore entry naming no spec changes nothing")
else bad("3 rc=" .. tostring(rc) .. " " .. shown(o)) end

o, rc = select("alpha,beta,gamma,delta")
if rc == 0 and o == "" then ok("4 ignoring every active spec gives an empty list")
else bad("4 rc=" .. tostring(rc) .. " " .. shown(o)) end

o = select(nil)
local verdictish = false
for _, l in ipairs(text.lines(o)) do
    if l:match("^[a-z%-]+:") then verdictish = true end
end
if not verdictish then ok("5 stdout is the list alone, with no verdict line for local-ci.sh to capture")
else bad("5 a verdict-shaped line reached stdout: " .. shown(o)) end

cleanup()
if failn == 0 then verdict.ok("local-ci-strict-specs:5 arms") end
verdict.emit("violation:local-ci-strict-specs:" .. failn .. " failed", 1)
