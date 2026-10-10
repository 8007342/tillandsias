-- @trace order:1577-g96z, order:1570-k5yt, order:1577-57u3, spec:ci-release
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-carried-obligations.lua — scripts/lua/check-carried-obligations.lua on
-- CONSTRUCTED diffs in a scratch git repo (methodology carried_obligations,
-- 1570-k5yt). A Lua fixture on `tillandsias-plan script run`, not a .sh: the
-- guard's own change is DUE under the rule it implements, and a new shell
-- fixture would have added exactly the item its port removed — measured, the
-- guard said `due` on its own first draft for that reason.
--
-- Each arm is one of the guard's verdicts:
--   1 DUE        an edited scripts/check-x.sh with no port and no trailer prints
--                carried:shell-to-lua:due:<item> (<n> lines) and, on stderr, the
--                exact line `Carried-Waiver: shell-to-lua <reason>`; exit 0.
--   2 SILENT     the same change with --landing is refused (exit 1).
--   3 WAIVED     plus a `Carried-Waiver:` trailer: waived:<reason>, and landing
--                passes.
--   4 PAID       deleting a check-*.sh and adding its Lua port: paid:<path>.
--   5 SLACK      deleting a floor line for a file already gone is NOT paid.
--   6 NOT DUE    NEGATIVE CONTROL: a crates/-only change is not-due, exit 0,
--                never shown the obligation, even at landing.
--   7 OFFER      two refs one order apart are offered different items.
--   8 UNPARSED   a Carried-Waiver line NOT in the message's last paragraph (so
--                git does not parse it as a trailer) is named — "waiver present
--                but not a trailer" — and refused at landing as
--                violation:carried:shell-to-lua:waiver-not-a-trailer.
--   9 TAKEN      an open origin/work/* ref that deletes the smallest item makes
--                the guard skip it (`taken-by:work/<ref>` on stderr) and offer
--                another; two hosts ported the same offered item on 2026-10-10.
--  10 WRAPPER    a tiny exec shim is never offered as small: onto a population
--                script it is no item of its own; onto any other script it is
--                sized as the callee and named `wrapper-of:<callee>`.
--  11 WIDENED    porting a scripts/audit-*.sh (a backlog `population` glob
--                outside the ratchet's four prefixes) pays (1577-57u3).
--  12 WRAPPED    a wrapper counts once with its callee: porting the callee
--                alone does not pay; retiring both does.
--  13 COUNTER    the ok: line ends counter=shell-to-lua:<n>.
--  14 FIRED      --burndown over ten waived `Carried:` landings with a flat
--                counter prints trigger=fired; a not-due landing is not counted.
--  15 CLEAR      one paid landing that deletes an item clears the trigger.
--
-- PRE-GUARD CODE FAILS IT: with no check-carried-obligations.lua the first arm
-- refuses the whole fixture, never a skip.
--
-- Usage: tillandsias-plan script run scripts/lua/test-carried-obligations.lua [-- --plan <bin>]
-- The plan binary (to run the guard) is --plan, TILLANDSIAS_PLAN_BIN, or
-- TILLANDSIAS_SCRIPT_RUNNER_BIN (exported by build.sh's _run_lua_decider).

local GUARD_REL = "scripts/lua/check-carried-obligations.lua"
if not fs.exists(GUARD_REL) then
    verdict.emit("violation:carried-obligations-fixture:no-guard", 1,
        "scripts/lua/check-carried-obligations.lua does not exist — no tool says what a change owes (1577-g96z)")
end

local PLAN
for i = 1, #arg do if arg[i] == "--plan" then PLAN = arg[i + 1] end end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("carried-obligations-fixture", "no plan binary named (--plan, TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 120000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local top = run({ "git", "rev-parse", "--show-toplevel" })
local ROOT = text.trim(top.stdout or "")
local GUARD = ROOT .. "/" .. GUARD_REL

-- A per-run scratch dir under target/plan-scratch (never /tmp, never the
-- checkout proper), named from the clock so two runs do not collide.
local REL = "target/plan-scratch/carried-obligations-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
local R = ROOT .. "/" .. REL
local function write(rel, content) fs.write(REL .. "/" .. rel, content) end
local function G(args)
    local argv = { "git", "-c", "user.email=f@f", "-c", "user.name=f", "-c", "commit.gpgsign=false" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = run(argv, { cwd = R })
    if not (r.status == "exited" and r.code == 0) then
        verdict.could_not_run("carried-obligations-fixture", "git " .. table.concat(args, " ") .. " failed: " .. (r.stderr or ""))
    end
    return r
end

for _, d in ipairs({ "", "/methodology", "/scripts", "/scripts/portability", "/scripts/lua", "/crates" }) do fs.mkdir(REL .. d) end
write("methodology/convergence.yaml", table.concat({
    "carried_obligations:",
    "  window_size: 10",
    "  backlogs:",
    "    - name: shell-to-lua",
    "      stage: gentle",
    "      area:",
    "        - scripts/check-*.sh",
    "        - scripts/test-*.sh",
    "        - scripts/verify-*.sh",
    "        - scripts/guard-*.sh",
    "        - scripts/lua/**",
    "        - scripts/audit-*.sh",
    "        - scripts/gate-steps.d/**",
    "      population:",
    "        - scripts/check-*.sh",
    "        - scripts/test-*.sh",
    "        - scripts/verify-*.sh",
    "        - scripts/guard-*.sh",
    "        - scripts/audit-*.sh",
    "      population_excludes: scripts/portability/bootstrap-shell-allowlist.txt",
    "      item_ceiling_lines: 150", "" }, "\n"))
write("scripts/portability/bootstrap-shell-allowlist.txt", "# the shell that stays shell\n")
write("scripts/portability/shell-decider-floor.txt", "scripts/check-gone.sh\nscripts/check-x.sh\nscripts/check-y.sh\n")
local function n_lines(prefix, n) local t = {} for i = 1, n do t[i] = "echo " .. prefix .. i end return table.concat(t, "\n") .. "\n" end
write("scripts/check-x.sh", n_lines("x", 10))
write("scripts/check-y.sh", n_lines("y", 4))
write("scripts/check-w.sh", n_lines("w", 6))
write("scripts/test-z.sh", n_lines("z", 2))
-- Over the ceiling, so never offered, but counted (the widened population).
write("scripts/audit-x.sh", n_lines("a", 160))
write("crates/a.rs", "fn main() {}\n")
-- proc.run's command-policy audit writes .cache/metrics/ under a repo root
-- (1443-w9hf); gitignored in the real checkout, so ignored here too.
write(".gitignore", ".cache/\n")
G({ "init", "-q", "-b", "base" })
G({ "add", "-A" }); G({ "commit", "-qm", "base" })

local function change(ref) G({ "checkout", "-q", "base" }); G({ "checkout", "-q", "-B", ref, "base" }) end
local function judge(landing, base_ref, mode)
    local argv = { PLAN, "script", "run", GUARD }
    if landing then argv[#argv + 1] = "--"; argv[#argv + 1] = "--landing" end
    if mode then argv[#argv + 1] = "--"; argv[#argv + 1] = mode end
    local r = run(argv, { cwd = R, env = { TILLANDSIAS_REPO_ROOT = R, TILLANDSIAS_CARRIED_BASE = base_ref or "base" } })
    return (r.status == "exited" and r.code or -1), (r.stdout or ""), (r.stderr or "")
end
local function has_line(s, want) for _, l in ipairs(text.lines(s)) do if l == want then return true end end return false end
local function grep(s, re) for _, l in ipairs(text.lines(s)) do if text.is_match(l, re) then return l end end return nil end

local passed, failed = {}, {}
local function check(name, cond, why)
    if cond then passed[#passed + 1] = name; out.line("ok:   " .. name)
    else failed[#failed + 1] = name; out.line("FAIL: " .. name .. " — " .. why) end
end

-- 1 + 2. DUE, and SILENT at landing
change("work/1234-abcd")
write("scripts/check-x.sh", n_lines("x", 10) .. "echo edited\n")
G({ "commit", "-qam", "edit a shell decider" })
local rc, o, e = judge(false)
check("DUE: due:<item> (<n> lines) and the waiver line to paste; a work push exits 0",
    rc == 0 and grep(o, [[^carried:shell-to-lua:due:scripts/check-[a-z]+\.sh \([0-9]+ lines\)$]]) ~= nil
        and has_line(e, "Carried-Waiver: shell-to-lua <reason>"),
    "rc=" .. rc .. " out=[" .. o .. "] err=[" .. e .. "]")
rc, o = judge(true)
check("SILENT: the due change with neither port nor trailer is refused at landing (exit 1)",
    rc == 1 and has_line(o, "violation:carried:shell-to-lua:silent"), "rc=" .. rc .. " out=[" .. o .. "]")

-- 3. WAIVED
G({ "commit", "-q", "--allow-empty", "-m", "carry nothing this time", "-m", "Carried-Waiver: shell-to-lua too-big:scripts/check-y.sh:200" })
rc, o = judge(true)
check("WAIVED: the trailer is read and printed, and landing passes",
    rc == 0 and has_line(o, "carried:shell-to-lua:waived:too-big:scripts/check-y.sh:200"), "rc=" .. rc .. " out=[" .. o .. "]")

-- 4. PAID
change("work/1235-efgh")
G({ "rm", "-q", "scripts/check-y.sh" })
write("scripts/lua/check-y.lua", 'verdict.ok("y")\n')
write("scripts/portability/shell-decider-floor.txt", "scripts/check-gone.sh\nscripts/check-x.sh\n")
G({ "add", "-A" }); G({ "commit", "-qm", "port check-y to Lua" })
rc, o = judge(true)
check("PAID: deleting a check-*.sh and adding its Lua port prints paid:<that path>",
    rc == 0 and has_line(o, "carried:shell-to-lua:paid:scripts/check-y.sh"), "rc=" .. rc .. " out=[" .. o .. "]")

-- 5. SLACK
change("work/1236-ijkl")
write("scripts/portability/shell-decider-floor.txt", "scripts/check-x.sh\nscripts/check-y.sh\n")
G({ "commit", "-qam", "drop the floor line of a file already gone" })
rc, o = judge(true)
check("SLACK: removing a floor line for a file already gone is not paid (and not due)",
    rc == 0 and has_line(o, "carried:shell-to-lua:not-due") and not o:find(":paid:", 1, true), "rc=" .. rc .. " out=[" .. o .. "]")

-- 6. NOT DUE
change("work/1237-mnop")
write("crates/a.rs", 'fn main() { println!("x"); }\n')
G({ "commit", "-qam", "crates only" })
rc, o, e = judge(true)
check("NOT DUE: a crates/-only change prints not-due, is never shown the obligation, and exits 0 even at landing",
    rc == 0 and has_line(o, "carried:shell-to-lua:not-due") and not e:find("Carried-Waiver", 1, true),
    "rc=" .. rc .. " out=[" .. o .. "] err=[" .. e .. "]")

-- 7. OFFER
change("work/1240-qrst")
write("scripts/check-w.sh", n_lines("w", 6) .. "echo e1\n"); G({ "commit", "-qam", "e1" })
local _, oa = judge(false)
change("work/1241-uvwx")
write("scripts/check-w.sh", n_lines("w", 6) .. "echo e2\n"); G({ "commit", "-qam", "e2" })
local _, ob = judge(false)
local a, b = oa:match("due:(%S+)"), ob:match("due:(%S+)")
check("OFFER: refs one order apart are offered different items",
    a ~= nil and b ~= nil and a ~= b, "1240 offered [" .. tostring(a) .. "], 1241 offered [" .. tostring(b) .. "]")

-- 8. UNPARSED waiver
change("work/1238-unpa")
write("scripts/check-x.sh", n_lines("x", 10) .. "echo u\n")
G({ "commit", "-qa", "-m", "edit with a misplaced waiver", "-m", "Carried-Waiver: shell-to-lua too-big:scripts/check-y.sh:200",
    "-m", "A closing paragraph after the waiver, so git does not read it as a trailer." })
rc, o, e = judge(true)
check("UNPARSED: a waiver outside the last paragraph is named and refused at landing as waiver-not-a-trailer",
    rc == 1 and has_line(o, "violation:carried:shell-to-lua:waiver-not-a-trailer")
        and e:find("waiver present but not a trailer: move it to the last paragraph", 1, true) ~= nil,
    "rc=" .. rc .. " out=[" .. o .. "] err=[" .. e .. "]")

-- 9. TAKEN: another open work ref deletes the smallest item (check-y.sh)
change("work/9999-take")
G({ "rm", "-q", "scripts/check-y.sh" }); G({ "commit", "-qm", "another host ports check-y" })
local take_sha = text.trim(G({ "rev-parse", "HEAD" }).stdout)
G({ "update-ref", "refs/remotes/origin/work/9999-take", take_sha })
change("work/1000-tkn0") -- order 1000: without the skip, check-y.sh (smallest) is offered
write("scripts/check-x.sh", n_lines("x", 10) .. "echo t\n")
G({ "commit", "-qam", "edit while check-y is taken" })
rc, o, e = judge(false)
local offered = o:match("due:(%S+)")
check("TAKEN: the item another open work ref deletes is skipped with taken-by on stderr, and another is offered",
    rc == 0 and offered ~= nil and offered ~= "scripts/check-y.sh"
        and e:find("taken-by:work/9999-take scripts/check-y.sh", 1, true) ~= nil
        and not e:find("    scripts/check-y.sh (", 1, true),
    "rc=" .. rc .. " offered=[" .. tostring(offered) .. "] err=[" .. e .. "]")
G({ "update-ref", "-d", "refs/remotes/origin/work/9999-take" })

-- 10. WRAPPER: a tiny exec shim is never offered as small. Onto a POPULATION
-- script (check-big.sh) it is not an item of its own (counted with its callee,
-- arm 12). Onto a script OUTSIDE the population (tool-big.sh) it is that
-- script's only representative, stays counted, is sized as its callee and is
-- named wrapper-of.
change("work/1001-wrap")
write("scripts/check-big.sh", n_lines("b", 200))
write("scripts/check-shim.sh", '#!/usr/bin/env bash\nexec "$(dirname "$0")/check-big.sh" "$@"\n')
write("scripts/tool-big.sh", n_lines("t", 200))
write("scripts/check-tshim.sh", '#!/usr/bin/env bash\nexec "$(dirname "$0")/tool-big.sh" "$@"\n')
write("scripts/check-x.sh", n_lines("x", 10) .. "echo w\n")
G({ "add", "-A" }); G({ "commit", "-qm", "two shims, two big scripts, and an edit" })
rc, o, e = judge(false)
check("WRAPPER: neither exec shim is offered as small; the one onto a non-population script is named wrapper-of",
    rc == 0 and not o:find("shim.sh", 1, true) and not e:find("    scripts/check-shim.sh (", 1, true)
        and not e:find("    scripts/check-tshim.sh (", 1, true)
        and e:find("wrapper-of:scripts/tool-big.sh scripts/check-tshim.sh", 1, true) ~= nil,
    "rc=" .. rc .. " out=[" .. o .. "] err=[" .. e .. "]")

-- 11. WIDENED: a decider outside the four ratchet prefixes is counted, so its
-- port pays (1577-57u3; 1570-25iq needed an uncounted-item waiver for this).
change("work/1011-wide")
G({ "rm", "-q", "scripts/audit-x.sh" })
fs.mkdir(REL .. "/scripts/lua")
write("scripts/lua/audit-x.lua", 'verdict.ok("audit-x")\n')
G({ "add", "-A" }); G({ "commit", "-qm", "port audit-x to Lua" })
rc, o = judge(true)
check("WIDENED: porting scripts/audit-x.sh (a population glob outside check-/test-/verify-/guard-) prints paid",
    rc == 0 and has_line(o, "carried:shell-to-lua:paid:scripts/audit-x.sh"), "rc=" .. rc .. " out=[" .. o .. "]")

-- 12. WRAPPED: a wrapper counts ONCE with its callee. With work/1001-wrap
-- (shim + big) as the base, porting big alone leaves the shim counted in its
-- place and does not pay; porting both does.
G({ "checkout", "-q", "work/1001-wrap" }); G({ "checkout", "-q", "-B", "work/1012-wrpd" })
G({ "rm", "-q", "scripts/check-big.sh" })
fs.mkdir(REL .. "/scripts/lua")
write("scripts/lua/check-big.lua", 'verdict.ok("big")\n')
G({ "add", "-A" }); G({ "commit", "-qm", "port the callee only" })
local rc_a, o_a = judge(true, "work/1001-wrap")
G({ "rm", "-q", "scripts/check-shim.sh" }); G({ "commit", "-qm", "and retire the shim" })
local rc_b, o_b = judge(true, "work/1001-wrap")
check("WRAPPED: porting a wrapped callee alone does not pay (the shim counts in its place); retiring both does",
    rc_a == 1 and has_line(o_a, "violation:carried:shell-to-lua:silent")
        and rc_b == 0 and has_line(o_b, "carried:shell-to-lua:paid:scripts/check-big.sh"),
    "callee-only rc=" .. rc_a .. " out=[" .. o_a .. "]; both rc=" .. rc_b .. " out=[" .. o_b .. "]")

-- 13. COUNTER: the ok: line carries the backlog's counter at HEAD.
-- base: check-x, check-y, check-w, test-z, audit-x = 5 (check-gone is only a
-- floor line).
change("work/1013-cntr")
write("crates/a.rs", 'fn main() { println!("c"); }\n')
G({ "commit", "-qam", "crates only" })
rc, o = judge(false)
check("COUNTER: the ok: line ends counter=shell-to-lua:5 (the population at HEAD)",
    rc == 0 and grep(o, [[^ok:carried-obligations:.* counter=shell-to-lua:5$]]) ~= nil, "rc=" .. rc .. " out=[" .. o .. "]")

-- 14 + 15. BURNDOWN: land commits trailered `Carried:` on a first-parent
-- history. Ten waived with a flat counter fire the stall trigger; a not-due
-- landing inside the window is not counted. One paid landing that really
-- deletes an item among the ten clears it.
local function landing(msg, trailer) G({ "commit", "-q", "--allow-empty", "-m", msg, "-m", "Carried: " .. trailer }) end
G({ "checkout", "-q", "base" }); G({ "checkout", "-q", "-B", "trunk-fired" })
landing("land(0): an older one", "shell-to-lua paid scripts/check-older.sh")
for i = 1, 5 do landing("land(" .. i .. ")", "shell-to-lua waived no-item-in-reach") end
landing("land(n): crates only", "shell-to-lua not-due")
for i = 6, 10 do landing("land(" .. i .. ")", "shell-to-lua waived no-item-in-reach") end
rc, o, e = judge(false, "trunk-fired", "--burndown")
check("FIRED: ten waived due landings and a flat counter print trigger=fired (the not-due landing is not counted)",
    rc == 0 and has_line(o, "burndown:shell-to-lua:count=5:stage=gentle:window=10:paid=0:waived=10:silent=0:trigger=fired")
        and has_line(o, "ok:carried-burndown:backlogs=1 fired=1"),
    "rc=" .. rc .. " out=[" .. o .. "] err=[" .. e .. "]")
G({ "checkout", "-q", "base" }); G({ "checkout", "-q", "-B", "trunk-clear" })
for i = 1, 9 do landing("land(" .. i .. ")", "shell-to-lua waived no-item-in-reach") end
G({ "rm", "-q", "scripts/check-w.sh" })
G({ "commit", "-q", "-m", "land(10): port check-w", "-m", "Carried: shell-to-lua paid scripts/check-w.sh" })
rc, o = judge(false, "trunk-clear", "--burndown")
check("CLEAR: with one paid landing that deletes an item, the counter descends and trigger=clear",
    rc == 0 and has_line(o, "burndown:shell-to-lua:count=4:stage=gentle:window=10:paid=1:waived=9:silent=0:trigger=clear"),
    "rc=" .. rc .. " out=[" .. o .. "]")

run({ "rm", "-rf", R })

if #failed > 0 then
    verdict.emit("violation:carried-obligations-fixture:" .. #failed .. ":of:" .. (#passed + #failed), 1,
        "failed arms: " .. table.concat(failed, "; "))
end
verdict.ok("carried-obligations-fixture", #passed)
