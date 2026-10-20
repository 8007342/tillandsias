-- @trace order:1800-nvsc, order:1799-5kvy
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-litmus-decide.lua — scripts/lua/litmus-decide.lua's contract, arm by
-- arm, against a FAKE cargo so every outcome is constructible on any tree.
--
--   1 RED-FIRST   a FAILED test and a panic: exit 1, the verdict line is NOT
--                 empty, and stderr names the test and the panic line. This
--                 is the 1799-5kvy incident: the bash step went red with empty
--                 output on the v56.10.19.1 release gate, so nobody could tell
--                 which test failed. Against a decider that exits silently
--                 this arm is red.
--   2 EMPTY       `running 0 tests` is could-not-run:…:empty-population, exit
--                 3, never ok
--   3 TOOL        a cargo that cannot spawn is could-not-run:…:tool-missing,
--                 exit 3, never a refusal of the tree
--   4 GREEN+CACHE a green run is ok with n=, cache=miss; the SAME call again
--                 is cache=hit and the producer ran ONCE (the fake counts)
--   5 PIN         --require-ok of a test that did not run is
--                 refused:…:missing-test:<t> (distinct from failed)
--   6 MIN         --min-ok under the floor is refused:…:only=<c>:need=<n>
--   7 RETRY       a transient lock failure then green: --retries 1 is ok with
--                 attempts=2; --retries 0 is refused and NOT retried
--   8 GREP        file-grep: present ok, absent-but-found names file:line,
--                 an empty population is could-not-run, count min/max
--   9 FAMILY      an unknown family is could-not-run, exit 3, naming the known
--
-- Usage: tillandsias-plan script run scripts/lua/test-litmus-decide.lua [-- --plan <bin>]

local DECIDER_REL = "scripts/lua/litmus-decide.lua"
if not fs.exists(DECIDER_REL) then
    verdict.emit("refused:litmus-decide-fixture:no-decider", 1, DECIDER_REL .. " does not exist (1800-nvsc)")
end

local PLAN
for i = 1, #arg do if arg[i] == "--plan" then PLAN = arg[i + 1] end end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("litmus-decide-fixture", "no plan binary named (--plan, TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 120000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local function must(r, what)
    if not (r.status == "exited" and r.code == 0) then
        verdict.could_not_run("litmus-decide-fixture", what .. " failed: " .. (r.stderr or r.status or ""))
    end
    return r
end
local ROOT = text.trim(must(run({ "git", "rev-parse", "--show-toplevel" }), "git rev-parse").stdout or "")
local REL = "target/plan-scratch/litmus-decide-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL
fs.mkdir(REL .. "/bin")

