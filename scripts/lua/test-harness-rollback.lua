-- @env PATH HOME
-- @trace spec:default-image, order:284, order:299, order:2412-ewmt
--
-- test-harness-rollback.lua — the order-284 harness last-good rollback in
-- images/default/lib-common.sh. Ported from the .sh of the same name (2412-ewmt).
--
-- The functions under test are cut from the shipped library (never the whole file) and run in
-- bash against a stub npm whose @latest installs a BROKEN codex and whose @1.2.3 installs a
-- working one. (Codex is the npm-managed harness this protects: order 459 moved opencode and
-- claude to the launch-time curl channel.) Each fixture is its own bash run over one scratch home.
--   1 a broken @latest with a recorded last-good rolls back to it, and the binary is 1.2.3
--   2 a broken @latest with NO last-good is loud and non-fatal
--   3 a healthy install records its last-good (from npm ls)
--   4 a harness invisible while the npm-update lock is held WAITS for the sibling updater rather
--     than racing it (2026-07-11 gate incident: consecutive launches raced the shared prefix)
--   5 order 299: a pristine cache with every npm install failing (dead egress) fires the first-run
--     FLOOR: a loud WARNING, and the 6h cadence stamp is cleared so the next launch retries
--   6 order 299: the same failing npm with a cached harness stays silent (order-181 fail-soft)
-- harness_probe gained a CONTRACT check in order 439, so its helpers are cut too; without them the
-- probe fails on a missing function and that reads as a rollback failure.
--
-- Usage: tillandsias-plan script run scripts/lua/test-harness-rollback.lua
-- Verdict: ok:harness-rollback:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("harness-rollback")
local SH = fixture.posix_shell()
local LIB = "\n" .. fs.read("images/default/lib-common.sh"):gsub("\r", "")
local got, lost = {}, {}
for _, f in ipairs{ "harness_probe", "harness_contract_help_cmd", "harness_contract_flags", "harness_contract_ok",
    "harness_last_good_file", "harness_record_last_good", "ensure_forge_harnesses", "_require_harness" } do
    local body = LIB:match("\n(" .. f .. "%(%)%s*{\n.-\n})\n")
    if body then got[#got + 1] = body else lost[#lost + 1] = f end
end
T:arm("0 the functions under test are cut from lib-common.sh", #lost == 0, table.concat(lost, " "))
if #lost > 0 then T:finish() end
local d = T:scratch()
fs.write(d.rel .. "/funcs.sh", table.concat(got, "\n") .. "\n")
fs.mkdir(d.rel .. "/bin"); fs.mkdir(d.rel .. "/failnpm")
-- A working codex: answers --help with the contract flags, else prints its version.
local function codex(v)
    return "#!/bin/bash\ncase \"$*\" in *--help*) echo \"  --json\"; echo \"  --output-last-message\"; echo \"  --dangerously-bypass-approvals-and-sandbox\"; exit 0;; esac\necho " .. v .. "\n"
end
fs.write(d.rel .. "/bin/npm", "#!/bin/bash\n"
    .. 'if [[ "$*" == *"ls -g"* ]]; then echo "@openai/codex@9.9.9-broken"; exit 0; fi\n'
    .. 'for a in "$@"; do\n  case "$a" in\n'
    .. '    "@openai/codex@latest") printf \'#!/bin/bash\\nexit 1\\n\' > "$NPM_CONFIG_PREFIX/bin/codex"; chmod +x "$NPM_CONFIG_PREFIX/bin/codex" ;;\n'
    .. '    "@openai/codex@1.2.3") cp "$W/codex-1.2.3" "$NPM_CONFIG_PREFIX/bin/codex"; chmod +x "$NPM_CONFIG_PREFIX/bin/codex" ;;\n'
    .. '  esac\ndone\nexit 0\n')
fs.write(d.rel .. "/failnpm/npm", "#!/bin/bash\nexit 1\n")
for _, v in ipairs{ "1.2.3", "9.9.9", "raced-ok", "cached" } do fs.write(d.rel .. "/codex-" .. v, codex(v)) end
fs.mkdir(d.rel .. "/home/.cache/tillandsias-project"); fs.mkdir(d.rel .. "/prefix/bin")
fs.mkdir(d.rel .. "/empty-fallback"); fs.mkdir(d.rel .. "/empty-fallback-req")
T:run{ "chmod", "+x", d.abs .. "/bin/npm", d.abs .. "/failnpm/npm" }

-- Every fixture: the same prelude, then its own body; it prints PASS or FAIL: <why>.
local PRE = [==[
set -uo pipefail
W="$1"; cd "$W" || exit 3
export HOME="$W/home" NPM_CONFIG_PREFIX="$W/prefix" W
export PATH="$W/bin:$PATH"
C="$HOME/.cache/tillandsias-project"
trace_lifecycle() { echo "[lifecycle] $1 | ${*:2}" >&2; }
. "$W/funcs.sh"
fail() { echo "FAIL: $*"; exit 1; }
]==]
local function fx(n, what, body)
    local r = T:run{ SH, "-s", "--", d.abs, stdin = PRE .. body .. "\necho PASS\n", env_unset = { "TILLANDSIAS_*", "NPM_*" }, timeout_ms = 120000, refusal_ok = true }
    local o = text.trim(r.stdout or "")
    T:arm(n .. " " .. what, r.code == 0 and o:match("PASS$") ~= nil, o .. " " .. (r.stderr or ""):sub(-300))
end
fx(1, "a broken @latest rolls back to the recorded last-good", [==[
echo "1.2.3" > "$(harness_last_good_file codex)"
out="$(ensure_forge_harnesses 2>&1)"
grep -q <<<"$out" "rolling back to last-good 1.2.3" || fail "no rollback attempt: $out"
grep -q <<<"$out" "rollback to 1.2.3 OK" || fail "rollback did not verify: $out"
[ "$("$NPM_CONFIG_PREFIX/bin/codex" --version)" = "1.2.3" ] || fail "binary not rolled back"]==])
fx(2, "a broken @latest with no last-good is loud and non-fatal", [==[
rm -rf "$C/npm-update.lock" "$NPM_CONFIG_PREFIX/bin/codex"
rm -f "$(harness_last_good_file codex)" "$C/harness-update-stamp"
out="$(ensure_forge_harnesses 2>&1)" || fail "updater must stay fail-soft"
grep -q <<<"$out" "no last-good recorded" || fail "missing loud no-last-good trace: $out"]==])
fx(3, "a healthy install records its last-good", [==[
rm -rf "$C/npm-update.lock"
cp "$W/codex-9.9.9" "$NPM_CONFIG_PREFIX/bin/codex"; chmod +x "$NPM_CONFIG_PREFIX/bin/codex"
harness_record_last_good codex "@openai/codex" || fail "record must succeed for a healthy binary"
[ "$(cat "$(harness_last_good_file codex)")" = "9.9.9-broken" ] || fail "last-good not recorded from npm ls"]==])
fx(4, "require waits out a sibling updater instead of racing it", [==[
rm -f "$NPM_CONFIG_PREFIX/bin/codex"
mkdir -p "$C/npm-update.lock"
( sleep 3; cp "$W/codex-raced-ok" "$NPM_CONFIG_PREFIX/bin/codex"; chmod +x "$NPM_CONFIG_PREFIX/bin/codex"; sleep 1; rmdir "$C/npm-update.lock" ) &
resolved="$(TILLANDSIAS_HARNESS_FALLBACK_DIR="$W/empty-fallback-req" _require_harness codex "@openai/codex" codex 2>/dev/null)"
wait
[ -x "$resolved" ] || fail "lock-wait did not resolve the sibling-installed harness (got: $resolved)"
[ "$("$resolved")" = "raced-ok" ] || fail "resolved wrong binary"]==])
fx(5, "a pristine cache with dead egress fails LOUD and clears the cadence stamp", [==[
export TILLANDSIAS_HARNESS_FALLBACK_DIR="$W/empty-fallback"
rm -rf "$C/npm-update.lock" "$NPM_CONFIG_PREFIX/bin"/*
rm -f "$C/harness-update-stamp"
out="$(PATH="$W/failnpm:$PATH" ensure_forge_harnesses 2>&1)" || fail "floor must stay fail-soft"
grep -q <<<"$out" "WARNING: no agent harness is installed" || fail "missing first-run floor warning: $out"
[ ! -f "$C/harness-update-stamp" ] || fail "cadence stamp must be cleared so the next launch retries"]==])
fx(6, "a cached harness's update failure stays silent (order-181 fail-soft)", [==[
export TILLANDSIAS_HARNESS_FALLBACK_DIR="$W/empty-fallback"
rm -rf "$C/npm-update.lock"; rm -f "$C/harness-update-stamp"
cp "$W/codex-cached" "$NPM_CONFIG_PREFIX/bin/codex"; chmod +x "$NPM_CONFIG_PREFIX/bin/codex"
out="$(PATH="$W/failnpm:$PATH" ensure_forge_harnesses 2>&1)" || fail "updater must stay fail-soft"
if grep -q <<<"$out" "WARNING: no agent harness is installed"; then fail "a cached harness must stay silent: $out"; fi
grep -q <<<"$out" "npm update failed" || fail "expected the quiet non-fatal trace: $out"]==])
T:finish()
