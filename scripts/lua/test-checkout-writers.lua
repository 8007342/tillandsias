-- @trace order:1611-imnj
-- @env PATH TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-checkout-writers.lua — both exit criteria of 1611-imnj.
--
-- THE SCAN (scripts/lua/check-checkout-writers.lua) on CONSTRUCTED roots:
--   1 TMPDIR     scratch made under ${TMPDIR:-/tmp} is no writer: writers=0
--   2 PLANTED    a $$ path in scripts/, undeclared: unsafe, named
--   3 MKTEMP     mktemp -d "$ROOT/.x.XXXXXX": unsafe, named
--   4 IGNORED    scratch under target/ is ignored-scratch, and a per-run
--                .tillandsias/fixture-scratch/<guard>.$$ with an EXIT trap is
--                fixture-scratch: writers=0 for both
--   4b FLAT      a flat name directly in fixture-scratch/ stays unsafe
--   4c NO-TRAP   a per-run fixture-scratch subdir with no EXIT trap is unsafe
--   5 DECLARED   a declared writer with the 1587 shape (EXIT trap, a TERM
--                handler function that exits, wait): ok, listed with its reason
--   6 NO-EXIT    declared, but its TERM handler only cleans up: unsafe
--   7 STALE      a declared file that no longer writes: stale-declared
--   8 COMMENT    a commented-out writer is not one
--   9 EMPTY      no scripts: could-not-run, exit 3
-- THE LUA POPULATION (2287-mg7v):
--  12 PRE-FIX   the three real Lua writers of 2026-11-24, as they were at LUA_PRE_REV, are each
--               counted by path (two hold the path in a local); as they are now, none is
--  13 SAFE      fs.write under target/, a kit .rel dir, and an assignment inside an embedded
--               long string are not writers
--  14 UNRESOLVED a function parameter is counted apart and named, never refused, never safe
--  15 DECLARED  a declared Lua writer needs artifacts=: without it unsafe, with it listed
--  16 NUMBERS   the line names how many .sh and how many .lua were scanned
--  17 MUTANT    with local-following removed, the two local-held writers go uncounted
-- THE DOOR KILL, in one run, on scripts/test-litmus-step-pipefail.sh: the
-- pre-fix file (git show PRE_REV, the trunk commit before the move) and the
-- file as it stands. Each is held in ARM 3, while its runner copy exists, by a
-- `timeout` shim that holds only for that copy. Then the door's KILL lands:
-- KILL to the pid (and its group), and the guard's TMPDIR is deleted.
--  10 PRE-FIX    the copy is left in scripts/ (the defect)
--  11 POST-FIX   nothing is left in the checkout
-- THE CONTROL SENDS KILL DIRECTLY, standing in for the door's KILL landing.
-- KILL cannot be caught, so no trap runs on any OS: the pre-fix EXIT trap never
-- removes the copy, and the post-fix copy is in the deleted TMPDIR. The door
-- itself sends TERM first, and whether TERM ends the guard before the KILL is
-- platform behaviour. On darwin, bash with an EXIT trap does not die on TERM
-- while it waits in $(...), so the KILL lands, which is how the leak that
-- filed this row happened. On Linux, TERM runs the trap and the pre-fix code
-- cleans up after itself (1611's first version used TERM-then-KILL as its
-- control and was evicted on the Linux gate for exactly that). That sequence
-- is still run once on the pre-fix file and printed as an `observed:` line,
-- asserting nothing.
--
-- Usage: tillandsias-plan script run scripts/lua/test-checkout-writers.lua

local PRE_REV = "c1a390082"
local SUBJECT_REL = "scripts/lua/check-checkout-writers.lua"
if not fs.exists(SUBJECT_REL) then
    verdict.emit("violation:checkout-writers-fixture:no-subject", 1, SUBJECT_REL .. " does not exist (1611-imnj)")
end
local PLAN = env.get("TILLANDSIAS_PLAN_BIN")
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("checkout-writers-fixture", "no plan binary named (TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("checkout-writers-fixture", "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/checkout-writers-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)

