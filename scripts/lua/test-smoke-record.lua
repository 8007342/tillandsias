-- @env PATH TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:2300-j4cv, spec:ci-release
--
-- test-smoke-record.lua — the whole chain on a scratch repo with a scratch origin: the
-- real attest-smoke.lua, then smoke-record.lua, then check-promote-gate.lua reading the
-- ledger the records wrote, with only `gh` stubbed.
--
--   1 CHAIN     three platforms attested and recorded: the gate says ok
--   2 VALID     the fragments load in a strict plan check; one row, one order
--   3 DERIVED   a partial attestation records partial and the gate blocks on it
--   4 UPGRADE   attested again as pass, recorded again: the gate says ok
--   5 RACE      two hosts that each declare the row write the same declaration, and both
--               records are in the fold
--   6 UNPUSHED  an attestation origin does not hold is refused, nothing written
--   7 FOREIGN   a ref whose Smoke: line names another tag, platform or sha is refused
--   8 NONE      no attestation, an unknown tag, a malformed tag and no plan binary are refused
--   9 AGAIN     recording the same attestation twice changes nothing
--  10 LONG      a line plan-events would cut is refused
--  11 RAW       an attestation whose tree is not digests only, or whose verdict.txt disagrees
--               with its Smoke: line, is refused
--
-- Usage: tillandsias-plan script run scripts/lua/test-smoke-record.lua
-- Verdict: ok:smoke-record-fixture:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("smoke-record-fixture")
local PLAN = fixture.plan_binary()
-- A native Windows spawn cannot start the extensionless #!/bin/sh `gh` stub, and C:/… on
-- PATH splits at the drive (yolanda 2026-11-24). There, and only there, the COPY of the gate
-- names the stub through a shell. Never an env override in the gate itself: a promotion gate
-- does not take its gh from the environment.
local function gate_source(r)
    local src = fs.read("scripts/lua/check-promote-gate.lua")
    local to = '{ "' .. fixture.posix_shell() .. '", "' .. r.abs .. '/bin/gh", '
    local win, n = src:gsub('{ "gh", ', function() return to end)
    if n ~= 3 then T:refuse("setup-failed", "the gate calls gh at " .. n .. " sites, not 3") end
    return r.abs:match("^%a:/") and win or src
end
local TAG, ASSET = "v1.2.3.4", string.rep("ab", 32)
local GENV = { PATH = env.get("PATH"), GIT_AUTHOR_NAME = "f", GIT_AUTHOR_EMAIL = "f@x", GIT_COMMITTER_NAME = "f", GIT_COMMITTER_EMAIL = "f@x",
    GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_NOSYSTEM = "1", TILLANDSIAS_SMOKE_HOST = "fxhost", TILLANDSIAS_PLAN_BIN = PLAN }
local function sh(r, argv, extra)
    local e = {}; for k, v in pairs(GENV) do e[k] = v end; for k, v in pairs(extra or {}) do e[k] = v end
    local x = proc.run{ argv = argv, cwd = r.abs, env = e, timeout_ms = 120000 }
    return x.status == "exited" and x.code or -1, text.trim((x.stdout or "") .. (x.stderr or ""))
end
local function git(r, ...)
    local c, o = sh(r, { "git", "-C", r.abs, "-c", "commit.gpgsign=false", ... })
    if c ~= 0 then T:refuse("setup-failed", o) end
    return o
