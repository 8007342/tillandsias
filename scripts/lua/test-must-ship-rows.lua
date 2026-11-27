-- @env PATH HOME TMPDIR
-- @trace order:1218-25z3, spec:versioning, spec:ci-release, order:2380-wjrd
--
-- test-must-ship-rows.lua — scripts/lua/check-must-ship-rows.lua names the rows marked for the next cut whose fix
-- is not in the tree being cut, and never blocks. Arms 1-6 run the guard in a scratch repo with its own
-- ledger: one row fixed by a `type(order):` subject, one only mentioned in a body. Arms 7-10 read THIS
-- repository: its history carries the case the row exists for, and its release path runs the guard.
-- Ported from the .sh of the same name, which pointed the guard at probe commits in the real repository.
--
-- Usage: tillandsias-plan script run scripts/lua/test-must-ship-rows.lua
-- Verdict: ok:must-ship-rows:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("must-ship-rows")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
local GUARD = "scripts/lua/check-must-ship-rows.lua"
if not fs.exists(GUARD) then T:refuse("subject-missing") end
if PLAN == "" then T:refuse("no-plan-binary") end
local src = fs.read(GUARD):gsub("\r\n", "\n")

local R = T:git_repo()
fs.mkdir(R.rel .. "/scripts"); fs.mkdir(R.rel .. "/scripts/lua"); fs.mkdir(R.rel .. "/plan")
fs.write(R.rel .. "/" .. GUARD, src)
fs.write(R.rel .. "/scripts/plan-binary-probe.sh", (fs.read("scripts/plan-binary-probe.sh"):gsub("\r\n", "\n")))
local function row(order, id, mark)
    return "  - packet_id: " .. id .. "\n    order: " .. order .. "\n    status: ready\n    kind: bug\n" .. (mark and "    must_ship: next\n" or "") .. "    title: |\n      t\n"
end
fs.write(R.rel .. "/plan/index.yaml", "packets:\n" .. row("9001-aaaa", "fixed-row", true) .. row("9002-bbbb", "mentioned-row", true) .. row("9003-cccc", "unmarked-row"))
local function commit(subject, body)
    T:must{ "git", "-C", R.abs, "commit", "-q", "--allow-empty", "-m", subject .. (body and ("\n\n" .. body) or "") }
    return text.trim(T:must{ "git", "-C", R.abs, "rev-parse", "HEAD" }.stdout)
end
local MENTION = commit("plan(9999-zzzz): talks about other rows", "this body names 9001-aaaa and 9002-bbbb and fix(9002-bbbb): at length")
local FIX = commit("fix(9001-aaaa): the fix")
local BOTH = commit("feat(8000-zzzz, 9002-bbbb): two orders in one subject")

-- The guard (or a mutant of it) on the scratch ledger.
local function guard(args, o)
    o = o or {}
    fs.write(R.rel .. "/" .. GUARD, o.body or src)
    local argv = { PLAN, "script", "run", R.abs .. "/" .. GUARD, "--", cwd = R.abs, timeout_ms = o.timeout_ms or 60000, env_unset = { "TILLANDSIAS_*", "GIT_*" },
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TMPDIR = env.get("TMPDIR"), TILLANDSIAS_PLAN_BIN = o.plan or PLAN } }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = T:run(argv)
    local line = text.trim((r.stdout or ""):gsub("\r", ""))
    return { line = line, code = r.code, err = (r.stderr or ""):gsub("\r", ""), got = "rc=" .. tostring(r.code) .. " [" .. line .. "] " .. (r.stderr or ""):sub(1, 300) }
end
local x = guard{ "--cut-ref", BOTH }
T:arm("1 CONTROL a cut holding every marked fix prints one ok line", x.line == "ok:must-ship:0 outstanding of 2 marked" and x.code == 0, x.got)
T:arm("1 an order among several in a subject counts", text.contains(x.err, "present      9002-bbbb"), x.got)
x = guard{ "--cut-ref", FIX }
T:arm("2 a cut missing one is an advisory that names it and does not block", x.line == "advisory:must-ship:1 outstanding of 2 marked" and x.code == 0
    and text.contains(x.err, "OUTSTANDING  9002-bbbb"), x.got)
T:arm("2 a type(order): subject counts as the fix", text.contains(x.err, "present      9001-aaaa"), x.got)
x = guard{ "--cut-ref", MENTION }
T:arm("3 a mention in a body is not the fix", x.line == "advisory:must-ship:2 outstanding of 2 marked" and text.contains(x.err, "OUTSTANDING  9001-aaaa"), x.got)
T:arm("3 an unmarked row is not counted", not text.contains(x.err, "9003-cccc"), x.got)
x = guard{ "--cut-ref", "refs/heads/definitely-no-such-ref" }
T:arm("4 a ref that does not resolve is skipped, never ok, and does not block", x.line == "skipped:must-ship:no-cut-ref" and x.code == 0, x.got)

