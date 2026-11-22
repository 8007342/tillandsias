-- @trace order:1060-6fx7, order:2208-vxb6
--
-- test-lane-instrument-vs-ledger.lua — PORTED from
-- test-lane-instrument-vs-ledger.sh (2208-vxb6), same arms, same lines.
--
-- Pin: when the plan binary cannot RUN, the plan-only lane must say so — and
-- must not say the LEDGER was refused. MEASURED on yoga 2026-09-05: with the
-- override pointed at a binary that dies on exec, the lane said "validation
-- FAILED — tillandsias-plan check refused the folded ledger". The ledger was
-- sound; the binary could not link (the 923-ws3r class: the instrument is
-- missing, not the data).
--
-- WHY BOTH ARMS. Arm 1 alone is satisfiable by never reporting a ledger fault
-- at all. Arm 2 is the control: a genuinely malformed ledger must STILL be
-- reported as a ledger fault.
--
-- HEAD: the hook runs in a scratch repo under target/plan-scratch with its own
-- origin, never against the real checkout's HEAD (2196-rdec: clean by
-- construction). Every commit carries its identity on the command line.
--
-- Verdict: after the .sh's summary line `lane-instrument-vs-ledger: <p>
-- passed, <f> failed`, ok:lane-instrument-vs-ledger:<p> |
-- violation:lane-instrument-vs-ledger:<f> | skip:lane-instrument-vs-ledger:no-validator

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local GUARD = "scripts/hooks/pre-push-local-gate.sh"
local pass, fail = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) log.raw("FAIL: " .. m .. "\n"); fail = fail + 1 end
-- The last six lines of the hook's output, for the reader. The runner returns
-- stdout and stderr separately, so this is stdout then stderr, where the .sh
-- interleaved them; the arms never read it.
local function tail6(s)
    local ls = text.lines((s or ""):gsub("%s+$", ""))
    for i = math.max(1, #ls - 5), #ls do log.raw("      " .. ls[i] .. "\n") end
end

local rel = "target/plan-scratch/lane-instrument-" .. tostring(time.now_ms())
local W = root .. "/" .. rel
proc.run{ argv = { "mkdir", "-p", W } }
local function cleanup() proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 } end

-- A real validator for the control arm, resolved (and therefore EXECUTED) in
-- the checkout rather than from inside the scratch repo (1056-5344).
fs.write(rel .. "/resolve.sh", ". scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null\n")
local real = text.trim(proc.run{ argv = { "bash", W .. "/resolve.sh" } }.stdout or "")
if real:sub(1, 2) == "./" then real = root .. "/" .. real:sub(3) end
if real == "" then
    cleanup()
    log.raw("skip:lane-instrument-vs-ledger:no-validator — no runnable tillandsias-plan; the control arm cannot distinguish a ledger fault from a missing instrument here\n")
    out.line("lane-instrument-vs-ledger: 0 passed, 0 failed (skipped)")
    verdict.skip("lane-instrument-vs-ledger:no-validator")
end

local WC = W .. "/wc"
local GENV = { GIT_TERMINAL_PROMPT = "0" }
local function git(args, opts)
    local a = { "git", "-c", "user.email=t@t", "-c", "user.name=t" }
    for _, x in ipairs(args) do a[#a + 1] = x end
    return proc.run{ argv = a, cwd = (opts and opts.cwd) or WC, env = GENV, timeout_ms = 120000 }
end
proc.run{ argv = { "git", "init", "-q", "--bare", W .. "/bare.git" } }
proc.run{ argv = { "git", "init", "-q", "-b", "linux-next", WC } }
git({ "remote", "add", "origin", W .. "/bare.git" })
git({ "config", "core.hooksPath", ".git/hooks" })
git({ "config", "core.autocrlf", "false" })
proc.run{ argv = { "mkdir", "-p", WC .. "/scripts/hooks", WC .. "/plan/index.d" } }
proc.run{ argv = { "cp", GUARD, WC .. "/scripts/hooks/pre-push-local-gate.sh" } }
for _, f in ipairs({ "plan-binary-probe.sh", "gate-stamp.sh", "common.sh", "check-issue-citation-convention.sh" }) do
    if fs.exists("scripts/" .. f) then proc.run{ argv = { "cp", "scripts/" .. f, WC .. "/scripts/" .. f } } end
end
proc.run{ argv = { "find", WC .. "/scripts", "-name", "*.sh", "-exec", "chmod", "+x", "{}", "+" } }
fs.write(rel .. "/wc/plan/index.yaml", "packets: []\n")
fs.write(rel .. "/wc/README.md", "base\n")
git({ "add", "-A" }); git({ "commit", "-q", "-m", "base" })
git({ "push", "-q", "-u", "origin", "linux-next" })

fs.write(rel .. "/stub", "#!/usr/bin/env bash\necho \"$0: /lib64/libm.so.6: version \\`GLIBC_2.44' not found\" >&2\nexit 127\n")
proc.run{ argv = { "chmod", "+x", W .. "/stub" } }

