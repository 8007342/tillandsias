-- @env PATH HOME
-- @trace order:2282-asxn
--
-- test-relay-preflight-derived-checks.lua — relay-preflight runs every check-*
-- decider the diff touches, DERIVED by gate-changed.sh --checks, so a decider
-- nobody listed is still run. Three PRs passed relay-preflight and were evicted
-- on a decider its hand-kept list lacked (#1109, #1135, #1190; 2026-11-24).
-- Real gate-changed.sh over a scratch repo; real relay phase text (its
-- BEGIN/END-DERIVED-CHECKS block) over a stub.
--
--   1 SELECTED   a check-* step whose declared input the diff touches is selected
--                and its red is rc 1 naming it; a test-* step on the same input is not
--   2 NEW        a check-* step wired a moment ago is selected with no list edited
--   3 CONTROL    a diff touching neither's input selects no check
--   4 HEAVY      an unmapped path runs every check-*, never none
--   5 GATE-ONLY  a check declaring gate-only is deferred by name and not run
--   6 WIRED      the relay phase refuses derived-checks:<name>, passes on green, and
--                exports no repo root to the deciders (one tests a copy of the tree)
--   7 MUTANT     with the check-* filter admitting nothing, arm 1's world is green
--
-- Usage: tillandsias-plan script run scripts/lua/test-relay-preflight-derived-checks.lua
-- Verdict: ok:relay-preflight-derived-checks:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("relay-preflight-derived-checks")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local R = T:git_repo("repo")
local function w(p, s)
    fs.mkdir((R.rel .. "/" .. p):match("^(.*)/[^/]*$")); fs.write(R.rel .. "/" .. p, s)
end
local function git(...) return T:must{ "git", "-C", R.abs, "-c", "user.name=f", "-c", "user.email=f@invalid", ... } end
local function step(n, name, body)
    w("scripts/" .. name .. ".sh", "#!/usr/bin/env bash\n" .. body .. "\n")
    w("scripts/gate-steps.d/" .. n .. "-x.step", 'STEP_DESC="' .. name .. '"\nSTEP_SCRIPT="scripts/' .. name .. '.sh"\n')
end
w("build.sh", "#!/usr/bin/env bash\n")
w("Cargo.toml", "[workspace]\nmembers = [\n]\n")
w("data/a.txt", "a\n"); w("data/b.txt", "b\n")
w("scripts/timing-log.sh", ":\n"); w("scripts/plan-binary-probe.sh", "resolve_plan_binary() { return 1; }\n")
step("100", "check-a", "cat data/a.txt >/dev/null; echo refused:a; exit 1")
step("200", "check-b", "cat data/b.txt >/dev/null; echo ok:b")
step("300", "test-a", "cat data/a.txt >/dev/null; echo test-a-ran; exit 1")
step("400", "check-slow", "# preflight: gate-only — a slow one\ncat data/a.txt >/dev/null; echo slow-ran; exit 1")
git("add", "-A"); git("commit", "-qm", "base")
local BASE = text.trim(git("rev-parse", "HEAD").stdout)

local function gc(tool, mode)
    local r = proc.run{ argv = { SH, tool, mode, "--checks", BASE }, cwd = R.abs, timeout_ms = 120000,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_GATE_CHANGED_ROOT = R.abs } }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local G = ROOT .. "/scripts/gate-changed.sh"
local has = text.contains
local function reset() git("reset", "-q", "--hard", BASE); git("clean", "-qfd") end

w("data/a.txt", "changed\n")
local rc, o = gc(G, "--run")
T:arm("1 SELECTED the touched check-* runs and its red is named; the test-* is not run",
    rc == 1 and has(o, "fail:gate-changed:fixture:scripts/check-a.sh") and not has(o, "test-a") and not has(o, "check-b.sh because"), "rc=" .. tostring(rc) .. "\n" .. o)