local failed, ran = {}, 0
local function arm(name, cond, got)
    ran = ran + 1
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. got)
        failed[#failed + 1] = name
    end
end

-- ── the scan ───────────────────────────────────────────────────────────────
local function root_with(name, files, declared)
    local d = REL .. "/" .. name
    fs.mkdir(d .. "/scripts")
    for f, body in pairs(files) do fs.write(d .. "/scripts/" .. f, body) end
    fs.write(d .. "/declared.txt", declared or "")
    return d
end
local function scan(d)
    local r = proc.run({ argv = { PLAN, "script", "run", SUBJECT_REL }, cwd = ROOT, timeout_ms = 60000,
        env = { TILLANDSIAS_CHECKOUT_WRITERS_SCAN_DIR = d .. "/scripts",
                TILLANDSIAS_CHECKOUT_WRITERS_DECLARED = d .. "/declared.txt" } })
    return r.code or -1, text.trim(r.stdout or "")
end

local SHAPED = table.concat({
    "cleanup() { rm -f \"$P\"; }",
    "trap cleanup EXIT",
    "on_signal() {",
    "    cleanup; trap - EXIT; exit \"$1\"",
    "}",
    "trap 'on_signal 143' TERM; trap 'on_signal 130' INT; trap 'on_signal 129' HUP",
    "P=\"$ROOT/scripts/.copy.$$.sh\"",
    "cp a \"$P\"; bash \"$P\" & wait \"$!\"",
    "" }, "\n")

local rc, o = scan(root_with("tmpdir", { ["test-a.sh"] = "W=\"$(mktemp -d \"${TMPDIR:-/tmp}/a.XXXXXX\")\"\nP=\"$W/copy.$$.sh\"\n" }))
arm("1 TMPDIR scratch under ${TMPDIR:-/tmp} is no writer",
    rc == 0 and o:find(":writers=0:unsafe=0:ignored-scratch=0", 1, true) ~= nil, rc .. " " .. o)

local d = root_with("planted", { ["test-b.sh"] = "trap 'rm -f \"$P\"' EXIT\nP=\"$ROOT/scripts/.prefix-runner.$$.sh\"\n" })
rc, o = scan(d)
arm("2 PLANTED a $$ copy in scripts/, undeclared, is unsafe and named",
    rc == 1 and o:find("unsafe:" .. d .. "/scripts/test-b.sh:scratch-in-the-checkout", 1, true) ~= nil, rc .. " " .. o)

d = root_with("mktemp", { ["test-c.sh"] = "W=\"$(mktemp -d \"$ROOT/.c.XXXXXX\")\"\n" })
rc, o = scan(d)
arm("3 MKTEMP a dotdir at the checkout root is unsafe and named",
    rc == 1 and o:find("unsafe:" .. d .. "/scripts/test-c.sh:", 1, true) ~= nil, rc .. " " .. o)

rc, o = scan(root_with("ignored", {
    ["test-d.sh"] = "W=\"$ROOT/.tillandsias/fixture-scratch/test-d.$$\"\ntrap 'rm -rf \"$W\"' EXIT\nrm -rf \"$W\"; mkdir -p \"$W\"\n",
    ["test-e.sh"] = "W=\"$ROOT/target/plan-scratch/e.$$\"\n" }))
arm("4 IGNORED target/ scratch and a per-run fixture-scratch subdir are counted apart, not as writers",
    rc == 0 and o:find(":writers=0:unsafe=0:ignored-scratch=1:fixture-scratch=1", 1, true) ~= nil, rc .. " " .. o)

d = root_with("flat", { ["test-d2.sh"] = "trap 'rm -rf \"$W\"' EXIT\nW=\"$(mktemp -d \"$ROOT/.tillandsias/fixture-scratch/d.XXXXXX\")\"\n" })
rc, o = scan(d)
arm("4b FLAT a flat name directly in fixture-scratch/ stays unsafe (the door cannot find it by pid)",
    rc == 1 and o:find("unsafe:" .. d .. "/scripts/test-d2.sh:scratch-in-the-checkout", 1, true) ~= nil, rc .. " " .. o)

d = root_with("notrap", { ["test-d3.sh"] = "W=\"$ROOT/.tillandsias/fixture-scratch/test-d3.$$\"\nmkdir -p \"$W\"\n" })
rc, o = scan(d)
arm("4c NO-TRAP a per-run fixture-scratch subdir with no EXIT trap is unsafe",
    rc == 1 and o:find("unsafe:" .. d .. "/scripts/test-d3.sh:fixture-scratch-without-exit-trap", 1, true) ~= nil, rc .. " " .. o)

d = REL .. "/declared"
root_with("declared", { ["test-f.sh"] = SHAPED }, d .. "/scripts/test-f.sh it must sit beside its producers\n")
rc, o = scan(d)
arm("5 DECLARED a declared writer with the 1587 shape passes and is listed with its reason",
    rc == 0 and o:find("note:checkout-writer:" .. d .. "/scripts/test-f.sh:kept-in-checkout:it must sit beside its producers", 1, true) ~= nil
    and o:find(":writers=1:unsafe=0:", 1, true) ~= nil, rc .. " " .. o)

d = REL .. "/noexit"
root_with("noexit", { ["test-g.sh"] = (SHAPED:gsub("cleanup; trap %- EXIT; exit \"%$1\"", "cleanup")) },
    d .. "/scripts/test-g.sh it must sit beside its producers\n")
rc, o = scan(d)
arm("6 NO-EXIT a TERM handler that only cleans up lets the script carry on: unsafe",
    rc == 1 and o:find("unsafe:" .. d .. "/scripts/test-g.sh:no-term-trap-that-exits", 1, true) ~= nil, rc .. " " .. o)

d = REL .. "/stale"
root_with("stale", { ["test-h.sh"] = "echo nothing\n" }, d .. "/scripts/test-h.sh once wrote beside a script\n")
rc, o = scan(d)
arm("7 STALE a declared file that no longer writes is refused",
    rc == 1 and o:find("stale-declared:" .. d .. "/scripts/test-h.sh", 1, true) ~= nil, rc .. " " .. o)

rc, o = scan(root_with("comment", { ["test-i.sh"] = "# P=\"$ROOT/scripts/.old.$$.sh\" was the defect\n" }))
arm("8 COMMENT a commented-out writer is not one", rc == 0 and o:find(":writers=0:", 1, true) ~= nil, rc .. " " .. o)

fs.mkdir(REL .. "/empty/x")
rc, o = scan(REL .. "/empty")
arm("9 EMPTY no scripts is could-not-run", rc == 3 and o:find("could-not-run:checkout-writers:empty-population", 1, true) ~= nil, rc .. " " .. o)

-- ── the Lua population ──────────────────────────────────────────────────────
local LUA_PRE_REV = "5eaa4fe3d"
local THREE = { "test-fixtures-ignore-inherited-git-dir", "test-litmus-verdict-reads-stdout-only", "test-gate-keep-going" }
local function count(o, what) local n = 0; for _ in o:gmatch(what) do n = n + 1 end; return n end
local LW = ":lua%-fixture%-writes%-the%-checkout"
local pre3, now3, have = { ["x.sh"] = "echo x\n" }, { ["x.sh"] = "echo x\n" }, 0
for _, f in ipairs(THREE) do
    local r = proc.run({ argv = { "git", "show", LUA_PRE_REV .. ":scripts/lua/" .. f .. ".lua" }, cwd = ROOT, timeout_ms = 30000 })
    if r.code == 0 then have = have + 1; pre3[f .. ".lua"] = r.stdout end
    now3[f .. ".lua"] = fs.read("scripts/lua/" .. f .. ".lua")
end
local dpre = root_with("lua-pre", pre3)
if have ~= 3 then
    out.line("not run: 12 and 17 need " .. LUA_PRE_REV .. " in this clone (a shallow one lacks it)")
else
    rc, o = scan(dpre)
    arm("12 PRE-FIX the three real writers are each counted by path", rc == 1 and count(o, LW) == 3, rc .. " " .. o)
    rc, o = scan(root_with("lua-now", now3))
    arm("12 PRE-FIX as they are now none is", rc == 0 and o:find(":lua=3:writers=0:", 1, true) ~= nil, rc .. " " .. o)
end
rc, o = scan(root_with("lua-safe", { ["x.sh"] = "echo x\n", ["test-s.lua"] =
    "local REL = \"target/plan-scratch/a-\" .. n\nfs.write(REL .. \"/b\", x)\nlocal W = T:scratch()\nfs.write(W.rel .. \"/c\", [[\nd=scripts/x\n  d = \"scripts/y\"\n]])\nlocal d = REL .. \"/k\"\nfs.write(d .. \"/e\", x)\n-- fs.write(\"scripts/old.sh\", x)\n" }))
arm("13 SAFE target/, a kit dir and an embedded long string are not writers", rc == 0 and o:find(":lua=1:writers=0:", 1, true) ~= nil and o:find("lua-unresolved=0", 1, true) ~= nil, rc .. " " .. o)
rc, o = scan(root_with("lua-unres", { ["x.sh"] = "echo x\n", ["test-u.lua"] = "local function w(p) fs.write(p, x) end\n" }))
arm("14 UNRESOLVED a parameter is counted apart and named", rc == 0 and o:find("lua-unresolved=1", 1, true) ~= nil and o:find("note:checkout-writers:lua-unresolved:test-u.lua", 1, true) ~= nil, rc .. " " .. o)
local LUAW = { ["x.sh"] = "echo x\n", ["test-d.lua"] = "local FIX = \"docs/zz-probe.md\"\nfs.write(FIX, x)\n" }
d = REL .. "/lua-decl"
root_with("lua-decl", LUAW, d .. "/scripts/test-d.lua it reads the live dir\n")
rc, o = scan(d)
arm("15 DECLARED without artifacts= it is unsafe", rc == 1 and o:find("test-d.lua:lua-writer-declared-without-artifacts", 1, true) ~= nil, rc .. " " .. o)
root_with("lua-decl", LUAW, d .. "/scripts/test-d.lua artifacts=zz-probe* it reads the live dir\n")
rc, o = scan(d)
arm("15 DECLARED with artifacts= it is listed", rc == 0 and o:find("test-d.lua:kept-in-checkout:it reads the live dir", 1, true) ~= nil, rc .. " " .. o)
arm("16 NUMBERS the line names both populations", o:find("scanned=1:lua=1:", 1, true) ~= nil, o)
if have == 3 then
    local msrc, nm = fs.read(SUBJECT_REL):gsub("in ipairs%(assigns%[name%] or {}%) do", "in ipairs({}) do", 1)
    fs.write(REL .. "/mutant.lua", msrc)
    local r = proc.run({ argv = { PLAN, "script", "run", REL .. "/mutant.lua" }, cwd = ROOT, timeout_ms = 60000,
        env = { TILLANDSIAS_CHECKOUT_WRITERS_SCAN_DIR = dpre .. "/scripts", TILLANDSIAS_CHECKOUT_WRITERS_DECLARED = dpre .. "/declared.txt" } })
    arm("17 MUTANT without following locals the writers go uncounted", nm == 1 and count(r.stdout or "", LW) < 3, "nm=" .. nm .. " " .. tostring(r.stdout))
end

-- ── the door kill ──────────────────────────────────────────────────────────
local GUARD = "scripts/test-litmus-step-pipefail.sh"
local function pinned(body)
    -- The copy runs from REL, so its own-path cd is pinned to this checkout.
    local n
    body, n = body:gsub('\ncd "%$%(dirname "%${BASH_SOURCE%[0%]}"%)/%.%." || exit 2\n', '\ncd "' .. ROOT .. '" || exit 2\n', 1)
    return body, n
end
local pre_src = proc.run({ argv = { "git", "show", PRE_REV .. ":" .. GUARD }, cwd = ROOT, timeout_ms = 30000 })
local pre, n_pre = pinned(pre_src.stdout or "")
local post, n_post = pinned(fs.read(GUARD))
fs.write(REL .. "/has-timeout.sh", "command -v timeout\n")
local ht = proc.run({ argv = { "bash", ROOT .. "/" .. REL .. "/has-timeout.sh" }, timeout_ms = 10000 })
if pre_src.code ~= 0 or n_pre ~= 1 or n_post ~= 1 then
    arm("10/11 DOOR premise: both versions of " .. GUARD .. " found and pinned", false,
        "git show rc=" .. tostring(pre_src.code) .. " pinned pre=" .. n_pre .. " post=" .. n_post)
elseif ht.code ~= 0 then
    out.line("not run: 10-11 the door-kill arms (no timeout(1) on this host; the guard needs it too)")
else
    fs.write(REL .. "/pre.sh", pre)
    fs.write(REL .. "/post.sh", post)
    fs.mkdir(REL .. "/shim")
    fs.write(REL .. "/shim/timeout", table.concat({
        "#!/bin/sh",
        "case \"$*\" in *wka4-prefix-runner*) : > \"$HOLD_MARK\"; sleep 20 ;; esac",
        "exec \"$REAL_TIMEOUT\" \"$@\"", "" }, "\n"))
    proc.run({ argv = { "chmod", "+x", ROOT .. "/" .. REL .. "/shim/timeout" }, timeout_ms = 10000 })
    fs.write(REL .. "/door.sh", table.concat({
        "set -m",
        "G=\"$1\"; ROOT=\"$2\"; SHIM=\"$3\"; MODE=\"$4\"",
        "GT=\"$(mktemp -d \"${TMPDIR:-/tmp}/checkout-writers-door.XXXXXX\")\"",
        "REAL_TIMEOUT=\"$(command -v timeout)\"; HOLD_MARK=\"$GT.hold\"; export REAL_TIMEOUT HOLD_MARK",
        "( export TMPDIR=\"$GT\" PATH=\"$SHIM:$PATH\"; exec bash \"$G\" ) >/dev/null 2>&1 &",
        "pid=$!",
        "pre=\"$ROOT/scripts/.wka4-prefix-runner.$pid.sh\"",
        "i=0; while [ ! -e \"$HOLD_MARK\" ] && [ $i -lt 1200 ]; do sleep 0.1; i=$((i + 1)); done",
        "echo \"held=$([ -e \"$HOLD_MARK\" ] && echo yes || echo no)\"",
        "if [ \"$MODE\" = term ]; then",
        "    kill -TERM \"$pid\"; g=0",
        "    while kill -0 \"$pid\" 2>/dev/null && [ $g -lt 10 ]; do sleep 0.1; g=$((g + 1)); done",
        "    echo \"died-on-term=$([ $g -lt 10 ] && echo yes || echo no)\"",
        "fi",
        "kill -KILL \"$pid\" 2>/dev/null; wait \"$pid\" 2>/dev/null",
        "kill -KILL -\"$pid\" 2>/dev/null",
        "rm -rf \"$GT\" \"$HOLD_MARK\"",
        "if [ -e \"$pre\" ]; then echo \"left=$pre\"; rm -f \"$pre\"; else echo left=none; fi",
        "" }, "\n"))
    local function door(which, mode)
        local r = proc.run({ argv = { "bash", ROOT .. "/" .. REL .. "/door.sh", ROOT .. "/" .. REL .. "/" .. which .. ".sh",
            ROOT, ROOT .. "/" .. REL .. "/shim", mode or "kill" }, cwd = ROOT, timeout_ms = 180000 })
        return text.trim(r.stdout or ""):gsub("\n", " ")
    end
    local pre_out = door("pre")
    arm("10 PRE-FIX (" .. PRE_REV .. ") held in ARM 3 and killed: its runner copy is left in scripts/ (the defect)",
        pre_out:find("held=yes", 1, true) ~= nil and pre_out:find("left=" .. ROOT .. "/scripts/.wka4-prefix-runner.", 1, true) ~= nil, pre_out)
    local post_out = door("post")
    arm("11 POST-FIX held in ARM 3 and killed: nothing is left in the checkout",
        post_out:find("held=yes", 1, true) ~= nil and post_out:find("left=none", 1, true) ~= nil, post_out)
    local os_ = text.trim(proc.run({ argv = { "uname", "-s" }, timeout_ms = 10000 }).stdout or "")
    out.line("observed: " .. os_ .. " pre-fix under TERM, 1 s, KILL (not a control): " .. door("pre", "term"))
end

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:checkout-writers-fixture:" .. #failed .. "-failed", 1)
end
verdict.ok("checkout-writers-fixture", ran .. " arms")
