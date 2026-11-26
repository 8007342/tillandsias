-- @env PATH HOME
-- @trace spec:default-image, order:2387-b6v2
--
-- test-harness-byte-cheap.lua — the warm harness byte-cost contract of images/default/lib-common.sh.
-- Ported from the .sh of the same name (2387-b6v2). No network or Podman: a fake official Claude
-- installer and a fake curl count installer and distribution attempts, and a fake release archive
-- drives the shared prebuilt-tool cache lock. The shipped functions are extracted from
-- lib-common.sh by name (so drift in production is what is tested) and run in ONE bash session,
-- because the fixtures share state in order (a warm cache, a last-good, a lock); the session
-- prints one observation line per fixture and the arms below judge them.
--
--   1 warm background + foreground coalesce: one installer fetch, one run, zero dist, no unguarded probe
--   2 a later session short-circuits even the install.sh fetch while the validated record is current
--   3 the real foreground launch is not opted out of official updates
--   4 two sibling containers' cold misses coalesce to one fetch, one run, one distribution
--   5 a failed installer keeps a usable last-good and leaks no refresh.lock
--   6 a corrupt installer candidate selects last-good; the corrupt launcher fails its probe
--   7 a hung installer is bounded by the timeout, reuses a usable binary, releases the lock
--   8 a warm foreground behind an active owner keeps a last-good snapshot that survives the owner's mutation
--   9 an interrupted lock owner's installer child and lock are cleaned; the foreground did not wait
--  10 stale Claude and cargo mkdir locks are reclaimed
--  11 concurrent cargo cold misses fetch once; the warm executable path fetches nothing
--
-- The .sh stopped at its first failed check; here every fixture is judged, and a fixture whose
-- line never printed (the session died) fails by name.
--
-- Usage: tillandsias-plan script run scripts/lua/test-harness-byte-cheap.lua
-- Verdict: ok:harness-byte-cheap:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("harness-byte-cheap")
local SH, ROOT = fixture.posix_shell("/bin/bash"), fixture.repo_root()
local w = T:scratch()

local SESSION = [==[
set -uo pipefail
ROOT="$1"; WORK="$2"
. "$ROOT/scripts/litmus-stdlib.sh"
SESSION_STAMP=""
cleanup() { [ -n "$SESSION_STAMP" ] && rm -f "$SESSION_STAMP"; }
trap cleanup EXIT
export HOME="$WORK/home"
export PROJECT_CACHE="$WORK/project-cache"
export CARGO_HOME="$PROJECT_CACHE/cargo"
export HARNESS_CURL_ROOT="$PROJECT_CACHE/harness-curl"
export INSTALLER_FETCH_LOG="$WORK/installer-fetch.log"
export INSTALLER_RUN_LOG="$WORK/installer-run.log"
export DIST_FETCH_LOG="$WORK/dist-fetch.log"
export PROBE_UPDATE_LOG="$WORK/probe-update.log"
export PREBUILT_FETCH_LOG="$WORK/prebuilt-fetch.log"
export MOCK_CLAUDE_VERSION="2.1.218"
mkdir -p "$HOME" "$CARGO_HOME/bin" "$WORK/bin" "$WORK/fixtures"
touch "$INSTALLER_FETCH_LOG" "$INSTALLER_RUN_LOG" "$DIST_FETCH_LOG" "$PROBE_UPDATE_LOG" "$PREBUILT_FETCH_LOG"
c() { grep -cFx -- "$1" "$2" 2>/dev/null || true; }
yn() { if "$@"; then echo y; else echo n; fi; }
sed -n \
    '/^install_prebuilt()/,/^}/p;
     /^claude_probe()/,/^}/p;
     /^claude_version()/,/^}/p;
     /^claude_last_good_path()/,/^}/p;
     /^claude_last_good_version_file()/,/^}/p;
     /^claude_refresh_record_file()/,/^}/p;
     /^claude_record_refresh_current()/,/^}/p;
     /^claude_refresh_is_current()/,/^}/p;
     /^claude_session_refresh_stamp()/,/^}/p;
     /^claude_restore_cached_launcher()/,/^}/p;
     /^claude_record_curl_last_good()/,/^}/p;
     /^claude_validate_or_rollback()/,/^}/p;
     /^claude_run_locked_refresh()/,/^)/p;
     /^curl_install_claude()/,/^}/p' \
    "$ROOT/images/default/lib-common.sh" >"$WORK/functions.sh"