-- the fake cargo: mode and call-count files beside it
local FAKE = W .. "/bin/cargo"
fs.write(REL .. "/bin/cargo", table.concat({
    "#!/usr/bin/env bash",
    "d=\"$(dirname \"$0\")\"",
    "n=$(cat \"$d/calls\" 2>/dev/null || echo 0); n=$((n+1)); printf '%s\\n' \"$n\" > \"$d/calls\"",
    "mode=$(cat \"$d/mode\")",
    "case \"$mode\" in",
    "  green) cat \"$d/green.out\"; exit 0;;",
    "  failed) cat \"$d/failed.out\"; exit 101;;",
    "  empty) printf 'running 0 tests\\n\\ntest result: ok. 0 passed; 0 failed; 0 ignored\\n'; exit 0;;",
    "  lock) if [ \"$n\" -eq 1 ]; then echo 'Blocking waiting for file lock on build directory'; exit 101; fi; cat \"$d/green.out\"; exit 0;;",
    "esac",
    "echo 'fake cargo: unknown mode' >&2; exit 2",
    "",
}, "\n"))
must(run({ "chmod", "+x", FAKE }), "chmod")
local GREEN = {}
for i = 1, 8 do GREEN[#GREEN + 1] = "test answer::tests::pin_" .. i .. " ... ok" end
GREEN[#GREEN + 1] = "test tests::every_live_packet_has_a_span_that_contains_its_own_id ... ok"
GREEN[#GREEN + 1] = "test result: ok. 9 passed; 0 failed; 0 ignored"
fs.write(REL .. "/bin/green.out", "running 9 tests\n" .. table.concat(GREEN, "\n") .. "\n")
fs.write(REL .. "/bin/failed.out", table.concat({
    "running 3 tests",
    "test answer::tests::pin_1 ... ok",
    "test answer::tests::span_contains_claim ... FAILED",
    "test tests::every_live_packet_has_a_span_that_contains_its_own_id ... ok",
    "",
    "failures:",
    "",
    "---- answer::tests::span_contains_claim stdout ----",
    "thread 'answer::tests::span_contains_claim' panicked at crates/tillandsias-plan/src/answer.rs:412:9:",
    "assertion failed: span.contains(id)",
    "",
    "test result: FAILED. 2 passed; 1 failed; 0 ignored",
    "",
}, "\n"))
local function mode(m) fs.write(REL .. "/bin/mode", m .. "\n"); fs.write(REL .. "/bin/calls", "0\n") end
local function calls() return tonumber(text.trim(fs.read(REL .. "/bin/calls"))) end

local function decide(...)
    local argv = { PLAN, "script", "run", ROOT .. "/" .. DECIDER_REL, "--" }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    local r = run(argv, { env = { LITMUS_DECIDE_CARGO = FAKE } })
    return (r.status == "exited" and r.code or -1), (r.stdout or ""), (r.stderr or "")
end
local function first_line(s) return (text.lines(s)[1] or "") end

local pass, fail = 0, 0
local function arm(n, label, ok, detail)
    if ok then pass = pass + 1; log.raw("  ok   " .. n .. " " .. label)
    else fail = fail + 1; log.raw("  FAIL " .. n .. " " .. label .. (detail and (" — " .. detail) or "")) end
end

-- 1 RED-FIRST: the failing test and the panic are NAMED; stdout is not empty
mode("failed")
local rc, so, se = decide("cargo-test", "--package", "arm1", "--name", "pins", "--require-ok", "every_live_packet_has_a_span_that_contains_its_own_id")
arm(1, "RED-FIRST: exit 1 with a non-empty verdict naming the failure",
    rc == 1 and text.starts_with(first_line(so), "refused:pins:failed=1")
        and text.contains(se, "FAILED answer::tests::span_contains_claim")
        and text.contains(se, "panicked at crates/tillandsias-plan/src/answer.rs:412:9")
        and text.contains(se, "remedy:"),
    "rc=" .. rc .. " stdout=" .. first_line(so) .. " stderr=" .. se:sub(1, 400))

-- 2 EMPTY
mode("empty")
rc, so, se = decide("cargo-test", "--package", "arm2", "--name", "pins")
arm(2, "EMPTY: zero tests is could-not-run, exit 3",
    rc == 3 and text.starts_with(first_line(so), "could-not-run:pins:empty-population") and text.contains(se, "running 0 tests"),
    "rc=" .. rc .. " stdout=" .. first_line(so))

-- 3 TOOL
do
    local argv = { PLAN, "script", "run", ROOT .. "/" .. DECIDER_REL, "--", "cargo-test", "--package", "arm3", "--name", "pins" }
    local r = run(argv, { env = { LITMUS_DECIDE_CARGO = W .. "/bin/no-such-cargo" } })
    rc, so, se = (r.status == "exited" and r.code or -1), (r.stdout or ""), (r.stderr or "")
    arm(3, "TOOL: an unspawnable cargo is could-not-run:tool-missing, exit 3",
        rc == 3 and text.starts_with(first_line(so), "could-not-run:pins:tool-missing:") and text.contains(se, "remedy:"),
        "rc=" .. rc .. " stdout=" .. first_line(so))
end

-- 4 GREEN + CACHE: the producer runs once for two judgements
mode("green")
rc, so, se = decide("cargo-test", "--package", "arm4", "--name", "pins", "--min-ok", "answer::tests::", "8", "--require-ok", "every_live_packet_has_a_span_that_contains_its_own_id")
local l1 = first_line(so)
local rc2, so2 = decide("cargo-test", "--package", "arm4", "--name", "pins", "--min-ok", "answer::tests::", "8", "--require-ok", "every_live_packet_has_a_span_that_contains_its_own_id")
local l2 = first_line(so2)
arm(4, "GREEN+CACHE: ok n=9 cache=miss, then cache=hit with the producer run once",
    rc == 0 and text.starts_with(l1, "ok:pins:n=9:failed=0:cache=miss")
        and rc2 == 0 and text.starts_with(l2, "ok:pins:n=9:failed=0:cache=hit:age=")
        and calls() == 1,
    "rc=" .. rc .. "/" .. rc2 .. " first=" .. l1 .. " second=" .. l2 .. " calls=" .. tostring(calls()))

-- 4b --no-cache forces the producer
local rc3, so3 = decide("cargo-test", "--package", "arm4", "--name", "pins", "--no-cache")
arm("4b", "--no-cache runs the producer again (cache=off)",
    rc3 == 0 and text.starts_with(first_line(so3), "ok:pins:n=9:failed=0:cache=off") and calls() == 2,
    "stdout=" .. first_line(so3) .. " calls=" .. tostring(calls()))

-- 5 PIN
mode("green")
rc, so, se = decide("cargo-test", "--package", "arm5", "--name", "pins", "--require-ok", "renamed_pin_that_is_gone")
arm(5, "PIN: a pinned test that did not run is refused:missing-test, not a pass",
    rc == 1 and text.starts_with(first_line(so), "refused:pins:missing-test:renamed_pin_that_is_gone"),
    "rc=" .. rc .. " stdout=" .. first_line(so))

-- 6 MIN
mode("green")
rc, so, se = decide("cargo-test", "--package", "arm6", "--name", "pins", "--min-ok", "answer::tests::", "20")
arm(6, "MIN: fewer passing tests than the floor is refused:only=8:need=20",
    rc == 1 and text.starts_with(first_line(so), "refused:pins:only=8:need=20"),
    "rc=" .. rc .. " stdout=" .. first_line(so))

-- 7 RETRY: transient lock then green
mode("lock")
rc, so, se = decide("cargo-test", "--package", "arm7a", "--name", "pins", "--retries", "1", "--no-cache")
local a = first_line(so)
mode("lock")
local rcb, sob = decide("cargo-test", "--package", "arm7b", "--name", "pins", "--retries", "0", "--no-cache")
local b = first_line(sob)
arm(7, "RETRY: --retries 1 recovers a lock (attempts=2); --retries 0 does not retry",
    rc == 0 and text.contains(a, ":attempts=2") and text.contains(se, "retry 1/1")
        and rcb == 3 and text.starts_with(b, "could-not-run:pins:producer-exit=101") and text.contains(b, ":attempts=1"),
    "a=" .. a .. " b=" .. b)

-- 8 GREP
fs.mkdir(REL .. "/corpus")
fs.write(REL .. "/corpus/a.md", "alpha\nbeta uses python3 here\ngamma\n")
fs.write(REL .. "/corpus/b.md", "delta\nalpha again\n")
local C = REL .. "/corpus"
local r8a = { decide("file-grep", "--name", "g", "--path", C, "--suffix", ".md", "--pattern", "^alpha") }
local r8b = { decide("file-grep", "--name", "g", "--path", C, "--pattern", "python3", "--mode", "absent") }
local r8c = { decide("file-grep", "--name", "g", "--path", REL .. "/no-such-dir", "--pattern", "x") }
local r8d = { decide("file-grep", "--name", "g", "--path", C, "--pattern", "alpha", "--mode", "count", "--min", "3") }
local r8e = { decide("file-grep", "--name", "g", "--path", C .. "/a.md", "--pattern", "python3", "--fixed", "--mode", "count", "--min", "1", "--max", "1") }
arm(8, "GREP: present ok / absent-but-found names file:line / empty population / count",
    r8a[1] == 0 and text.starts_with(first_line(r8a[2]), "ok:g:matches=2:files=2")
        and r8b[1] == 1 and text.starts_with(first_line(r8b[2]), "refused:g:absent-but-found:" .. C .. "/a.md:2")
        and r8c[1] == 3 and text.starts_with(first_line(r8c[2]), "could-not-run:g:empty-population")
        and r8d[1] == 1 and text.starts_with(first_line(r8d[2]), "refused:g:count=2:min=3")
        and r8e[1] == 0 and text.starts_with(first_line(r8e[2]), "ok:g:matches=1:files=1"),
    table.concat({ first_line(r8a[2]), first_line(r8b[2]), first_line(r8c[2]), first_line(r8d[2]), first_line(r8e[2]) }, " | "))

-- 9 FAMILY
rc, so, se = decide("no-such-family")
arm(9, "FAMILY: an unknown family is could-not-run naming the known ones",
    rc == 3 and text.starts_with(first_line(so), "could-not-run:litmus-decide:unknown-family:no-such-family") and text.contains(se, "cargo-test, file-grep"),
    "rc=" .. rc .. " stdout=" .. first_line(so))

must(run({ "rm", "-rf", W }), "cleanup")
if fail > 0 then
    verdict.emit("refused:litmus-decide-fixture:" .. fail .. "-of-" .. (pass + fail) .. "-arms-failed", 1, "see the FAIL lines above")
end
verdict.ok("litmus-decide-fixture", "arms=" .. pass)
