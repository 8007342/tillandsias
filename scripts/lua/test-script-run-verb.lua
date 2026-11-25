-- @trace order:1384-bqhy, order:2375-psb9
-- @env PATH HOME
--
-- test-script-run-verb.lua — `tillandsias-plan script run` is the ONE runner for a Lua
-- decider, and `script classify` the ONE classifier the gate loop and the preflight door both
-- read (1384-bqhy verifiable_closure). Ported from test-script-run-verb.sh (2375-psb9); same
-- seven arms, in its order.
--
--   1 OK          verdict.ok("x", 3) prints exactly `ok:x:3`, exit 0
--   2 REFUSED     verdict.refused("x", detail): exit 1, `refused:x` on stdout, detail on stderr
--   3 NO VERDICT  a script returning without one: exit 1, `refused:no-verdict:<name>`
--                 (silent green is unconstructible)
--   4 TIMEOUT     a script outliving --timeout: exit 124, `status=timed_out`
--   5 STEP_LUA    build.sh's own gate-steps loop over a SCRATCH root runs a STEP_LUA-only
--                 .step and shows its verdict; a missing .lua is refused, not skipped; a .step
--                 naming both is refused
--   6 TIMING      the record lands in TILLANDSIAS_TIMING_LOG; /tmp/tillandsias-timing.jsonl
--                 does not grow (1204-3s2s)
--   7 CLASSIFY    advisory is successful-only; skip / could-not-run / timed_out / plain
--                 refusal keep the door's precedence; ONE outcome classifier in the tree, and
--                 both build.sh call sites reach it through the binary
--
-- Hermetic: every tree it writes is under target/plan-scratch (1516-wru4).
--
-- GRAMMAR ok:script-run-verb:<n> arms | violation:script-run-verb:<n>-failed
--       | skip:script-run-verb:no-validator

local fixture = require "common.fixture"
local T = fixture.new("script-run-verb")
local ROOT = fixture.repo_root()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:skip("no-validator") end
if PLAN:sub(1, 1) ~= "/" then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end

local W = T:scratch()
local TLOG = W.abs .. "/timing.jsonl"
local ENV = { TILLANDSIAS_TIMING_LOG = TLOG }
local UNSET = { "TILLANDSIAS_*" }

local function lua(name, body) fs.write(W.rel .. "/" .. name .. ".lua", body .. "\n") end
local function run(name, ...)
    local argv = { PLAN, "script", "run", W.abs .. "/" .. name .. ".lua", ... }
    argv.cwd, argv.env, argv.env_unset, argv.timeout_ms = ROOT, ENV, UNSET, 60000
    local r = T:run(argv)
    return r.code, text.trim(r.stdout or ""), r.stderr or ""
end
local function has_line(s, want) for _, l in ipairs(text.lines(s)) do if l == want then return true end end return false end

-- ARM 1
lua("okv", 'verdict.ok("x", 3)')
local rc, o, e = run("okv")
T:arm('ARM 1: verdict.ok("x", 3) prints exactly ok:x:3 and exits 0', rc == 0 and o == "ok:x:3", "rc=" .. tostring(rc) .. " out='" .. o .. "'")

-- ARM 2
lua("refv", 'verdict.refused("x", "the detail goes to stderr")')
rc, o, e = run("refv")
T:arm("ARM 2: verdict.refused exits 1 with refused:x on stdout and the detail on stderr only",
    rc == 1 and o == "refused:x" and text.contains(e, "the detail goes to stderr") and not text.contains(o, "detail"),
    "rc=" .. tostring(rc) .. " out='" .. o .. "' err='" .. e .. "'")

-- ARM 3
lua("silent", "local x = 1 + 1")
rc, o = run("silent")
T:arm("ARM 3: a script ending without a verdict exits 1 with refused:no-verdict:silent",
    rc == 1 and o == "refused:no-verdict:silent", "rc=" .. tostring(rc) .. " out='" .. o .. "'")

-- ARM 4
lua("sleeper", 'local t = time.now_ms(); while time.now_ms() - t < 5000 do end; verdict.ok("late")')
rc, o = run("sleeper", "--timeout", "300ms")
local any_ok = false
for _, l in ipairs(text.lines(o)) do if l:sub(1, 3) == "ok:" then any_ok = true end end
T:arm("ARM 4: a script outliving --timeout 300ms exits 124 printing status=timed_out, and never ok",
    rc == 124 and has_line(o, "status=timed_out") and not any_ok, "rc=" .. tostring(rc) .. " out='" .. o .. "'")

-- ARM 5: build.sh's own loop over scratch roots.
local function mkroot(leaf)
    fs.mkdir(W.rel .. "/" .. leaf .. "/scripts/gate-steps.d"); fs.mkdir(W.rel .. "/" .. leaf .. "/scripts/lua")
    return W.rel .. "/" .. leaf, W.abs .. "/" .. leaf
end
local function gate(abs)
    local r = T:run{ "./build.sh", "--gate-steps", abs, cwd = ROOT, env = ENV, env_unset = UNSET, timeout_ms = 300000 }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local R = mkroot("root-ok")
fs.write(R .. "/scripts/lua/fixture-step.lua", 'verdict.ok("fixture-lua-step", 7)\n')
fs.write(R .. "/scripts/gate-steps.d/100-lua.step",
    'STEP_DESC="a Lua step"\nSTEP_LUA="scripts/lua/fixture-step.lua"\nSTEP_ERROR="lua step failed"\nSTEP_OK="lua step passed"\n')