source "$WORK/functions.sh"
SESSION_STAMP="$(claude_session_refresh_stamp)"
chmod +x "$WORK/fixtures/claude" "$WORK/fixtures/claude-install.sh" "$WORK/bin/curl"
export CLAUDE_BINARY_FIXTURE="$WORK/fixtures/claude"
export CLAUDE_INSTALLER_FIXTURE="$WORK/fixtures/claude-install.sh"
mkdir -p "$WORK/fixtures/prebuilt"
printf '#!/usr/bin/env bash\nprintf cargo-demo\\n\n' >"$WORK/fixtures/prebuilt/cargo-demo"
chmod +x "$WORK/fixtures/prebuilt/cargo-demo"
tar -czf "$WORK/fixtures/prebuilt.tar.gz" -C "$WORK/fixtures/prebuilt" cargo-demo
export PREBUILT_ARCHIVE="$WORK/fixtures/prebuilt.tar.gz"
export PATH="$WORK/bin:$PATH"
LOCK="$HARNESS_CURL_ROOT/claude/refresh.lock"

# 1
mkdir -p "$HARNESS_CURL_ROOT/claude/share/versions"
install -m 0755 "$WORK/fixtures/claude" "$HARNESS_CURL_ROOT/claude/share/versions/2.1.217"
rm -f "$SESSION_STAMP"; rm -rf "$LOCK"
(curl_install_claude) & a=$!
(curl_install_claude) & b=$!
wait "$a"; ra=$?; wait "$b"; rb=$?
echo "F1 bg=$ra fg=$rb fetch=$(c fetch "$INSTALLER_FETCH_LOG") run=$(c run "$INSTALLER_RUN_LOG") dist=$(c dist "$DIST_FETCH_LOG") unguarded=$(c unguarded "$PROBE_UPDATE_LOG")"

# 2
rm -f "$SESSION_STAMP"
TILLANDSIAS_CLAUDE_REFRESH_STAMP="$WORK/next-container.done" curl_install_claude; r=$?
echo "F2 rc=$r fetch=$(c fetch "$INSTALLER_FETCH_LOG") dist=$(c dist "$DIST_FETCH_LOG")"

# 3
"$HOME/.local/bin/claude" --version >/dev/null
echo "F3 unguarded=$(c unguarded "$PROBE_UPDATE_LOG")"

# 4
rm -rf "$HARNESS_CURL_ROOT/claude"
: >"$INSTALLER_FETCH_LOG"; : >"$INSTALLER_RUN_LOG"; : >"$DIST_FETCH_LOG"
mkdir -p "$WORK/sibling-a" "$WORK/sibling-b"
( HOME="$WORK/sibling-a" TILLANDSIAS_CLAUDE_REFRESH_STAMP="$WORK/sibling-a.done" curl_install_claude ) & a=$!
( HOME="$WORK/sibling-b" TILLANDSIAS_CLAUDE_REFRESH_STAMP="$WORK/sibling-b.done" curl_install_claude ) & b=$!
wait "$a"; ra=$?; wait "$b"; rb=$?
echo "F4 a=$ra b=$rb fetch=$(c fetch "$INSTALLER_FETCH_LOG") run=$(c run "$INSTALLER_RUN_LOG") dist=$(c dist "$DIST_FETCH_LOG")"