end
local function script(r, name, ...)
    local a = { PLAN, "script", "run", "scripts/lua/" .. name, "--" }
    for _, x in ipairs{ ... } do a[#a + 1] = x end
    return sh(r, a, { PATH = r.abs .. "/bin:" .. env.get("PATH"), HOME = r.abs })
end
local n = 0
local function world()
    n = n + 1
    local r = T:git_repo("w" .. n)
    r.origin = r.abs .. "-origin.git"
    T:must{ "git", "init", "-q", "--bare", r.origin }
    git(r, "remote", "add", "origin", r.origin)
    for _, f in ipairs{ "attest-smoke.lua", "smoke-record.lua", "check-promote-gate.lua" } do
        fs.mkdir(r.rel .. "/scripts/lua"); fs.write(r.rel .. "/scripts/lua/" .. f, f == "check-promote-gate.lua" and gate_source(r) or fs.read("scripts/lua/" .. f))
    end
    fs.mkdir(r.rel .. "/plan/index.d"); fs.mkdir(r.rel .. "/bin"); fs.mkdir(r.rel .. "/ev")
    fs.write(r.rel .. "/plan/index.yaml", "packets: []\n")
    fs.write(r.rel .. "/.gitignore", "ev/\nbin/\n")
    fs.write(r.rel .. "/ev/00-run-start.txt", "run_start=x\n")
    T:must{ "touch", "-t", "202001010000", r.abs .. "/ev/00-run-start.txt" }
    git(r, "add", "-A"); git(r, "commit", "-qm", "rc"); git(r, "tag", TAG)
    r.sha = git(r, "rev-parse", "HEAD")
    return r
end
local function attest(r, plat, v, o)
    o = o or {}
    fs.write(r.rel .. "/ev/credential-step.txt", (v == "pass" and "measured: signed in" or "unmeasured: not signed in") .. "\n")
    local a = { "--sha", r.sha, "--tag", o.tag or TAG, "--asset-sha256", ASSET, "--verdict", v, "--dir", r.abs .. "/ev", "--platform", plat, "--regime", o.regime or "fixture" }
    if not o.nopush then a[#a + 1] = "--push" end
    -- the runner drops a planted GIT_COMMITTER_DATE, so a re-attestation waits out the second
    if o.later then T:must{ "sleep", "1.2" } end
    local argv = { PLAN, "script", "run", "scripts/lua/attest-smoke.lua", "--" }
    for _, x in ipairs(a) do argv[#argv + 1] = x end
    local c, out_ = sh(r, argv)
    if c ~= 0 then T:refuse("setup-failed", "attest " .. plat .. " " .. v .. ": " .. out_) end
end
local function record(r, plat, ...) return script(r, "smoke-record.lua", "--tag", TAG, "--platform", plat, ...) end
local function gate(r)
    git(r, "add", "-A"); git(r, "commit", "-q", "--allow-empty", "-m", "ledger")
    local head = git(r, "rev-parse", "HEAD")
    fs.write(r.rel .. "/bin/gh", "#!/bin/sh\ncase \"$*\" in\n  *heads/linux-next*) echo " .. head
        .. " ;;\n  *queue/status*) echo abc123 ;;\n  *git/commits/abc123*) echo 'queue:idle last-land=a 1s' ;;\n  *) exit 9 ;;\nesac\n")
    T:must{ "chmod", "+x", r.abs .. "/bin/gh" }
    return script(r, "check-promote-gate.lua", TAG)
end
local function frags(r) return text.lines(git(r, "ls-files", "-o", "-c", "plan/index.d")) end

local r = world()
for _, p in ipairs{ "linux", "darwin", "msys" } do attest(r, p, "pass") end
local ok3 = true
local outs = ""
for _, p in ipairs{ "linux", "darwin", "msys" } do local c, o = record(r, p); ok3 = ok3 and c == 0; outs = outs .. o .. " " end
local c, o = gate(r)
T:arm("1 CHAIN three platforms attested and recorded: the gate says ok", ok3 and c == 0 and text.contains(o, "ok:promote-gate:" .. TAG .. ":linux=pass,darwin=pass,windows=pass:queue=idle"), outs .. c .. " " .. o)
local pc, po = sh(r, { PLAN, "check", "--strict-fragments" })
local decl = 0
for _, f in ipairs(frags(r)) do if f ~= "" and text.contains(fs.read(r.rel .. "/" .. f), "\npackets:") then decl = decl + 1 end end
T:arm("2 VALID the fragments load strictly, and only the first declares the row", pc == 0 and decl == 1 and #frags(r) == 3, pc .. " decl=" .. decl .. " " .. po)
c, o = record(r, "linux")
local dirty = git(r, "status", "--porcelain", "--", "plan")
T:arm("9 AGAIN recording the same attestation twice changes nothing", c == 0 and dirty == "", c .. " " .. o .. " " .. dirty)

r = world()
attest(r, "linux", "pass"); attest(r, "msys", "pass"); attest(r, "darwin", "partial:credential-unmeasured")
for _, p in ipairs{ "linux", "darwin", "msys" } do record(r, p) end
c, o = gate(r)
T:arm("3 DERIVED a partial attestation records partial and blocks", c == 1 and text.contains(o, "darwin=partial:credential-unmeasured") and not text.contains(o, "linux="), c .. " " .. o)
attest(r, "darwin", "pass", { later = true })
local rc = record(r, "darwin")
c, o = gate(r)
T:arm("4 UPGRADE attested again as pass, recorded again: ok", rc == 0 and c == 0, rc .. " " .. c .. " " .. o)

r = world()
attest(r, "linux", "pass"); attest(r, "darwin", "pass"); attest(r, "msys", "pass")
record(r, "linux")
local f1 = frags(r)[1]
local b1 = fs.read(r.rel .. "/" .. f1)
T:must{ "rm", "-f", r.abs .. "/" .. f1 }
record(r, "darwin")
local b2 = fs.read(r.rel .. "/" .. frags(r)[1])
fs.write(r.rel .. "/" .. f1, b1)
record(r, "msys")
local d1, d2 = b1:match("(\npackets:.-\n)events:"), b2:match("(\npackets:.-\n)events:")
c, o = gate(r)
pc, po = sh(r, { PLAN, "check", "--strict-fragments" })
T:arm("5 RACE two hosts write the same declaration and both records are in the fold", d1 ~= nil and d1 == d2 and c == 0 and pc == 0, tostring(d1 == d2) .. " " .. c .. " " .. o .. " " .. po)

r = world()
attest(r, "linux", "pass", { nopush = true })
c, o = record(r, "linux")
T:arm("6 UNPUSHED an attestation origin does not hold is refused, nothing written", c == 2 and text.contains(o, "refused:smoke-record:attestation-not-on-origin") and #frags(r) == 0 or (c == 2 and frags(r)[1] == ""), c .. " " .. o)

r = world()
attest(r, "linux", "pass", { tag = "v1.2.3.5" })
c, o = record(r, "linux")
local c2, o2
attest(r, "darwin", "pass")
local dref = git(r, "rev-parse", "refs/attest/smoke/darwin/" .. r.sha)
git(r, "update-ref", "refs/attest/smoke/msys/" .. r.sha, dref)
git(r, "push", "-q", "origin", "refs/attest/smoke/msys/" .. r.sha)
c2, o2 = record(r, "msys")
T:arm("7 FOREIGN another tag, or another platform's attestation under this name, is refused",
    c == 2 and c2 == 2 and text.contains(o, "attestation-is-not-this-run") and text.contains(o2, "attestation-is-not-this-run"), c .. " " .. o .. " / " .. c2 .. " " .. o2)

r = world()
c, o = record(r, "linux")
c2, o2 = script(r, "smoke-record.lua", "--tag", "v9.9.9.9", "--platform", "linux")
local c3, o3 = script(r, "smoke-record.lua", "--tag", "1.2.3", "--platform", "linux")
attest(r, "linux", "pass")
local c4, o4 = sh(r, { PLAN, "script", "run", "scripts/lua/smoke-record.lua", "--", "--tag", TAG, "--platform", "linux" }, { TILLANDSIAS_PLAN_BIN = r.abs .. "/absent", TILLANDSIAS_SCRIPT_RUNNER_BIN = "" })
T:arm("8 NONE", c == 2 and c4 == 2 and text.contains(o4, "no-plan-binary") and c2 == 2 and c3 == 2 and text.contains(o, "no-attestation") and text.contains(o2, "unknown-tag") and text.contains(o3, "bad-tag"), o .. " / " .. o2 .. " / " .. o3 .. " / " .. o4)

r = world()
attest(r, "linux", "pass", { regime = string.rep("x", 90) })
c, o = record(r, "linux")
T:arm("10 LONG a line plan-events would cut is refused", c == 2 and text.contains(o, "refused:smoke-record:too-long"), c .. " " .. o)
r = world()
attest(r, "linux", "pass")
local lref = "refs/attest/smoke/linux/" .. r.sha
local function forge(tree)
    local msg = git(r, "log", "-1", "--format=%B", lref)
    git(r, "update-ref", lref, git(r, "commit-tree", tree, "-m", msg)); git(r, "push", "-qf", "origin", lref)
end
fs.write(r.rel .. "/ev/verdict.txt", "fail:lane\n")
local good = git(r, "rev-parse", lref .. "^{tree}")
forge(git(r, "rev-parse", "HEAD^{tree}"))
c, o = record(r, "linux")
local ls = T:must{ "git", "-C", r.abs, "ls-tree", good }.stdout
local other = git(r, "hash-object", "-w", r.abs .. "/ev/verdict.txt")
local mk = proc.run{ argv = { "git", "-C", r.abs, "mktree" }, stdin = (ls:gsub("(blob )%x+(\tverdict)", "%1" .. other .. "%2")), timeout_ms = 30000 }
forge(text.trim(mk.stdout or ""))
c2, o2 = record(r, "linux")
T:arm("11 RAW a tree that is not digests only, or that disagrees with its line, is refused", c == 2 and text.contains(o, "not-digest-only") and c2 == 2 and text.contains(o2, "disagrees-with-itself"), c .. " " .. o .. " / " .. c2 .. " " .. o2)
T:finish()
