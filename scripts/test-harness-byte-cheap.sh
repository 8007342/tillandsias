#!/usr/bin/env bash
# @trace spec:default-image
# Deterministic fixture for the warm harness byte-cost contract. No network or
# Podman runtime is used: a fake official Claude installer counts installer and
# distribution attempts, while a fake release archive exercises the shared
# prebuilt-tool cache lock.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
SESSION_STAMP=""
cleanup() {
    rm -rf "$WORK"
    [ -n "$SESSION_STAMP" ] && rm -f "$SESSION_STAMP"
}
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
touch "$INSTALLER_FETCH_LOG" "$INSTALLER_RUN_LOG" "$DIST_FETCH_LOG" \
    "$PROBE_UPDATE_LOG" "$PREBUILT_FETCH_LOG"

trace_lifecycle() {
    printf '[lifecycle] %s | %s\n' "$1" "${*:2}" >&2
}
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
count_lines() {
    local pattern="$1" file="$2"
    grep -cFx -- "$pattern" "$file" 2>/dev/null || true
}

# Extract only the shipped functions under test. Keeping the fixture bound to
# lib-common.sh catches drift in the production implementation.
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
# shellcheck disable=SC1091
source "$WORK/functions.sh"
SESSION_STAMP="$(claude_session_refresh_stamp)"

# A Claude binary that records any unguarded --version invocation. Production
# probes must set both documented update-disable variables; a foreground launch
# intentionally does not.
cat >"$WORK/fixtures/claude" <<'CLAUDE'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
    if [ "${DISABLE_AUTOUPDATER:-}" != "1" ] || [ "${DISABLE_UPDATES:-}" != "1" ]; then
        printf 'unguarded\n' >>"$PROBE_UPDATE_LOG"
    fi
    printf '%s (Claude Code)\n' "$MOCK_CLAUDE_VERSION"
    exit 0
fi
exit 0
CLAUDE
chmod +x "$WORK/fixtures/claude"

# Fake official installer: an already-restored launcher is current and costs
# zero distribution bytes. A cold cache records exactly one distribution and
# installs the fixture into persistent versions/.
cat >"$WORK/fixtures/claude-install.sh" <<'INSTALLER'
#!/usr/bin/env bash
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
INSTALLER
chmod +x "$WORK/fixtures/claude-install.sh"
export CLAUDE_BINARY_FIXTURE="$WORK/fixtures/claude"
export CLAUDE_INSTALLER_FIXTURE="$WORK/fixtures/claude-install.sh"

# One tiny executable archive stands in for a cargo release asset.
mkdir -p "$WORK/fixtures/prebuilt"
printf '#!/usr/bin/env bash\nprintf cargo-demo\\n\n' \
    >"$WORK/fixtures/prebuilt/cargo-demo"
chmod +x "$WORK/fixtures/prebuilt/cargo-demo"
tar -czf "$WORK/fixtures/prebuilt.tar.gz" -C "$WORK/fixtures/prebuilt" cargo-demo
export PREBUILT_ARCHIVE="$WORK/fixtures/prebuilt.tar.gz"

cat >"$WORK/bin/curl" <<'CURL'
#!/usr/bin/env bash
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
CURL
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"

reset_claude_session() {
    rm -f "$SESSION_STAMP"
    rm -rf "$HARNESS_CURL_ROOT/claude/refresh.lock"
}

# Fixture 1: warm persistent versions but ephemeral launcher. Background
# ensure + foreground require share one session and invoke the installer once,
# download no distribution, and never self-update from a health probe.
mkdir -p "$HARNESS_CURL_ROOT/claude/share/versions"
install -m 0755 "$WORK/fixtures/claude" \
    "$HARNESS_CURL_ROOT/claude/share/versions/2.1.217"
reset_claude_session
(curl_install_claude) &
warm_bg=$!
(curl_install_claude) &
warm_fg=$!
wait "$warm_bg" || fail "warm background refresh failed"
wait "$warm_fg" || fail "warm foreground refresh failed"
[ "$(count_lines fetch "$INSTALLER_FETCH_LOG")" = "1" ] \
    || fail "same-container calls did not coalesce installer fetch"