local r5, o5 = gate(W.abs .. "/root-ok")
local R2 = mkroot("root-missing")
fs.write(R2 .. "/scripts/gate-steps.d/100-lua.step", 'STEP_DESC="a missing Lua step"\nSTEP_LUA="scripts/lua/absent.lua"\n')
local r5m, o5m = gate(W.abs .. "/root-missing")
local R3 = mkroot("root-both")
fs.write(R3 .. "/scripts/lua/both.lua", 'verdict.ok("both")\n'); fs.write(R3 .. "/scripts/both.sh", "echo ok:both\n")
fs.write(R3 .. "/scripts/gate-steps.d/100-both.step", 'STEP_DESC="both"\nSTEP_LUA="scripts/lua/both.lua"\nSTEP_SCRIPT="scripts/both.sh"\n')
local r5b, o5b = gate(W.abs .. "/root-both")
local tail = {}
local l5 = text.lines(o5)
for i = math.max(1, #l5 - 2), #l5 do tail[#tail + 1] = l5[i] end
T:arm("ARM 5: build.sh's loop runs a STEP_LUA-only step and shows its verdict; a missing .lua and a step naming both are refused",
    r5 == 0 and text.contains(o5, "ok:fixture-lua-step:7")
        and r5m ~= 0 and text.contains(o5m, "absent.lua, which does not exist")
        and r5b ~= 0 and text.contains(o5b, "names both STEP_SCRIPT and STEP_LUA"),
    "ok-root rc=" .. tostring(r5) .. " missing rc=" .. tostring(r5m) .. " both rc=" .. tostring(r5b)
        .. "; ok-root tail: " .. table.concat(tail, "|"))

-- ARM 6: timing goes where it is told, and never to /tmp (outside the repo: no fs.*).
local SHARED = "/tmp/tillandsias-timing.jsonl"
local function shared_lines()
    if T:run{ "test", "-f", SHARED }.code ~= 0 then return 0 end
    return tonumber((T:run{ "wc", "-l", SHARED }.stdout or ""):match("(%d+)")) or -1
end
local before = shared_lines()
fs.write(W.rel .. "/timing.jsonl", "")
run("okv")
local after = shared_lines()
local tl = fs.read(W.rel .. "/timing.jsonl") or ""
T:arm("ARM 6: the timing record lands in TILLANDSIAS_TIMING_LOG and /tmp/tillandsias-timing.jsonl did not grow",
    text.contains(tl, '"kind":"script-run"') and text.contains(tl, '"verdict":"ok:x:3"') and after == before,
    "log='" .. tl .. "' shared " .. before .. "->" .. after)

-- ARM 7: advisory and one classifier, reached by both call sites.
fs.write(W.rel .. "/c-skip", "skip:x:not-here\n"); fs.write(W.rel .. "/c-cnr", "could-not-run:x:no-meminfo\n")
fs.write(W.rel .. "/c-to", "partial\n"); fs.write(W.rel .. "/c-ref", "violation: the tree is wrong\n")
fs.write(W.rel .. "/c-adv", "centicolon: R=1 regime=baseline (advisory)\n")
local function classify(rc_, file, status)
    local argv = { PLAN, "script", "classify", "--rc", tostring(rc_) }
    if status then argv[#argv + 1] = "--status"; argv[#argv + 1] = status end
    argv[#argv + 1] = "--file"; argv[#argv + 1] = W.abs .. "/" .. file
    argv.cwd, argv.env_unset = ROOT, UNSET
    return text.trim(T:run(argv).stdout or "")
end
local kinds = table.concat({
    classify(1, "c-skip"), classify(3, "c-cnr"), classify(0, "c-to", "timed_out"), classify(1, "c-ref"),
    classify(0, "c-adv"), classify(1, "c-adv"), classify(124, "c-adv"), classify(127, "c-adv"),
    classify(0, "c-adv", "timed_out") }, " ")
-- ONE OUTCOME classifier: every Rust fn classifying from an exit code. (Other `fn classify`
-- in the tree classify questions, commands and refs, not outcomes.)
local gg = T:run{ "git", "grep", "-n", "--untracked", "-E", "fn classify[a-z_]*\\(rc: i32", "--", "crates", cwd = ROOT }
local defs = 0
for _, l in ipairs(text.lines(gg.stdout or "")) do if l ~= "" then defs = defs + 1 end end
local build = fs.read("build.sh") or ""
local sites = 0
for _, l in ipairs(text.lines(build)) do if text.contains(l, "script classify --rc") then sites = sites + 1 end end
local oldgrep = 0
for _, l in ipairs(text.lines(build)) do if text.contains(l, "grep -qE '^skip:' \"$_pf_tmp\"") then oldgrep = oldgrep + 1 end end
lua("lclass", 'verdict.ok("k", verdict.classify{rc=1, text="skip:x"})')
run("lclass")
lua("advisory", 'verdict.advisory("centicolon: R=1 regime=baseline (advisory)")')
local adv_rc, adv_out = run("advisory")
lua("injected", 'verdict.advisory("refused:injected\\ncenticolon: report (advisory)")')
local inj_rc, inj_out = run("injected")
T:arm("ARM 7: advisory is verbatim only for successful runs; failure precedence survives and newline injection is refused",
    kinds == "skip could-not-run timed-out refused advisory refused timed-out cannot-start timed-out" and defs == 1
        and sites == 2 and oldgrep == 0 and adv_rc == 0 and adv_out == "centicolon: R=1 regime=baseline (advisory)"
        and inj_rc == 1 and not text.contains(inj_out, "refused:injected") and not text.contains(inj_out, "centicolon: report"),
    "kinds='" .. kinds .. "' defs=" .. defs .. " build.sh-sites=" .. sites .. " old-door-grep=" .. oldgrep
        .. " injected='" .. inj_out .. "' rc=" .. tostring(inj_rc))

T:finish()