# 5
export HOME="$WORK/failure-home"
mkdir -p "$HOME/.local/bin" "$HOME/.local/share"
rm -f "$(claude_session_refresh_stamp)"
ln -sfn "$HARNESS_CURL_ROOT/claude/share" "$HOME/.local/share/claude"
ln -sfn "$HOME/.local/share/claude/versions/$MOCK_CLAUDE_VERSION" "$HOME/.local/bin/claude"
install -m 0755 "$WORK/fixtures/claude" "$(claude_last_good_path)"
rm -f "$(claude_refresh_record_file)"
export CURL_FAIL=1
CC_BIN=""; curl_install_claude; r=$?
unset CURL_FAIL
echo "F5 rc=$r usable=$(yn test -x "$CC_BIN") lock=$(yn test -d "$LOCK")"

# 6
rm -f "$(claude_session_refresh_stamp)" "$(claude_refresh_record_file)"
export INSTALLER_CORRUPT=1
CC_BIN=""; curl_install_claude; r=$?
unset INSTALLER_CORRUPT
echo "F6 rc=$r lastgood=$(yn test "$CC_BIN" = "$(claude_last_good_path)") corrupt_probe=$(yn claude_probe "$HOME/.local/bin/claude") lock=$(yn test -d "$LOCK")"

# 7
rm -f "$(claude_session_refresh_stamp)" "$(claude_refresh_record_file)"
export INSTALLER_HANG=1 TILLANDSIAS_CLAUDE_INSTALL_TIMEOUT_SECONDS=1
CC_BIN=""; curl_install_claude; r=$?
unset INSTALLER_HANG TILLANDSIAS_CLAUDE_INSTALL_TIMEOUT_SECONDS
echo "F7 rc=$r usable=$(yn test -x "$CC_BIN") lock=$(yn test -d "$LOCK")"

