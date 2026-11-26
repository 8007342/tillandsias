-- @trace order:1033-iycs, order:2387-lrg2
-- @env PATH HOME TMPDIR
--
-- test-land-gate-refusal-names-its-step.lua — when the land tool's gate refuses, the refusal
-- names the failing step and the log holding the gate's output (1033-iycs). Ported from
-- test-land-gate-refusal-names-its-step.sh (2387-lrg2); same arms, in its order.
--
-- What it used to say, in full, on macbookair landing 997-e4v2:
--   refused:land:gate-failed — run ./build.sh --check to see why
-- No step, no reason, no log, and the remedy did not work: a standalone re-run is a DIFFERENT
-- invocation against a tree the land's own integrate step may have moved.
--
-- The gate here is a STUB build.sh in a scratch repo: a real gate takes minutes and will not fail
-- on demand. The land script derives its root from its own location, so it sits at scripts/.
-- No child runs the real build.sh, so no gate env is inherited.
--
--   1   a failing gate still refuses with refused:land:gate-failed (rc 3)
--   2   the refusal names a log that exists, non-empty, holding the gate's output
--   3   it quotes the FIRST failing line, not the trailing summary
--   4   it warns against the old re-run remedy
--   4b  a marker inside an `ok` row is not the cause
--   4c  a yellow _warn quoting a violation count is not the cause, and is not reported at all
--   4d  a red _error is the cause when nothing failed first
--   4e  a colourless log falls back AND says so
--   5   CONTROL a passing gate lands, and names no failing line
--
-- GRAMMAR ok:land-gate-refusal:<n> arms | violation:land-gate-refusal:<n>-failed

local fixture = require "common.fixture"
local SH = fixture.posix_shell()
local T = fixture.new("land-gate-refusal")
local SRC = "scripts/land-on-platform-branch.sh"
if not fs.exists(SRC) then T:refuse("subject-not-found", SRC) end