local function run_guard(planbin)
    local rsha = text.trim(git({ "rev-parse", "origin/linux-next" }).stdout or "")
    local head = text.trim(git({ "rev-parse", "HEAD" }).stdout or "")
    local r = proc.run{ argv = { "bash", "scripts/hooks/pre-push-local-gate.sh" }, cwd = WC,
        stdin = "refs/heads/linux-next " .. head .. " refs/heads/linux-next " .. rsha .. "\n",
        env = { GIT_TERMINAL_PROMPT = "0", TILLANDSIAS_PLAN_BIN = planbin }, timeout_ms = 600000 }
    return (r.stdout or "") .. (r.stderr or "")
end

-- ── 1. AN UNRUNNABLE BINARY IS AN INSTRUMENT FAULT ─────────────────────────
fs.write(rel .. "/wc/plan/index.d/20260905t000000z-fixture.yaml", "packets: []\n")
git({ "add", "-A" }); git({ "commit", "-q", "-m", "ledger append" })
local o = run_guard(W .. "/stub")

-- EVERY DATA-BLAMING VERDICT, not just the one from the report: a dead binary
-- fails validate-yaml FIRST and the lane says "is not valid YAML", the same
-- misattribution in a different sentence.
local blamed = ""
for _, s in ipairs({ "refused the folded ledger", "is not valid YAML", "does not parse to a YAML mapping",
        "could not PARSE a pushed fragment" }) do
    if blamed == "" and o:find(s, 1, true) then blamed = s end
end
if blamed ~= "" then
    bad("an unrunnable binary is reported as a fault in the DATA (\"" .. blamed .. "\") — this is the incident")
else
    ok("an unrunnable binary is not reported as a fault in the data")
end
if o:find("does NOT run here", 1, true) then ok("the verdict names the instrument, and says it does not run")
else bad("the verdict does not name the instrument"); tail6(o) end
-- The linker's own words, not a generic label.
if o:find("GLIBC_2.44", 1, true) then ok("the verdict carries the underlying reason")
else bad("the verdict does not carry the underlying reason") end

-- ── 2. CONTROL: A REAL LEDGER FAULT IS STILL A LEDGER FAULT ────────────────
git({ "reset", "-q", "--hard", "origin/linux-next" })
proc.run{ argv = { "mkdir", "-p", WC .. "/plan/index.d" } }
fs.write(rel .. "/wc/plan/index.d/20260905t000001z-malformed.yaml", "packets: [unclosed\n")
git({ "add", "-A" }); git({ "commit", "-q", "-m", "a malformed fragment" })
o = run_guard(real)
if o:find("validation FAILED", 1, true) then
    ok("CONTROL: a malformed fragment is still refused by the lane")
else
    bad("CONTROL: a malformed fragment was NOT refused — the lane's validation is gone"); tail6(o)
end
if o:find("does NOT run here", 1, true) then
    bad("CONTROL: a real ledger fault was misreported as an instrument fault")
else ok("CONTROL: a real ledger fault is not blamed on the instrument") end

cleanup()
out.line("lane-instrument-vs-ledger: " .. pass .. " passed, " .. fail .. " failed")
if fail == 0 then verdict.ok("lane-instrument-vs-ledger:" .. pass) end
verdict.emit("violation:lane-instrument-vs-ledger:" .. fail, 1)