# 8
ln -sfn "$HOME/.local/share/claude/versions/$MOCK_CLAUDE_VERSION" "$HOME/.local/bin/claude"
rm -f "$(claude_session_refresh_stamp)" "$(claude_refresh_record_file)"
export INSTALLER_DELAY_CORRUPT=1
curl_install_claude & owner=$!
n=0; while [ ! -s "$LOCK/owner.pid" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
acq=$(yn test -s "$LOCK/owner.pid")
CC_BIN=""; curl_install_claude; r=$?
fg="$CC_BIN"
wait "$owner"; ro=$?
unset INSTALLER_DELAY_CORRUPT
echo "F8 acquired=$acq rc=$r lastgood=$(yn test "$fg" = "$(claude_last_good_path)") owner=$ro launcher_probe=$(yn claude_probe "$HOME/.local/bin/claude") fg_probe=$(yn claude_probe "$fg") lock=$(yn test -d "$LOCK")"

# 9
ln -sfn "$HOME/.local/share/claude/versions/$MOCK_CLAUDE_VERSION" "$HOME/.local/bin/claude"
rm -f "$(claude_session_refresh_stamp)" "$(claude_refresh_record_file)"
export INSTALLER_HANG=1 TILLANDSIAS_CLAUDE_INSTALL_TIMEOUT_SECONDS=30
claude_run_locked_refresh "$LOCK" "$WORK/interrupt-result" "$WORK/interrupt-session.done" & ip=$!
n=0; while [ ! -s "$LOCK/owner.pid" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
acq=$(yn test -s "$LOCK/owner.pid")
io="$(cat "$LOCK/owner.pid" 2>/dev/null)"
CC_BIN=""; curl_install_claude; r=$?
lg=$(yn test "$CC_BIN" = "$(claude_last_good_path)")
held=$(yn test -d "$LOCK")
[ -n "$io" ] && kill -TERM "$io"
wait "$ip" 2>/dev/null
unset INSTALLER_HANG TILLANDSIAS_CLAUDE_INSTALL_TIMEOUT_SECONDS
echo "F9 acquired=$acq rc=$r lastgood=$lg held=$held lock=$(yn test -d "$LOCK")"

# 10
rm -f "$(claude_session_refresh_stamp)" "$(claude_refresh_record_file)"
mkdir -p "$LOCK"
mf_touch_age_minutes "$LOCK" 31
: >"$INSTALLER_FETCH_LOG"
curl_install_claude; r=$?
cf=$(c fetch "$INSTALLER_FETCH_LOG"); cl=$(yn test -d "$LOCK")
rm -rf "$CARGO_HOME/bin/cargo-demo"
mkdir -p "$PROJECT_CACHE/prebuilt-locks/cargo-demo.lock"
mf_touch_age_minutes "$PROJECT_CACHE/prebuilt-locks/cargo-demo.lock" 31
install_prebuilt cargo-demo https://example.invalid/prebuilt.tar.gz
echo "F10 rc=$r fetch=$cf lock=$cl cargo=$(yn test -x "$CARGO_HOME/bin/cargo-demo") cargolock=$(yn test -d "$PROJECT_CACHE/prebuilt-locks/cargo-demo.lock")"

# 11
rm -f "$CARGO_HOME/bin/cargo-demo"
: >"$PREBUILT_FETCH_LOG"
(install_prebuilt cargo-demo https://example.invalid/prebuilt.tar.gz) & a=$!
(install_prebuilt cargo-demo https://example.invalid/prebuilt.tar.gz) & b=$!
wait "$a"; ra=$?; wait "$b"; rb=$?
cold=$(c fetch "$PREBUILT_FETCH_LOG")
install_prebuilt cargo-demo https://example.invalid/prebuilt.tar.gz
echo "F11 a=$ra b=$rb cold=$cold warm=$(c fetch "$PREBUILT_FETCH_LOG")"
]==]

-- The fakes, byte for byte the .sh's.
fs.mkdir(w.rel .. "/fixtures"); fs.mkdir(w.rel .. "/bin")
fs.write(w.rel .. "/fixtures/claude", [==[#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
    if [ "${DISABLE_AUTOUPDATER:-}" != "1" ] || [ "${DISABLE_UPDATES:-}" != "1" ]; then
        printf 'unguarded\n' >>"$PROBE_UPDATE_LOG"
    fi
    printf '%s (Claude Code)\n' "$MOCK_CLAUDE_VERSION"
    exit 0
fi
exit 0
]==])
fs.write(w.rel .. "/fixtures/claude-install.sh", [==[#!/usr/bin/env bash
set -eu
printf 'run\n' >>"$INSTALLER_RUN_LOG"
if [ "${INSTALLER_HANG:-0}" = "1" ]; then
    sleep 5
fi
if [ "${INSTALLER_DELAY_CORRUPT:-0}" = "1" ]; then
    sleep 1
    INSTALLER_CORRUPT=1
fi
if [ "${INSTALLER_CORRUPT:-0}" = "1" ]; then
    mkdir -p "$HOME/.local/share/claude/versions" "$HOME/.local/bin"
    printf '#!/usr/bin/env bash\nexit 1\n' \
        >"$HOME/.local/share/claude/versions/9.9.9-broken"
    chmod +x "$HOME/.local/share/claude/versions/9.9.9-broken"
    ln -sfn "$HOME/.local/share/claude/versions/9.9.9-broken" \
        "$HOME/.local/bin/claude"
    exit 0
fi
if [ -x "$HOME/.local/bin/claude" ]; then
    exit 0
fi
printf 'dist\n' >>"$DIST_FETCH_LOG"
mkdir -p "$HOME/.local/share/claude/versions" "$HOME/.local/bin"
install -m 0755 "$CLAUDE_BINARY_FIXTURE" \
    "$HOME/.local/share/claude/versions/$MOCK_CLAUDE_VERSION"
ln -sfn "$HOME/.local/share/claude/versions/$MOCK_CLAUDE_VERSION" \
    "$HOME/.local/bin/claude"
]==])
fs.write(w.rel .. "/bin/curl", [==[#!/usr/bin/env bash
set -eu
out=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            shift
            out="$1"
            ;;
        http://* | https://*)
            url="$1"
            ;;
    esac
    shift
done
[ -n "$out" ] || exit 2
if [ "${CURL_FAIL:-0}" = "1" ]; then
    exit 22
fi
case "$url" in
    https://claude.ai/install.sh)
        printf 'fetch\n' >>"$INSTALLER_FETCH_LOG"
        cp "$CLAUDE_INSTALLER_FIXTURE" "$out"
        ;;
    *prebuilt.tar.gz)
        printf 'fetch\n' >>"$PREBUILT_FETCH_LOG"
        cp "$PREBUILT_ARCHIVE" "$out"
        ;;
    *)
        exit 22
        ;;
esac
]==])