-- A binary older than the field projects no must_ship: its zero means "cannot see", not "none".
fs.write(R.rel .. "/stale-plan", "#!/usr/bin/env bash\nfor a in \"$@\"; do [ \"$a\" = --json ] && { echo '[{\"order\":\"1\",\"packet_id\":\"p\",\"status\":\"ready\"}]'; exit 0; }; done\n"
    .. '[ "$1" = capabilities ] && echo query\nexit 0\n')
T:must{ SH, "-s", "--", R.abs .. "/stale-plan", stdin = 'chmod +x "$1"\n' }
local STALE = { plan = R.abs .. "/stale-plan" }
x = guard({ "--cut-ref", BOTH }, STALE)
T:arm("5 a binary that cannot see the mark is skipped, never a clean zero", x.line == "skipped:must-ship:stale-plan-binary" and x.code == 0, x.got)
for _, a in ipairs{ { "v56.9.13.1" }, { "--against", "v56.9.13.1" }, { "--marker" }, { "--cut-ref" } } do
    x = guard(a, { timeout_ms = 30000 })
    T:arm("6 an invocation it does not know prints no verdict and does not block: " .. table.concat(a, " "),
        x.line:find("^fail:must%-ship:[a-z-]+$") ~= nil and x.code == 0, x.got)
end

-- This repository: the miss the row exists for is in its history.
local function subjects(ref)
    local c = 0
    for l in (T:run{ "git", "log", "--format=%s", ref, cwd = ROOT }.stdout or ""):gmatch("[^\r\n]+") do
        if l:find("^%l+%([^)]*1211%-34v6[^)]*%)") then c = c + 1 end
    end
    return c
end
local shallow = text.trim(T:run{ "git", "rev-parse", "--is-shallow-repository", cwd = ROOT }.stdout or "") == "true"
if shallow then out.line("skip:must-ship-rows:7-8:shallow-clone") else
    T:arm("7 1211-34v6's fix has a subject on this branch", subjects("HEAD") >= 1, subjects("HEAD"))
    if T:run{ "git", "rev-parse", "--verify", "-q", "v56.9.13.1", cwd = ROOT }.code == 0 then
        T:arm("8 and none in the tag that shipped after it", subjects("v56.9.13.1") == 0, subjects("v56.9.13.1"))
    else
        out.line("skip:must-ship-rows:8:no-tag-v56.9.13.1-in-this-clone")
    end
end
local live = T:run{ PLAN, "script", "run", GUARD, "--", "--cut-ref", "HEAD", cwd = ROOT, timeout_ms = 120000,
    env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TMPDIR = env.get("TMPDIR"), TILLANDSIAS_PLAN_BIN = PLAN } }
local said = text.trim((live.stdout or ""):gsub("\r", ""))
T:arm("9 on the real ledger it prints one line of its grammar, rc 0", live.code == 0
    and (said:find("^ok:must%-ship:0 outstanding of %d+ marked$") ~= nil or said:find("^advisory:must%-ship:%d+ outstanding of %d+ marked$") ~= nil), said)
T:arm("10 the release path runs it", text.contains(fs.read("scripts/release-preflight.sh"), "scripts/lua/check-must-ship-rows.lua"))
local pf = T:run{ SH, ROOT .. "/scripts/release-preflight.sh", cwd = ROOT, timeout_ms = 240000,
    env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TMPDIR = env.get("TMPDIR"), TILLANDSIAS_PLAN_BIN = PLAN } }
T:arm("10 and still prints one line on stdout", select(2, (pf.stdout or ""):gsub("[^\r\n]+", "")) == 1, (pf.stdout or ""):sub(1, 300))

-- MUTATION
local function mutant(from, to)
    local x, y = src:find(from, 1, true)
    if not x then T:refuse("mutation-anchor-missing", from) end
    return src:sub(1, x - 1) .. to .. src:sub(y + 1)
end
local MENTIONS = mutant('for _, s in ipairs(subjects) do if s:find(pat) then', 'for _, s in ipairs(subjects) do if s:find(m.order, 1, true) then')
MENTIONS = MENTIONS:gsub('"%-%-format=%%s", CUT_REF', '"--format=%%B", CUT_REF')
x = guard({ "--cut-ref", MENTION }, { body = MENTIONS })
T:arm("11 MUTATION a guard that counts mentions fails arm 3", x.line == "ok:must-ship:0 outstanding of 2 marked", x.got)
x = guard({ "--cut-ref", BOTH }, { plan = STALE.plan, body = mutant('if saw ~= "next" then', "if false then") })
T:arm("11 MUTATION a guard that trusts any binary's zero fails arm 5", x.line ~= "skipped:must-ship:stale-plan-binary", x.got)
x = guard({ "v56.9.13.1" }, { body = mutant('done("fail:must-ship:unknown-argument")', "i = i + 1") })
T:arm("11 MUTATION a guard that drops an argument it does not know fails arm 6", x.line == "ok:must-ship:0 outstanding of 2 marked", x.got)
T:finish()
