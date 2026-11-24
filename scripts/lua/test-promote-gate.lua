-- @env PATH HOME TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:2296-pn45, spec:ci-release
--
-- test-promote-gate.lua — check-promote-gate.lua on a scratch ledger read by the REAL
-- plan binary (so records are folded as promotion reads them), with `gh` stubbed.
--
--   1 PASS       a pass per platform, an idle queue, trunk's ledger: ok
--   2 MISSING    one platform without a record is named; another tag's record is not it
--   3 LATEST     a later fail cancels a pass, whatever the order the events were written
--   4 PARTIAL    credential-unmeasured refuses, counts only when that platform is named,
--                and the verdict line names it; naming another platform does not help
--   5 PROSE      an event of another type with the same words is not a record
--   6 MALFORMED  a smoke-record that does not match refuses; a regime of another platform
--   7 QUEUE      gating refuses; an unreadable status refuses
--   8 LEDGER     trunk ahead of HEAD refuses; a local plan/ edit refuses
--   9 OFFLINE    trunk's head unreadable is could-not-run, never ok
--  10 USAGE      a malformed tag, an unknown platform
--
-- Usage: tillandsias-plan script run scripts/lua/test-promote-gate.lua
-- Verdict: ok:promote-gate-fixture:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("promote-gate-fixture")
local PLAN = fixture.plan_binary()
local TAG, ROW = "v1.2.3.4", "smoke-v1-2-3-4"
local SUBJECT = fs.read("scripts/lua/check-promote-gate.lua")
local n = 0

local function rec(p, v, o)
    o = o or {}
    return { type = o.type or "smoke-record", ts = o.ts or "2026-11-24T01:00:00Z",
        sum = o.sum or ("smoke " .. p .. " " .. (o.tag or TAG) .. " " .. v .. " regime=" .. (o.regime or p .. ":fixture")) }
