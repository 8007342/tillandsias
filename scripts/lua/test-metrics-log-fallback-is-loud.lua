-- @env PATH HOME TMPDIR
-- @trace order:1268-m2ir, spec:ci-release, order:2379-p5dq
--
-- test-metrics-log-fallback-is-loud.lua — scripts/metrics-log-path.sh keeps a checkout's records in the
-- checkout, a worktree (.git is a file) included; a run outside any checkout still falls back to /tmp and
-- SAYS so; PROJECT_ROOT wins over a root that is not a checkout. Ported from the .sh of the same name.
-- /tmp's own log is never deleted: on a host with stray records it is another order's evidence.
--
-- Usage: tillandsias-plan script run scripts/lua/test-metrics-log-fallback-is-loud.lua
-- Verdict: ok:metrics-log-fallback:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("metrics-log-fallback")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
local SUBJECT, BASE = "scripts/metrics-log-path.sh", "tillandsias-timing.jsonl"
local src = fs.read(SUBJECT):gsub("\r\n", "\n")
local W = T:scratch()
local function environ() return { PATH = env.get("PATH"), HOME = env.get("HOME"), TMPDIR = env.get("TMPDIR"), TILLANDSIAS_PLAN_BIN = PLAN } end

-- 1. The runner from the checkout, as an agent shell runs it: under timeout where the host has one, pipefail
-- on, its output through a pipe. The probe's name is assembled: a bare one reads as a pin claim.
local LIT = "litmus"
local NAME = LIT .. ":m2ir-probe"
fs.mkdir(W.rel .. "/tests")
fs.write(W.rel .. "/bindings.yaml", "version: '1.0'\ndescription: fixture for 1268-m2ir\nspecs:\n- spec_id: ci-release\n  status: active\n  "
    .. LIT .. "_tests:\n  - " .. NAME .. "\n  coverage_ratio: 100\n  last_verified: '2026-09-20'\n")
fs.write(W.rel .. "/tests/" .. LIT .. "-m2ir-probe.yaml", "name: " .. NAME .. "\nspec: ci-release\nphase: pre-build\nseverity: high\nsize: instant\n"
    .. "description: >\n  a one-step probe, so the suite's timing record is emitted without running a tier\ncritical_path:\n  - step: \"trivial\"\n"
    .. "    command: \"echo m2ir\"\n    timeout_ms: 5000\n    expected_behavior: \"m2ir\"\n    assert_output_contains: \"m2ir\"\n")
local e = environ()
e.TILLANDSIAS_LITMUS_BINDINGS, e.TILLANDSIAS_LITMUS_TESTS_DIR = W.abs .. "/bindings.yaml", W.abs .. "/tests"
local r = T:run{ SH, "-s", "--", BASE, cwd = ROOT, env = e, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 330000, stdin = [[
set -uo pipefail
size() { if [ -f "$1" ]; then wc -c < "$1"; else echo 0; fi; }
s0="$(size "/tmp/$1")"; k0="$(size ".cache/metrics/$1")"
t=""; if command -v timeout >/dev/null 2>&1; then t="timeout 300"; fi
$t scripts/run-litmus-test.sh ci-release --size instant --phase pre-build --compact 2>&1 </dev/null | cat >/dev/null
s1="$(size "/tmp/$1")"; k1="$(size ".cache/metrics/$1")"
echo "stray=$(( s1 - s0 )) kept=$(( k1 - k0 ))"
]] }
local stray, kept = (r.stdout or ""):match("stray=(%-?%d+) kept=(%-?%d+)")
local got = (r.stdout or "") .. (r.stderr or ""):sub(1, 300)
T:arm("1 the runner emits its timing record into the checkout", (tonumber(kept) or 0) > 0, got)
T:arm("1 and none of it reaches /tmp", stray == "0", got)

-- Ask a resolver (the shipped one, or `lib`) where a log lives. root nil = no argument's worth of root.
local function resolve(o)
    local x = T:run{ SH, "-s", "--", o.lib or (ROOT .. "/" .. SUBJECT), BASE, o.root or "", cwd = o.cwd or ROOT, env_unset = { "TILLANDSIAS_*", "PROJECT_ROOT" },
        env = { PATH = env.get("PATH"), PROJECT_ROOT = o.project }, stdin = '. "$1"\nmetrics_default_log "$2" "$3"\n' }
    return (x.stdout or ""):gsub("\r", ""), (x.stderr or ""):gsub("\r", "")
end
fs.mkdir(W.rel .. "/wt")
fs.write(W.rel .. "/wt/.git", "gitdir: " .. ROOT .. "/.git/worktrees/probe\n")
local WT = W.abs .. "/wt"
local path = resolve{ root = WT }
T:arm("1 a root whose .git is a file is a checkout", path == WT .. "/.cache/metrics/" .. BASE, path)

-- 2. Outside: the library copied where no checkout is above it. The scratch dirs sit inside this one, but
-- the library looks only at its own parent.
local function outside(tag, body)
    fs.mkdir(W.rel .. "/" .. tag); fs.mkdir(W.rel .. "/" .. tag .. "/nested")
    fs.write(W.rel .. "/" .. tag .. "/nested/metrics-log-path.sh", body)
    return W.abs .. "/" .. tag .. "/nested"
end
local out_dir = outside("outside", src)
local said
path, said = resolve{ lib = out_dir .. "/metrics-log-path.sh", cwd = out_dir }
T:arm("2 CONTROL outside a checkout the /tmp fallback still fires", path == "/tmp/" .. BASE, path)
T:arm("2 and names itself and where it ran", text.contains(said, "timing-log: fallback:/tmp:no-checkout-from:") and text.contains(said, "/outside/nested"), said)
path = resolve{ root = "/tmp/definitely-not-a-checkout", project = ROOT, cwd = W.abs }
T:arm("3 PROJECT_ROOT wins over a root that is not a checkout", path == ROOT .. "/.cache/metrics/" .. BASE, path)

-- MUTATION, each against the shipped text.
local function mutant(tag, from, to)
    local a, b = src:find(from, 1, true)
    if not a then T:refuse("mutation-anchor-missing", from) end
    local d = outside(tag, src:sub(1, a - 1) .. to .. src:sub(b + 1))
    return { lib = d .. "/metrics-log-path.sh", cwd = d }
end
local m = mutant("m-dir", '[ -e "$1/.git" ]', '[ -d "$1/.git" ]')
m.root = WT
path = resolve(m)
T:arm("4 MUTATION a resolver that wants .git to be a directory fails arm 1", path == "/tmp/" .. BASE, path)
m = mutant("m-quiet", '"$_mdl_label" "$_mdl_fb" "$PWD" >&2', '"$_mdl_label" "$_mdl_fb" "$PWD" >/dev/null')
path, said = resolve(m)
T:arm("4 MUTATION a silent fallback fails arm 2", path == "/tmp/" .. BASE and said == "", path .. " " .. said)
m = mutant("m-project", 'in "$_mdl_root" "${PROJECT_ROOT:-}"', 'in "$_mdl_root"')
m.root, m.project = "/tmp/definitely-not-a-checkout", ROOT
path = resolve(m)
T:arm("4 MUTATION a resolver that ignores PROJECT_ROOT fails arm 3", path == "/tmp/" .. BASE, path)

T:finish()