[ "$(count_lines run "$INSTALLER_RUN_LOG")" = "1" ] \
    || fail "same-container calls did not coalesce installer run"
[ "$(count_lines dist "$DIST_FETCH_LOG")" = "0" ] \
    || fail "warm current cache downloaded a distribution"
[ "$(count_lines unguarded "$PROBE_UPDATE_LOG")" = "0" ] \
    || fail "--version probe was allowed to self-update"
printf 'fixture 1 ok: warm background+foreground coalesced with zero dist bytes\n'

# A distinct later container/session short-circuits even the installer-script
# fetch while the validated version+epoch record is current.
rm -f "$SESSION_STAMP"
TILLANDSIAS_CLAUDE_REFRESH_STAMP="$WORK/next-container.done" \
    curl_install_claude || fail "current cross-launch refresh failed"
[ "$(count_lines fetch "$INSTALLER_FETCH_LOG")" = "1" ] \
    || fail "current persistent version did not short-circuit install.sh"
[ "$(count_lines dist "$DIST_FETCH_LOG")" = "0" ] \
    || fail "current persistent version downloaded a distribution"
printf 'fixture 2 ok: recent validated version short-circuits across launches\n'

# The actual foreground process is not globally opted out of official updates.
"$HOME/.local/bin/claude" --version >/dev/null
[ "$(count_lines unguarded "$PROBE_UPDATE_LOG")" = "1" ] \
    || fail "probe guards leaked into the real foreground environment"
printf 'fixture 3 ok: official foreground launch-time updater remains enabled\n'

# Fixture 4: two simulated sibling containers have separate HOME and /tmp
# session stamps but one persistent tool cache. Their cold miss downloads and
# installs exactly one distribution.
rm -rf "$HARNESS_CURL_ROOT/claude"
: >"$INSTALLER_FETCH_LOG"
: >"$INSTALLER_RUN_LOG"
: >"$DIST_FETCH_LOG"
mkdir -p "$WORK/sibling-a" "$WORK/sibling-b"
(
    HOME="$WORK/sibling-a" \
    TILLANDSIAS_CLAUDE_REFRESH_STAMP="$WORK/sibling-a.done" \
        curl_install_claude
) &
sibling_a=$!
(
    HOME="$WORK/sibling-b" \
    TILLANDSIAS_CLAUDE_REFRESH_STAMP="$WORK/sibling-b.done" \
        curl_install_claude
) &
sibling_b=$!
wait "$sibling_a" || fail "sibling A cold refresh failed"
wait "$sibling_b" || fail "sibling B cold refresh failed"
[ "$(count_lines fetch "$INSTALLER_FETCH_LOG")" = "1" ] \
    || fail "sibling calls did not coalesce installer fetch"
[ "$(count_lines run "$INSTALLER_RUN_LOG")" = "1" ] \
    || fail "sibling calls did not coalesce installer run"
[ "$(count_lines dist "$DIST_FETCH_LOG")" = "1" ] \
    || fail "cold sibling calls did not produce exactly one distribution"
printf 'fixture 4 ok: sibling cold misses coalesced to one distribution\n'

# Fixture 5: a failed installer keeps validated last-good usable and never
# leaks refresh.lock.
export HOME="$WORK/failure-home"
mkdir -p "$HOME/.local/bin" "$HOME/.local/share"
rm -f "$(claude_session_refresh_stamp)"
ln -sfn "$HARNESS_CURL_ROOT/claude/share" "$HOME/.local/share/claude"
ln -sfn "$HOME/.local/share/claude/versions/$MOCK_CLAUDE_VERSION" \
    "$HOME/.local/bin/claude"
install -m 0755 "$WORK/fixtures/claude" "$(claude_last_good_path)"
rm -f "$(claude_refresh_record_file)"
export CURL_FAIL=1
curl_install_claude || fail "offline refresh did not retain last-good"
unset CURL_FAIL
[ -x "$CC_BIN" ] || fail "offline refresh returned no usable last-good"
[ ! -d "$HARNESS_CURL_ROOT/claude/refresh.lock" ] \
    || fail "failed installer leaked refresh.lock"
printf 'fixture 5 ok: failed installer retained last-good and cleaned lock\n'