local r = T:run{ SH, "-s", "--", ROOT, w.abs, stdin = SESSION, env_unset = { "TILLANDSIAS_*", "CURL_FAIL", "INSTALLER_*" }, timeout_ms = 300000 }
local obs = {}
for l in (r.stdout or ""):gsub("\r", ""):gmatch("[^\n]+") do
    local k, rest = l:match("^(F%d+) (.*)$")
    if k then
        obs[k] = { line = rest }
        for a, b in rest:gmatch("([%w_]+)=(%S*)") do obs[k][a] = b end
    end
end
local tail = " | rc=" .. tostring(r.code) .. " " .. tostring(r.stderr or ""):sub(-400)
local function arm(n, label, pred)
    local o = obs["F" .. n]
    T:arm(n .. " " .. label, o ~= nil and pred(o), o and o.line or ("the session never reached fixture " .. n .. tail))
end
arm(1, "warm background+foreground coalesced with zero dist bytes", function(o)
    return o.bg == "0" and o.fg == "0" and o.fetch == "1" and o.run == "1" and o.dist == "0" and o.unguarded == "0" end)
arm(2, "a recent validated version short-circuits install.sh across launches", function(o)
    return o.rc == "0" and o.fetch == "1" and o.dist == "0" end)
arm(3, "the official foreground launch-time updater remains enabled", function(o) return o.unguarded == "1" end)
arm(4, "sibling cold misses coalesced to one distribution", function(o)
    return o.a == "0" and o.b == "0" and o.fetch == "1" and o.run == "1" and o.dist == "1" end)
arm(5, "a failed installer retained last-good and cleaned the lock", function(o)
    return o.rc == "0" and o.usable == "y" and o.lock == "n" end)
arm(6, "a corrupt installer candidate selects last-good", function(o)
    return o.rc == "0" and o.lastgood == "y" and o.corrupt_probe == "n" and o.lock == "n" end)
arm(7, "an installer timeout is bounded and lock-safe", function(o)
    return o.rc == "0" and o.usable == "y" and o.lock == "n" end)
arm(8, "a foreground snapshot survives the owner's launcher mutation", function(o)
    return o.acquired == "y" and o.rc == "0" and o.lastgood == "y" and o.owner == "0" and o.launcher_probe == "n"
        and o.fg_probe == "y" and o.lock == "n" end)
arm(9, "an interrupted installer child and lock are cleaned", function(o)
    return o.acquired == "y" and o.rc == "0" and o.lastgood == "y" and o.held == "y" and o.lock == "n" end)
arm(10, "stale Claude and cargo locks self-heal", function(o)
    return o.rc == "0" and o.fetch == "1" and o.lock == "n" and o.cargo == "y" and o.cargolock == "n" end)
arm(11, "a cargo cold miss coalesces and the warm path is byte-free", function(o)
    return o.a == "0" and o.b == "0" and o.cold == "1" and o.warm == "1" end)
T:finish()