local W = T:scratch()
local BARE, WC = W.abs .. "/bare.git", W.abs .. "/wc"
local ENV = { GIT_TERMINAL_PROMPT = "0" }
local UNSET = { "TILLANDSIAS_*", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE" }
local function git(...)
    local a = { "git", "-c", "user.email=t@t", "-c", "user.name=t", ... }
    a.cwd, a.env, a.env_unset = WC, ENV, UNSET
    return T:must(a)
end

T:must{ "git", "init", "-q", "--bare", BARE, env_unset = UNSET }
T:must{ "git", "init", "-q", "-b", "linux-next", WC, env_unset = UNSET }
git("remote", "add", "origin", BARE)
git("config", "core.hooksPath", ".git/hooks")
git("config", "user.email", "t@t"); git("config", "user.name", "t"); git("config", "commit.gpgsign", "false")
fs.mkdir(W.rel .. "/wc/scripts")
fs.write(W.rel .. "/wc/scripts/land-on-platform-branch.sh", fs.read(SRC))
T:must{ "chmod", "+x", WC .. "/scripts/land-on-platform-branch.sh" }
fs.write(W.rel .. "/wc/README.md", "base\n")
git("add", "-A"); git("commit", "-q", "-m", "base")
git("push", "-q", "-u", "origin", "linux-next")

local function stub(body, msg)
    fs.write(W.rel .. "/wc/build.sh", "#!/usr/bin/env bash\n" .. body .. "\n")
    T:must{ "chmod", "+x", WC .. "/build.sh" }
    if msg then git("add", "-A"); git("commit", "-q", "-m", msg) end
end
local function land()
    local r = T:run{ SH, "scripts/land-on-platform-branch.sh", "linux-next", "1",
        cwd = WC, env = ENV, env_unset = UNSET, timeout_ms = 120000 }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local function first_failing(o)
    for _, l in ipairs(text.lines(o)) do if text.contains(l, "first failing") then return l end end
    return "<none>"
end
local function has_line_prefix(o, p)
    for _, l in ipairs(text.lines(o)) do if l:sub(1, #p) == p then return true end end
    return false
end

-- A stub gate that fails on a NAMED step, in build.sh's own verdict shape.
stub([[echo "[build] Checking the thing that works..."
echo "[build] Checking scripts/check-invented-guard.sh (order 9999-test)..."
echo "violation:invented-guard-tripped:1"
echo "[build] a script tripped the invented guard — see the verdict line above"
exit 1]])
fs.write(W.rel .. "/wc/work.txt", "work\n")
git("add", "-A"); git("commit", "-q", "-m", "work to land")
local rc, out = land()

T:arm("1 a failing gate still refuses with refused:land:gate-failed",
    rc == 3 and has_line_prefix(out, "refused:land:gate-failed"), "rc=" .. tostring(rc))

local log = out:match("its output is at ([^\n]+)")
local log_ok = log and T:run{ "test", "-s", log }.code == 0
T:arm("2 the refusal names a log path that exists and is non-empty", log_ok, log or "<none>")
T:arm("2 the log holds the gate's actual output",
    log_ok and T:run{ "grep", "-q", "violation:invented-guard-tripped", log }.code == 0, log or "<none>")

-- The FIRST failing line: build.sh prints its verdict after the failure.
T:arm("3 the refusal quotes the first failing line, not the trailing summary",
    out:find("first failing line:[^\n]*violation:invented%-guard%-tripped") ~= nil, first_failing(out))

T:arm("4 the refusal warns that a standalone re-run is a different invocation",
    text.contains(out, "Do NOT re-run"), "no 'Do NOT re-run' in the refusal")

-- 4b: the first real refusal this fix caught named a PASSING arm quoting `refused:`.
stub([[echo "ok   no evidence at all                -> refused:no-evidence:v0.4:missing=linux (0 mutations)"
echo "ok:   a passing arm that quotes violation: in its own text"
echo "FAIL: the arm that actually failed"
echo "[build] the real verdict banner"
exit 1]], "a gate whose passing arms quote the markers")
local _, out3 = land()
T:arm("4b a marker inside an ok row is skipped; the real FAIL line is named",
    text.contains(out3, "first failing line: FAIL: the arm that actually failed"), first_failing(out3))

-- 4c: macuahuitl 2026-09-05 — a yellow _warn quoting a violation COUNT, ~60 lines before the cause.
-- build.sh's _error is red (0;31) and _warn yellow (0;33); the stub reproduces the bytes.
stub([[printf '\033[0;36m[build]\033[0m Checking declared closures...\n'
printf '\033[0;33m[build]\033[0m standing declared-closure debt: violation:declared-closure-unresolvable:4 (see '"'"'tillandsias-plan declared-closures'"'"'; not a gate)\n'
i=0; while [ $i -lt 60 ]; do echo "  ok   some passing arm $i"; i=$((i+1)); done
echo "FAIL: expected measured-clean, got: sigpipe-decided:fx:2:2/3"
printf '\033[0;31m[build]\033[0m the calibration corpus refused\n'
exit 1]], "a gate whose advisory warning quotes a violation count")
local _, out4c = land()
T:arm("4c an advisory _warn quoting violation: is skipped; the real FAIL is named",
    text.contains(out4c, "first failing line: FAIL: expected measured-clean"), first_failing(out4c))
T:arm("4c the advisory line does not appear in the refusal at all",
    not text.contains(out4c, "declared-closure-unresolvable"), first_failing(out4c))

-- 4d: the severity rule must not make [build] lines invisible — only advisory ones.
stub([[printf '\033[0;33m[build]\033[0m advisory: violation:some-standing-debt:3\n'
printf '\033[0;31m[build]\033[0m the gate refused for a reason only _error names\n'
exit 1]], "a gate whose only failure is a red _error line")
local _, out4d = land()
T:arm("4d a red _error line is named when it is the first real failure",
    text.contains(out4d, "first failing line: [build] the gate refused for a reason only _error names"), first_failing(out4d))

-- 4e: no colour at all — severity is unavailable, so the fallback must announce itself (1024-c3h3).
stub([[echo "[build] standing declared-closure debt: violation:declared-closure-unresolvable:4"
echo "FAIL: the arm that actually failed"
exit 1]], "a gate log with no colour at all")
local _, out4e = land()
T:arm("4e a colourless log names its fallback instead of degrading silently",
    text.contains(out4e, "severity was unavailable"), first_failing(out4e))

-- 5: without this, arms 1-4 are satisfied by a tool that refuses unconditionally.
stub([[echo "[build] everything is fine"
exit 0]], "make the gate pass")
local rc2, out2 = land()
local tail = {}
local l2 = text.lines(out2)
for i = math.max(1, #l2 - 3), #l2 do tail[#tail + 1] = l2[i] end
T:arm("5 CONTROL: a passing gate lands without a refusal",
    rc2 == 0 and not text.contains(out2, "refused:land:gate-failed"), "rc=" .. tostring(rc2) .. " tail: " .. table.concat(tail, "|"))
T:arm("5 CONTROL: a passing gate names no failing line", not text.contains(out2, "first failing line"), first_failing(out2))

T:finish()