# Fixture 6: an installer that replaces the launcher with a corrupt candidate
# selects the independent validated last-good, rather than treating an
# executable-but-broken path as healthy.
rm -f "$(claude_session_refresh_stamp)" "$(claude_refresh_record_file)"
export INSTALLER_CORRUPT=1
curl_install_claude || fail "corrupt candidate did not roll back"
unset INSTALLER_CORRUPT
[ "$CC_BIN" = "$(claude_last_good_path)" ] \
    || fail "corrupt candidate did not select last-good (got $CC_BIN)"
claude_probe "$HOME/.local/bin/claude" \
    && fail "corrupt launcher fixture unexpectedly passed its probe"
[ ! -d "$HARNESS_CURL_ROOT/claude/refresh.lock" ] \
    || fail "corrupt-candidate rollback leaked refresh.lock"
printf 'fixture 6 ok: corrupt installer candidate selects last-good\n'

# Fixture 7: installer execution itself is bounded. Timing out reuses the
# current validated binary and releases the owner lock.
rm -f "$(claude_session_refresh_stamp)" "$(claude_refresh_record_file)"
export INSTALLER_HANG=1
export TILLANDSIAS_CLAUDE_INSTALL_TIMEOUT_SECONDS=1
curl_install_claude || fail "timed-out installer did not reuse validated cache"
unset INSTALLER_HANG TILLANDSIAS_CLAUDE_INSTALL_TIMEOUT_SECONDS
[ -x "$CC_BIN" ] || fail "timed-out installer returned no usable binary"
[ ! -d "$HARNESS_CURL_ROOT/claude/refresh.lock" ] \
    || fail "timed-out installer leaked refresh.lock"
printf 'fixture 7 ok: installer timeout is bounded and lock-safe\n'

# Fixture 8: a warm foreground behind an active owner selects immutable
# last-good. The owner then mutates the launcher to a broken candidate; the
# already-selected foreground path must remain independently healthy.
ln -sfn "$HOME/.local/share/claude/versions/$MOCK_CLAUDE_VERSION" \
    "$HOME/.local/bin/claude"
rm -f "$(claude_session_refresh_stamp)" "$(claude_refresh_record_file)"
export INSTALLER_DELAY_CORRUPT=1
curl_install_claude &
mutating_owner=$!
mutating_wait=0
while [ ! -s "$HARNESS_CURL_ROOT/claude/refresh.lock/owner.pid" ] \
    && [ "$mutating_wait" -lt 50 ]; do
    sleep 0.1
    mutating_wait=$((mutating_wait + 1))
done
[ -s "$HARNESS_CURL_ROOT/claude/refresh.lock/owner.pid" ] \
    || fail "mutating owner never acquired refresh.lock"
curl_install_claude || fail "warm foreground did not select last-good"
foreground_bin="$CC_BIN"
[ "$foreground_bin" = "$(claude_last_good_path)" ] \
    || fail "warm foreground selected mutable launcher ($foreground_bin)"
wait "$mutating_owner" || fail "mutating owner did not finish through rollback"
unset INSTALLER_DELAY_CORRUPT
claude_probe "$HOME/.local/bin/claude" \
    && fail "mutating owner did not replace launcher with corrupt candidate"
claude_probe "$foreground_bin" \
    || fail "foreground last-good became unhealthy after launcher mutation"
[ ! -d "$HARNESS_CURL_ROOT/claude/refresh.lock" ] \
    || fail "mutating owner leaked refresh.lock"
printf 'fixture 8 ok: foreground snapshot survives owner launcher mutation\n'

# Fixture 9: an interrupted lock owner terminates its installer child and
# releases the lock through the subshell-local signal trap.
ln -sfn "$HOME/.local/share/claude/versions/$MOCK_CLAUDE_VERSION" \
    "$HOME/.local/bin/claude"
rm -f "$(claude_session_refresh_stamp)" "$(claude_refresh_record_file)"
interrupt_result="$WORK/interrupt-result"
interrupt_lock="$HARNESS_CURL_ROOT/claude/refresh.lock"
export INSTALLER_HANG=1
export TILLANDSIAS_CLAUDE_INSTALL_TIMEOUT_SECONDS=30
claude_run_locked_refresh "$interrupt_lock" "$interrupt_result" \
    "$WORK/interrupt-session.done" &
