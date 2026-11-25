-- @env PATH HOME
-- @trace order:1367-emjg, order:2253-iher
--
-- test-landed-but-open.lua — scripts/lua/check-landed-but-open.lua lists the
-- orders a CODE landing cites whose ledger row is still open, and nothing else.
-- Scratch repo; statuses from --status-file. Ported from
-- scripts/test-landed-but-open.sh (order 2253-iher pays the carried shell-to-lua
-- item); same arms and verdict line.
--
--   1  a code landing citing a READY order is listed (order, status, sha)
--   2  a code landing citing a COMPLETED order is not
--   3  a PLAN-ONLY commit citing a ready order is not a landing, not counted
--   4  an order named only in a commit BODY is not listed by default, and is
--      with --cite message
--   6  spec-only and docs-only commits citing a ready order are not landings
--      (1483-8zct); the code landing is still a suspect
--   5  the summary's total equals the number of suspect lines, and the exit is
--      0 with suspects present (advisory)
--
-- The door's env allowlist already drops PROJECT_ROOT/TILLANDSIAS_REPO_ROOT, so
-- the checker reads the SCRATCH repo's history, never the real checkout's
-- (2093-lbop's failure shape).
--
-- Usage: tillandsias-plan script run scripts/lua/test-landed-but-open.lua
-- Verdict: PASS: landed-but-open <p>/<n> (1367-emjg) then ok:landed-but-open:<p>/<n>
--          or FAIL: ... then violation:landed-but-open:<n>-failed

local fixture = require "common.fixture"
local ROOT = fixture.repo_root()
local C = ROOT .. "/scripts/lua/check-landed-but-open.lua"
local PLAN = fixture.plan_binary()
local pass, fail = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) out.line("FAIL: " .. m); fail = fail + 1 end
local REL = "target/plan-scratch/landed-but-open-" .. tostring(time.now_ms())
local W = ROOT .. "/" .. REL
local function finish()
    proc.run({ argv = { "rm", "-rf", W }, timeout_ms = 60000 })
    local total = pass + fail
    if fail == 0 then
        out.line("PASS: landed-but-open " .. pass .. "/" .. total .. " (1367-emjg)")
        verdict.emit("ok:landed-but-open:" .. pass .. "/" .. total, 0)
    end
    out.line("FAIL: landed-but-open " .. pass .. "/" .. total .. " (1367-emjg)")
    verdict.emit("violation:landed-but-open:" .. fail .. "-failed", 1)
end
if not PLAN or PLAN == "" then bad("no plan binary resolves"); finish() end
if not fs.exists("scripts/lua/check-landed-but-open.lua") then bad("arm 1: " .. C .. " does not exist"); finish() end

local R = W .. "/repo"
for _, d in ipairs({ "/repo/src", "/repo/plan/index.d", "/repo/openspec/specs/x", "/repo/docs" }) do fs.mkdir(REL .. d) end
fs.write(REL .. "/gitconfig", "[user]\n\tname = t\n\temail = t@example.invalid\n")
local GE = { PATH = env.get("PATH"), HOME = env.get("HOME"), GIT_CONFIG_GLOBAL = W .. "/gitconfig", GIT_CONFIG_NOSYSTEM = "1" }
local function git(args)
    local argv = { "git", "-C", R }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    return proc.run({ argv = argv, env = GE, timeout_ms = 60000 })
end
git({ "init", "-q", "-b", "main" })
local n = 0
local function commit(path, msg)
    n = n + 1
    local p = REL .. "/repo/" .. path
    local cur = fs.exists(p) and (fs.read(p) or "") or ""
    fs.write(p, cur .. tostring(n) .. "\n")
    git({ "add", "-A" }); git({ "commit", "-q", "-m", msg })
end
commit("src/a.rs", "feat(1111-aaaa): the landed-but-open one")
local A_SHA = text.trim(git({ "rev-parse", "--short=12", "HEAD" }).stdout or "")
commit("src/b.rs", "fix(2222-bbbb): landed and closed")
commit("plan/index.d/x.yaml", "plan(3333-cccc): claim")
commit("src/c.rs", "refactor: tidy\n\nContext: see 4444-dddd for why.")
-- 1483-8zct: a spec-only and a docs-only commit citing a READY order (the
-- 1438-pk9j shape): neither is a landing.
commit("openspec/specs/x/spec.md", "spec(5555-eeee): the requirement lands before the code")
commit("docs/y.md", "docs(5555-eeee): describe it")
fs.write(REL .. "/status", "1111-aaaa ready\n2222-bbbb completed\n3333-cccc ready\n4444-dddd ready\n5555-eeee ready\n")

local function run(extra)
    local argv = { PLAN, "script", "run", C, "--", "--ref", "HEAD", "--since", "1 day ago", "--status-file", W .. "/status" }
    for _, a in ipairs(extra or {}) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, cwd = R, env = GE, timeout_ms = 120000 })
    return r.stdout or "", r.code
end
local function has(o, s) return o:find(s, 1, true) ~= nil end
local function line_starts(o, p)
    for _, l in ipairs(text.lines(o)) do if l:sub(1, #p) == p then return true end end
    return false
end
local o, rc = run()

if line_starts(o, "suspect:1111-aaaa:ready:" .. A_SHA .. " ") then
    ok("arm 1: a code landing citing a ready order is listed with its status and sha")
else bad("arm 1: [" .. o .. "]") end
if not has(o, "2222-bbbb") then ok("arm 2: a landing citing a completed order is not listed") else bad("arm 2: [" .. o .. "]") end
if not has(o, "3333-cccc") and has(o, " landings=3 ") then
    ok("arm 3: a plan-only commit is not a landing (3 landings counted of 4 commits)")
else bad("arm 3: [" .. o .. "]") end
local wide = run({ "--cite", "message" })
if not has(o, "4444-dddd") and line_starts(wide, "suspect:4444-dddd:ready:") then
    ok("arm 4: a body-only mention is not a citation by default, and is with --cite message")
else bad("arm 4: default=[" .. o .. "] wide=[" .. wide .. "]") end
if not has(o, "5555-eeee") and has(o, " landings=3 ") and line_starts(o, "suspect:1111-aaaa:ready:") then
    ok("arm 6: spec-only and docs-only commits citing a ready order are not landings (1483-8zct); the code landing (arm 1) is still a suspect")
else bad("arm 6: [" .. o .. "]") end
local nsus = 0
for _, l in ipairs(text.lines(o)) do if l:sub(1, 8) == "suspect:" then nsus = nsus + 1 end end
local total = o:match("summary:landed%-but%-open:(%d+) ")
if rc == 0 and total and tonumber(total) == nsus then
    ok("arm 5: the summary total (" .. total .. ") equals the suspect lines, and the exit is 0 (advisory)")
else bad("arm 5: rc=" .. tostring(rc) .. " total=[" .. tostring(total) .. "] lines=" .. nsus) end
finish()