T:arm("5 GATE-ONLY a declared gate-only check is deferred by name and not run",
    has(o, "deferred:checks scripts/check-slow.sh") and not has(o, "slow-ran"), o)

step("500", "check-new", "cat data/a.txt >/dev/null; echo ok:new")
rc, o = gc(G, "--list")
T:arm("2 NEW a check-* wired a moment ago is selected with no list edited", has(o, "select:fixture:scripts/check-new.sh"), o)

reset(); w("data/b.txt", "changed\n")
rc, o = gc(G, "--run")
T:arm("3 CONTROL a diff touching only b selects check-b and not check-a",
    rc == 0 and has(o, "ok:gate-changed:fixture:scripts/check-b.sh") and not has(o, "check-a.sh"), "rc=" .. tostring(rc) .. "\n" .. o)

reset(); w("unmapped/z.txt", "z\n")
rc, o = gc(G, "--run")
T:arm("4 HEAVY an unmapped path runs every check-*, and only those",
    rc == 1 and has(o, "select:checks-all") and has(o, "fixture:scripts/check-a.sh") and has(o, "fixture:scripts/check-b.sh") and not has(o, "test-a"),
    "rc=" .. tostring(rc) .. "\n" .. o)

-- 6: the relay block itself, over a stub gate-changed
local block = fs.read("scripts/relay-preflight.sh"):match("# BEGIN%-DERIVED%-CHECKS\n(.-)# END%-DERIVED%-CHECKS\n") or ""
local W = T:scratch("phase")
local function phase(stub)
    fs.write(W.rel .. "/gate-changed.sh", stub)
    local r = proc.run{ argv = { SH, "-s", "--", W.abs }, timeout_ms = 60000, stdin = [[
export TILLANDSIAS_REPO_ROOT=$1 PROJECT_ROOT=$1
SELF_DIR=$1; ROOT=$1; BASE=x; PLAN_MODE=0; STUB=0; KEEP_GOING=0; T0=0; FIRST_FAIL_TOKEN=
timing_now_ms() { echo 0; }; timing_emit() { :; }; _restore_clean() { :; }
_item() { echo "item: $1 $2"; }; _afford() { echo "why: $1"; echo "remedy: $2"; }
_cap() { _CAP_OUT="$("$@" 2>&1)"; }
]] .. block .. "echo fell-through\n" }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local c4, o4 = phase("[ -z \"${TILLANDSIAS_REPO_ROOT:-}${PROJECT_ROOT:-}\" ] || { echo fail:gate-changed:fixture:scripts/check-root-leaked.sh; exit 1; }\n")
local c1, o1 = phase("echo 'fail:gate-changed:fixture:scripts/lua/check-zz.lua rc=1 ms=2'; exit 1\n")
local c2, o2 = phase("echo 'ok:gate-changed fixtures=1 crates=0 ms=1'; exit 0\n")
local c3, o3 = phase("echo could-not-run:gate-changed:no-tmpdir; exit 2\n")
T:arm("6 WIRED the relay phase refuses by the decider's name, refuses a run that could not answer, and passes on green",
    block ~= "" and c1 == 1 and has(o1, "refused:relay-preflight:derived-checks:check-zz") and not has(o1, "fell-through")
    and c2 == 0 and has(o2, "fell-through") and c4 == 0 and c3 == 1 and has(o3, "derived-checks:could-not-run:rc=2"), o1 .. "--\n" .. o2 .. "--\n" .. o3)

-- 7
local src = fs.read("scripts/gate-changed.sh")
local mut, n = src:gsub('in check%-%*%) ;; %*%) continue', 'in none-match) ;; *) continue', 1)
fs.write(W.rel .. "/mutant.sh", mut)
reset(); w("data/a.txt", "changed\n")
rc, o = gc(W.abs .. "/mutant.sh", "--run")
T:arm("7 MUTANT with a filter that admits nothing, arm 1's red world passes", n == 1 and rc == 0, "n=" .. n .. " rc=" .. tostring(rc) .. "\n" .. o)
T:finish()
