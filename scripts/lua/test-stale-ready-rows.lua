-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:1144-jfr5, order:2031-dwwy
--
-- test-stale-ready-rows.lua — pins scripts/lua/check-stale-ready-rows.lua's
-- first pass (cites-the-order) in a hermetic scratch repo: candidates, the
-- three negative controls, the count-and-newest grammar, the closed-on suffix,
-- and exit 0. Ported from test-stale-ready-rows.sh with the guard (2031-dwwy);
-- the same eleven assertions. The real-tree arm asserts only the summary
-- grammar, since a live candidate is a coincidence.
--
-- PRE-PORT CODE FAILS IT: with no check-stale-ready-rows.lua the fixture
-- refuses at once, never a skip.
--
-- Usage: tillandsias-plan script run scripts/lua/test-stale-ready-rows.lua [-- --plan <bin>]

local GUARD_REL = "scripts/lua/check-stale-ready-rows.lua"
if not fs.exists(GUARD_REL) then
    verdict.emit("violation:stale-ready-rows-fixture:no-guard", 1, GUARD_REL .. " does not exist")
end

local PLAN
for i = 1, #(arg or {}) do if arg[i] == "--plan" then PLAN = arg[i + 1] end end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("stale-ready-rows-fixture", "no plan binary named (--plan, TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 120000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local top = run({ "git", "rev-parse", "--show-toplevel" })
local ROOT = text.trim(top.stdout or "")
local GUARD = ROOT .. "/" .. GUARD_REL

local REL = "target/plan-scratch/stale-ready-rows-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
local R = ROOT .. "/" .. REL
local function G(args)
    local argv = { "git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false" }
    for _, x in ipairs(args) do argv[#argv + 1] = x end
    local r = run(argv, { cwd = R .. "/repo" })
    if not (r.status == "exited" and r.code == 0) then
        verdict.could_not_run("stale-ready-rows-fixture", "git " .. table.concat(args, " ") .. " failed: " .. (r.stderr or ""))
    end
    return r
end

fs.mkdir(REL); fs.mkdir(REL .. "/repo")
G({ "init", "-q", "." })
local body = ""
local function c(msg)
    body = body .. msg .. "\n"
    fs.write(REL .. "/repo/f", body)
    G({ "add", "f" }); G({ "commit", "-q", "-m", msg })
end
c("fix(1001-aaaa): the first candidate")
c("claim(1002-bbbb): a claim is not work")
c("close(1003-cccc, 1004-dddd): two orders in one subject")
c("docs: mention 1005-eeee without the cite shape")
c("feat(1001-aaaab): a longer order that must not match 1001-aaaa")
c("fix(278): numeric order")
c("fix(1278-zzzz): must not match 278")
c("test(1001-aaaa): the second citing commit, newest")
fs.write(REL .. "/orders", "1001-aaaa\n1002-bbbb\n1003-cccc\n1005-eeee\n278\n# comment\n")

local function guard(extra)
    local argv = { PLAN, "script", "run", GUARD, "--", "--repo", R .. "/repo", "--orders-file", REL .. "/orders" }
    for _, x in ipairs(extra or {}) do argv[#argv + 1] = x end
    return run(argv)
end

local passes, fails = 0, 0
local function arm(name, cond, got)
    if cond then passes = passes + 1; out.line("ok: " .. name)
    else fails = fails + 1; out.line("FAIL: " .. name .. (got and (" — got: " .. got) or "")) end
end
local function has(o, pat) for _, l in ipairs(text.lines(o)) do if l:match(pat) then return l end end return nil end

local r = guard()
local o = r.stdout or ""
arm("exit 0 (advisory)", r.status == "exited" and r.code == 0, tostring(r.code))
local newest = text.trim(G({ "rev-parse", "--short", "HEAD" }).stdout or "")
arm("two citing commits counted, newest sha first", has(o, "^stale%-candidate:1001%-aaaa:2:" .. newest .. "$") ~= nil, has(o, "1001%-aaaa"))
arm("an order cited among several in one subject is a candidate", has(o, "^stale%-candidate:1003%-cccc:1:") ~= nil)
arm("a numeric order is bounded (278 found once, not via 1278)", has(o, "^stale%-candidate:278:1:") ~= nil, has(o, ":278:"))
arm("NEGATIVE CONTROL: claim(<order>) is not a candidate", has(o, "1002%-bbbb") == nil)
arm("NEGATIVE CONTROL: a mention without (<order>) is not a candidate", has(o, "1005%-eeee") == nil)
arm("NEGATIVE CONTROL: an order not in the ready list is never reported", has(o, "1004%-dddd") == nil)
arm("summary grammar: 3 candidates of 5 ready rows", has(o, "^ok:stale%-ready%-rows:3/5:pass=cites%-order$") ~= nil, o)

-- CLOSED-ON ARM (the closure direction): a sibling branch carries a status
-- fragment closing 1003-cccc that the "trunk" branch does not have; the
-- candidate line must say so. Negative control: 1001-aaaa has no such fragment.
G({ "branch", "-q", "trunk-sim" })
G({ "checkout", "-q", "-b", "sib-sim" })
fs.mkdir(REL .. "/repo/plan"); fs.mkdir(REL .. "/repo/plan/index.d")
fs.write(REL .. "/repo/plan/index.d/20260913t130000z-close-sib.yaml",
    "status:\n  - packet_id: pkt-cccc\n    field: status\n    value: completed\n    ts: \"2026-09-13T13:00:00Z\"\n    host: sib\n")
G({ "add", "plan/index.d" }); G({ "commit", "-q", "-m", "plan(1003-cccc): closed on the sibling" })
G({ "checkout", "-q", "trunk-sim" })
fs.write(REL .. "/orders", "1001-aaaa\tpkt-aaaa\n1003-cccc\tpkt-cccc\n")
local o2 = guard({ "--siblings", "sib-sim", "--trunk", "trunk-sim" }).stdout or ""
arm("a candidate closed on a sibling branch says closed-on:<branch>", has(o2, "^stale%-candidate:1003%-cccc:1:%x+:closed%-on:sib%-sim$") ~= nil, has(o2, "1003"))
arm("NEGATIVE CONTROL: a candidate with no sibling closure has no closed-on suffix", has(o2, "^stale%-candidate:1001%-aaaa:2:%x+$") ~= nil, has(o2, "1001"))

-- Real tree: grammar only.
local real = run({ PLAN, "script", "run", GUARD }, { env = { TILLANDSIAS_PLAN_BIN = PLAN } })
local last = text.lines(text.trim(real.stdout or ""))
last = last[#last] or ""
arm("real tree: summary grammar holds (" .. last .. ")", last:match("^ok:stale%-ready%-rows:%d+/%d+:pass=cites%-order") ~= nil, last)

out.line("stale-ready-rows fixture: " .. passes .. " passed, " .. fails .. " failed")
if fails == 0 then verdict.emit("ok:stale-ready-rows-fixture:all", 0) end
verdict.emit("violation:stale-ready-rows-fixture:failed=" .. fails, 1)