end
local ALL = { rec("linux", "pass"), rec("darwin", "pass"), rec("windows", "pass") }
local function with(...) local t = {}; for _, r in ipairs(ALL) do t[#t + 1] = r end
    for _, r in ipairs{ ... } do t[#t + 1] = r end; return t end

local function gate(events, o)
    o = o or {}
    n = n + 1
    local r = T:git_repo("g" .. n)
    local y = { "packets:\n  - packet_id: " .. ROW .. "\n    order: \"0001-aaaa\"\n    status: ready\n    kind: research\n    title: t\n    events:\n" }
    for _, e in ipairs(events) do
        y[#y + 1] = "      - {type: " .. e.type .. ", ts: \"" .. e.ts .. "\", host: fx, summary: \"" .. e.sum .. "\"}\n"
    end
    fs.mkdir(r.rel .. "/plan/index.d"); fs.mkdir(r.rel .. "/scripts/lua"); fs.mkdir(r.rel .. "/bin")
    fs.write(r.rel .. "/plan/index.yaml", table.concat(y))
    fs.write(r.rel .. "/scripts/lua/check-promote-gate.lua", SUBJECT)
    local function git(...)
        local a = { "git", "-C", r.abs, "-c", "user.name=t", "-c", "user.email=t@t" }
        for _, x in ipairs{ ... } do a[#a + 1] = x end
        return text.trim(T:must(a).stdout or "")
    end
    git("add", "-A"); git("commit", "-qm", "ledger")
    local head = git("rev-parse", "HEAD")
    if o.ahead then head = git("commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "later") end
    if o.dirty then fs.write(r.rel .. "/plan/index.d/zz.yaml", "events: []\n") end
    fs.write(r.rel .. "/bin/gh", "#!/bin/sh\ncase \"$*\" in\n"
        .. "  *heads/linux-next*) " .. (o.offline and "exit 1" or "echo " .. head) .. " ;;\n"
        .. "  *queue/status*) " .. (o.noqueue and "exit 1" or "echo abc123") .. " ;;\n"
        .. "  *git/commits/abc123*) echo '" .. (o.queue or "queue:idle last-land=abc 12s") .. "' ;;\n"
        .. "  *) exit 9 ;;\nesac\n")
    T:must{ "chmod", "+x", r.abs .. "/bin/gh" }
    local argv = { PLAN, "script", "run", "scripts/lua/check-promote-gate.lua", "--" }
    for _, a in ipairs(o.args or { TAG }) do argv[#argv + 1] = a end
    local x = proc.run{ argv = argv, cwd = r.abs, timeout_ms = 60000,
        env = { PATH = r.abs .. "/bin:" .. env.get("PATH"), HOME = r.abs, TILLANDSIAS_PLAN_BIN = PLAN } }
    local lines = text.lines(text.trim(x.stdout or ""))
    return x.code, lines[#lines] or "", (x.stdout or "") .. (x.stderr or "")
end
local function refused(c, last, what) return c == 1 and last:find("^refused:promote%-gate:" .. TAG:gsub("%.", "%%.") .. ":") ~= nil and text.contains(last, what) end

local c, l, all = gate(ALL)
T:arm("1 PASS", c == 0 and l == "ok:promote-gate:" .. TAG .. ":linux=pass,darwin=pass,windows=pass:queue=idle", c .. " " .. all)
c, l, all = gate{ ALL[1], ALL[2], rec("windows", "pass", { tag = "v1.2.3.5" }) }
T:arm("2 MISSING another tag's record on the row is malformed, and windows is missing", refused(c, l, "windows=missing") and text.contains(l, "record=malformed"), c .. " " .. all)
c, l, all = gate{ ALL[1], ALL[2] }
T:arm("2 MISSING one platform is named", refused(c, l, "windows=missing") and not text.contains(l, "linux="), c .. " " .. all)
c, l, all = gate(with(rec("linux", "fail:lane", { ts = "2026-11-24T02:00:00Z" })))
T:arm("3 LATEST a later fail cancels a pass", refused(c, l, "linux=fail:lane"), c .. " " .. all)
c, l, all = gate{ rec("linux", "fail:lane", { ts = "2026-11-24T02:00:00Z" }), ALL[1], ALL[2], ALL[3] }
T:arm("3 LATEST by time, not by order written", refused(c, l, "linux=fail:lane"), c .. " " .. all)
c, l, all = gate(with(rec("linux", "fail:lane")))
T:arm("3 LATEST at the same instant the fail stands", refused(c, l, "linux=fail:lane"), c .. " " .. all)
c, l, all = gate(with(rec("linux", "fail:lane", { ts = "2026-11-24T00:30:00Z" })))
T:arm("3 LATEST an earlier fail does not outlive a later pass", c == 0, c .. " " .. all)
local PART = { ALL[1], rec("darwin", "partial:credential-unmeasured"), ALL[3] }
c, l, all = gate(PART)
T:arm("4 PARTIAL refuses unnamed", refused(c, l, "darwin=partial:credential-unmeasured"), c .. " " .. all)
c, l, all = gate(PART, { args = { TAG, "--allow-unmeasured", "darwin" } })
T:arm("4 PARTIAL counts when named, and is named in the verdict", c == 0 and text.contains(l, "darwin=partial:credential-unmeasured"), c .. " " .. all)
c, l, all = gate(PART, { args = { TAG, "--allow-unmeasured", "linux" } })
T:arm("4 PARTIAL naming another platform does not help", refused(c, l, "darwin=partial"), c .. " " .. all)
c, l, all = gate({ ALL[1], rec("darwin", "fail:lane"), ALL[3] }, { args = { TAG, "--allow-unmeasured", "darwin" } })
T:arm("4 PARTIAL naming a platform never excuses a fail", refused(c, l, "darwin=fail:lane"), c .. " " .. all)
c, l, all = gate{ ALL[1], ALL[2], rec("windows", "pass", { type = "note" }) }
T:arm("5 PROSE the same words on a note are no record", refused(c, l, "windows=missing"), c .. " " .. all)
c, l, all = gate(with(rec("linux", "", { sum = "smoke PASS on linux for " .. TAG, ts = "2026-11-24T02:00:00Z" })))
T:arm("6 MALFORMED a record nobody can read refuses", refused(c, l, "record=malformed"), c .. " " .. all)
c, l, all = gate{ ALL[1], ALL[2], rec("windows", "pass", { regime = "linux:wsl" }) }
T:arm("6 MALFORMED a regime of another platform refuses", refused(c, l, "record=malformed"), c .. " " .. all)
c, l, all = gate{ ALL[1], ALL[2], rec("windows", "pass", { regime = "windows:" .. string.rep("x", 150) }) }
T:arm("6 MALFORMED a record plan-events cut short refuses, never passes", refused(c, l, "record=malformed"), c .. " " .. all)
c, l, all = gate(ALL, { queue = "queue:gating:#7 work/0001-abcd phase=gate elapsed=5s train=- waiting=0" })
T:arm("7 QUEUE gating refuses", refused(c, l, "queue=gating"), c .. " " .. all)
c, l, all = gate(ALL, { noqueue = true })
T:arm("7 QUEUE unreadable refuses", refused(c, l, "queue=unreadable"), c .. " " .. all)
c, l, all = gate(ALL, { ahead = true })
T:arm("8 LEDGER trunk ahead of HEAD refuses", refused(c, l, "ledger=stale"), c .. " " .. all)
c, l, all = gate(ALL, { dirty = true })
T:arm("8 LEDGER a local plan edit refuses", refused(c, l, "ledger=dirty"), c .. " " .. all)
c, l, all = gate(ALL, { offline = true })
T:arm("9 OFFLINE is could-not-run", c == 3 and l:find("^could%-not%-run:promote%-gate:") ~= nil, c .. " " .. all)
c, l, all = gate(ALL, { args = { "1.2.3.4" } })
local c2, l2 = gate(ALL, { args = { TAG, "--allow-unmeasured", "solaris" } })
T:arm("10 USAGE", c == 2 and c2 == 2 and text.contains(all, "refused:promote-gate:usage"), c .. " " .. c2 .. " " .. all .. l2)
T:finish()