interrupt_pid=$!
interrupt_wait=0
while [ ! -s "$interrupt_lock/owner.pid" ] && [ "$interrupt_wait" -lt 50 ]; do
    sleep 0.1
    interrupt_wait=$((interrupt_wait + 1))
done
[ -s "$interrupt_lock/owner.pid" ] || fail "interrupt fixture never acquired refresh.lock"
interrupt_owner="$(cat "$interrupt_lock/owner.pid")"
# The foreground caller has an independently validated last-good and must not
# sit behind the long-running owner.
curl_install_claude || fail "warm foreground did not reuse last-good behind owner"
[ "$CC_BIN" = "$(claude_last_good_path)" ] \
    || fail "warm foreground selected the wrong fallback behind owner"
[ -d "$interrupt_lock" ] \
    || fail "warm foreground unexpectedly displaced the active owner"
kill -TERM "$interrupt_owner"
wait "$interrupt_pid" 2>/dev/null || true
unset INSTALLER_HANG TILLANDSIAS_CLAUDE_INSTALL_TIMEOUT_SECONDS
[ ! -d "$interrupt_lock" ] || fail "interrupted installer leaked refresh.lock"
printf 'fixture 9 ok: interrupted installer child and lock are cleaned\n'

# Fixture 10: stale mkdir locks are reclaimed for both Claude and cargo paths.
rm -f "$(claude_session_refresh_stamp)"
rm -f "$(claude_refresh_record_file)"
mkdir -p "$HARNESS_CURL_ROOT/claude/refresh.lock"
touch -d '31 minutes ago' "$HARNESS_CURL_ROOT/claude/refresh.lock"
: >"$INSTALLER_FETCH_LOG"
curl_install_claude || fail "stale Claude lock was not reclaimed"
[ "$(count_lines fetch "$INSTALLER_FETCH_LOG")" = "1" ] \
    || fail "stale Claude lock reclaim skipped the bounded refresh"
[ ! -d "$HARNESS_CURL_ROOT/claude/refresh.lock" ] \
    || fail "reclaimed Claude lock leaked"

rm -rf "$CARGO_HOME/bin/cargo-demo"
mkdir -p "$PROJECT_CACHE/prebuilt-locks/cargo-demo.lock"
touch -d '31 minutes ago' "$PROJECT_CACHE/prebuilt-locks/cargo-demo.lock"
install_prebuilt cargo-demo https://example.invalid/prebuilt.tar.gz
[ -x "$CARGO_HOME/bin/cargo-demo" ] || fail "stale cargo lock was not reclaimed"
[ ! -d "$PROJECT_CACHE/prebuilt-locks/cargo-demo.lock" ] \
    || fail "reclaimed cargo lock leaked"
printf 'fixture 10 ok: stale Claude and cargo locks self-heal\n'

# Fixture 11: concurrent cargo cold misses fetch once; the warm executable
# fast-path remains zero-network. This audits the measured cargo-tool claim
# without attributing it to Claude's launcher bug.
rm -f "$CARGO_HOME/bin/cargo-demo"
: >"$PREBUILT_FETCH_LOG"
(install_prebuilt cargo-demo https://example.invalid/prebuilt.tar.gz) &
cargo_a=$!
(install_prebuilt cargo-demo https://example.invalid/prebuilt.tar.gz) &
cargo_b=$!
wait "$cargo_a" || fail "cargo cold installer A failed"
wait "$cargo_b" || fail "cargo cold installer B failed"
[ "$(count_lines fetch "$PREBUILT_FETCH_LOG")" = "1" ] \
    || fail "concurrent cargo cold misses did not coalesce"
install_prebuilt cargo-demo https://example.invalid/prebuilt.tar.gz
[ "$(count_lines fetch "$PREBUILT_FETCH_LOG")" = "1" ] \
    || fail "warm cargo executable performed network work"
printf 'fixture 11 ok: cargo cold miss coalesces and warm path is byte-free\n'

printf 'PASS: harness byte-cheap fixtures\n'
