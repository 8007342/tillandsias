-- @env PATH HOME TMPDIR
-- @trace order:2285-jvg6, order:2248-zcqh, order:2243-urcy
--
-- test-gate-changed-nextest-transcript.lua — at intake, a green nextest run
-- reads GREEN. MEASURED 2026-11-24 (yoga, #1135's head): nextest passed 3168 of
-- 3168 and intake answered fail:test-baseline:no-test-results, because the log
-- sat in /tmp, the converter's fs.read refuses a path outside the repository,
-- and a silent `|| cp` handed the ratchet the raw log. Every crate-touching
-- intake was red wherever nextest is installed. The gate's own path (build.sh)
-- keeps its log under target/ and refuses a failed conversion; arm 5 pins that.
--
-- Real gate-changed.sh, converter and ratchet over a scratch workspace; cargo is
-- a stub whose nextest prints one result line.
--   1 GREEN    a passing nextest run is rc 0 (pre-fix: no-test-results)
--   2 RED      a failing one is rc 1 and names the new red
--   3 REASON   a converter that errors is rc 1 with its reason printed, and is
--              named as the converter, never as a test result
--   4 MUTANT   the log moved back to the /tmp work dir: refused, with the reason
--   5 GATE     build.sh's nextest log is under target/ and a failed conversion exits
--
-- Usage: tillandsias-plan script run scripts/lua/test-gate-changed-nextest-transcript.lua
-- Verdict: ok:gate-changed-nextest-transcript:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("gate-changed-nextest-transcript")
local ROOT, SH, PLAN = fixture.repo_root(), fixture.posix_shell(), fixture.plan_binary()
local R = T:git_repo("repo")
local function w(p, s) fs.mkdir((R.rel .. "/" .. p):match("^(.*)/[^/]*$")); fs.write(R.rel .. "/" .. p, s) end
local function git(...) return T:must{ "git", "-C", R.abs, "-c", "user.name=f", "-c", "user.email=f@invalid", ... } end
w("build.sh", "#!/usr/bin/env bash\n")
w("Cargo.toml", '[workspace]\nmembers = [\n    "crates/a",\n]\n')
w("crates/a/Cargo.toml", '[package]\nname = "a"\nversion = "0.1.0"\n')
w("crates/a/src/lib.rs", "pub fn f() {}\n")
w("scripts/gate-steps.d/100-x.step", 'STEP_DESC="x"\nSTEP_SCRIPT="scripts/test-x.sh"\n')
w("scripts/test-x.sh", "#!/usr/bin/env bash\ncat data/x.txt\n")
w("data/x.txt", "x\n")
for _, f in ipairs{ "scripts/check-test-baseline.sh", "scripts/lua/nextest-to-libtest.lua", "scripts/timing-log.sh" } do w(f, fs.read(f)) end
w("scripts/test-known-red.txt", "# nothing tolerated\n")
w("scripts/plan-binary-probe.sh", "resolve_plan_binary() { printf '%s\\n' '" .. PLAN .. "'; }\n")
w(".gitignore", "target/\n")
git("add", "-A"); git("commit", "-qm", "base")
local BASE = text.trim(git("rev-parse", "HEAD").stdout)
w("crates/a/src/lib.rs", "pub fn f() { }\n")

local B = T:scratch("bin")
local function cargo(status)
    fs.write(B.rel .. "/cargo", table.concat({ "#!/bin/sh", 'case "$*" in',
        "*--version*) echo 'cargo-nextest 0.9.999 (stub)' ;;",
        "'nextest run'*) echo '        " .. status .. " [   0.004s] (1/1) a tests::one'; [ " .. status .. " = PASS ] || exit 100 ;;",
        "esac", "" }, "\n"))
    T:must{ "chmod", "+x", B.abs .. "/cargo" }
end
local function intake(tool)
    local r = proc.run{ argv = { SH, tool, "--run", "--intake", BASE }, cwd = R.abs, timeout_ms = 120000,
        env = { PATH = B.abs .. ":" .. env.get("PATH"), HOME = env.get("HOME"), TMPDIR = "/tmp", TILLANDSIAS_GATE_CHANGED_ROOT = R.abs } }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local G, has = ROOT .. "/scripts/gate-changed.sh", text.contains

cargo("PASS")
local rc, o = intake(G)
T:arm("1 GREEN a passing nextest run reads green", rc == 0 and has(o, "runner:nextest:") and has(o, "ok:gate-changed:cargo-test"), "rc=" .. tostring(rc) .. "\n" .. o)
cargo("FAIL")
rc, o = intake(G)
T:arm("2 RED a failing test is red and named", rc == 1 and has(o, "new-red=1") and has(o, "tests::one"), "rc=" .. tostring(rc) .. "\n" .. o)
cargo("PASS")
-- committed, so the fault is the base and not part of the judged diff
local function plant(body) w("scripts/lua/nextest-to-libtest.lua", body); git("add", "scripts"); git("commit", "-qm", "plant"); BASE = text.trim(git("rev-parse", "HEAD").stdout) end
plant("error(\"planted-converter-fault\")\n")
rc, o = intake(G)
T:arm("3 REASON a converter error is named with its reason, never as a test result",
    rc == 1 and has(o, "fail:gate-changed:nextest-transcript") and has(o, "planted-converter-fault") and not has(o, "no-test-results"), "rc=" .. tostring(rc) .. "\n" .. o)
fs.write(B.rel .. "/silent-plan", "#!/bin/sh\nexit 1\n"); T:must{ "chmod", "+x", B.abs .. "/silent-plan" }
w("scripts/plan-binary-probe.sh", "resolve_plan_binary() { printf '%s\\n' '" .. B.abs .. "/silent-plan'; }\n")
plant(fs.read("scripts/lua/nextest-to-libtest.lua"))
local rc3, o3 = intake(G)
T:arm("3b SILENT a converter that fails without a reason is still a named failure", rc3 == 1 and has(o3, "fail:gate-changed:nextest-transcript") and has(o3, "printed nothing"), "rc=" .. tostring(rc3) .. "\n" .. o3)
w("scripts/plan-binary-probe.sh", "resolve_plan_binary() { printf '%s\\n' '" .. PLAN .. "'; }\n")
plant(fs.read("scripts/lua/nextest-to-libtest.lua"))
local mut, n = fs.read("scripts/gate-changed.sh"):gsub('_nx_log="%$ROOT/target/nextest%-changed%.log"', '_nx_log="$WORK/nextest.log"', 1)
fs.write(B.rel .. "/mutant.sh", mut)
rc, o = intake(B.abs .. "/mutant.sh")
T:arm("4 MUTANT the log back in /tmp is refused with the converter's reason", n == 1 and rc == 1 and has(o, "outside repository root"), "n=" .. n .. " rc=" .. tostring(rc) .. "\n" .. o)
local b = fs.read("build.sh")
T:arm("5 GATE build.sh keeps its nextest log under target/ and a failed conversion exits",
    has(b, '_ws_nx_log="$SCRIPT_DIR/target/') and b:find('_nextest_transcript "%$_ws_nx_log" >"%$_WS_TEST_TRANSCRIPT" || { _error [^\n]* exit 1; }') ~= nil, "shape changed")
T:finish()
