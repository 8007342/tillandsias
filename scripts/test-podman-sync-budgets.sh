#!/usr/bin/env bash
# @trace spec:podman-orchestration
#
# Fixture for scripts/check-podman-sync-budgets.sh (order 714-4r6w).
#
# A gate that only ever passes is decoration. The negative controls below are
# the load-bearing cases: the checker must FAIL on direct std commands,
# escape-hatch growth, unbounded capture, and sleeping production waits.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAN="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary)"
LUA="$ROOT/scripts/lua/check-podman-sync-budgets.lua"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$LUA" ] || fail "gate not found: $LUA"

# --- case 1: the live tree is bounded ----------------------------------------
out="$("$PLAN" script run "$LUA")" || fail "case 1: live tree must pass, got '$out'"
case "$out" in
    ok:podman-sync-bounded:*) ;;
    *) fail "case 1: unexpected verdict '$out'" ;;
esac
echo "ok: case 1 — live tree passes ($out)"

# --- case 2 (NEGATIVE CONTROL): a direct std podman Command is refused --------
mkdir -p "$WORK/crates/fixture/src"
cat > "$WORK/crates/fixture/src/bad.rs" <<'RS'
fn probe() {
    let mut cmd = std::process::Command::new("podman");
    let _ = cmd.arg("ps").output();
}
RS
out="$(TILLANDSIAS_REPO_ROOT="$WORK" PODMAN_SYNC_SEARCH_ROOT=crates "$PLAN" script run "$LUA" 2>/dev/null)"
rc=$?
[ "$rc" -ne 0 ] || fail "case 2: a direct podman Command must be refused"
case "$out" in
    violation:direct-command:*) ;;
    *) fail "case 2: expected violation:direct-command, got '$out'" ;;
esac
echo "ok: case 2 — direct std podman Command refused"

# --- case 3 (NEGATIVE CONTROL): the escape hatch cannot grow silently --------
rm "$WORK/crates/fixture/src/bad.rs"
cat > "$WORK/crates/fixture/src/hatch.rs" <<'RS'
fn a() { let _ = cmd.spawn_caller_owned_lifetime(); }
fn b() { let _ = cmd.spawn_caller_owned_lifetime(); }
RS
out="$(TILLANDSIAS_REPO_ROOT="$WORK" PODMAN_SYNC_SEARCH_ROOT=crates PODMAN_SYNC_ESCAPE_HATCHES=1 "$PLAN" script run "$LUA" 2>/dev/null)"
rc=$?
[ "$rc" -ne 0 ] || fail "case 3: a second caller-owned spawn must be refused"
case "$out" in
    violation:escape-hatch-grew:2) ;;
    *) fail "case 3: expected violation:escape-hatch-grew:2, got '$out'" ;;
esac
echo "ok: case 3 — escape hatch counted, not merely allowed"

# --- case 4: the reviewed count is what makes case 3 a decision --------------
out="$(TILLANDSIAS_REPO_ROOT="$WORK" PODMAN_SYNC_SEARCH_ROOT=crates PODMAN_SYNC_ESCAPE_HATCHES=2 "$PLAN" script run "$LUA")" \
    || fail "case 4: raising the reviewed count must allow it, got '$out'"
[ "$out" = "ok:podman-sync-bounded:2" ] || fail "case 4: unexpected verdict '$out'"
echo "ok: case 4 — raising the reviewed count is the sanctioned path"

# --- case 5 (NEGATIVE CONTROL): an unbounded child-pipe capture is refused ---
# Order 795-hzpg slice A. The path must sit under tillandsias-podman/src/ —
# the scan is scoped to the crate the capped reader lives in.
rm "$WORK/crates/fixture/src/hatch.rs"
mkdir -p "$WORK/crates/tillandsias-podman/src"
cat > "$WORK/crates/tillandsias-podman/src/bad_capture.rs" <<'RS'
fn probe(mut pipe: std::process::ChildStdout) {
    let mut buf = Vec::new();
    let _ = pipe.read_to_end(&mut buf);
}
RS
out="$(TILLANDSIAS_REPO_ROOT="$WORK" PODMAN_SYNC_SEARCH_ROOT=crates "$PLAN" script run "$LUA" 2>/dev/null)"
rc=$?
[ "$rc" -ne 0 ] || fail "case 5: an unbounded child-pipe capture must be refused"
case "$out" in
    violation:unbounded-capture:1) ;;
    *) fail "case 5: expected violation:unbounded-capture:1, got '$out'" ;;
esac
rm "$WORK/crates/tillandsias-podman/src/bad_capture.rs"
echo "ok: case 5 — unbounded child-pipe capture refused"

# --- case 6 (NEGATIVE CONTROL): a sleeping child-wait poll is refused -------
cat > "$WORK/crates/tillandsias-podman/src/busy_wait.rs" <<'RS'
/// Documentation may name `thread::sleep` without becoming executable.
fn wait(mut child: std::process::Child) -> std::io::Result<()> {
    loop {
        if child.try_wait()?.is_some() {
            return Ok(());
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}
RS
mkdir -p "$WORK/crates/tillandsias-podman/tests"
cat > "$WORK/crates/tillandsias-podman/tests/allowed_poll.rs" <<'RS'
fn test_only_wait(mut child: std::process::Child) {
    while child.try_wait().unwrap().is_none() {
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}
RS
out="$(TILLANDSIAS_REPO_ROOT="$WORK" PODMAN_SYNC_SEARCH_ROOT=crates "$PLAN" script run "$LUA" 2>/dev/null)"
rc=$?
[ "$rc" -ne 0 ] || fail "case 6: a sleeping child-wait poll must be refused"
case "$out" in
    violation:sleep-poll:1) ;;
    *) fail "case 6: expected violation:sleep-poll:1, got '$out'" ;;
esac
rm "$WORK/crates/tillandsias-podman/src/busy_wait.rs"
rm "$WORK/crates/tillandsias-podman/tests/allowed_poll.rs"
echo "ok: case 6 — sleeping child-wait poll refused"

# --- case 7: legacy absolute roots (including spaces) remain readable --------
EXT="$WORK/external root"
mkdir -p "$EXT/crates/fixture/src"
cat > "$EXT/crates/fixture/src/bad.rs" <<'RS'
fn probe() { let _ = std::process::Command::new("podman"); }
RS
out="$(PODMAN_SYNC_SEARCH_ROOT="$EXT/crates" "$PLAN" script run "$LUA" 2>/dev/null)"
rc=$?
[ "$rc" -ne 0 ] || fail "case 7: an external root direct command must be refused"
case "$out" in
    violation:direct-command:1) ;;
    *) fail "case 7: external space-path verdict changed: '$out'" ;;
esac
echo "ok: case 7 — external root with spaces is scanned through typed listing"

# --- case 8: malformed budgets fail loudly instead of defaulting to one ------
out="$(TILLANDSIAS_REPO_ROOT="$WORK" PODMAN_SYNC_SEARCH_ROOT=crates PODMAN_SYNC_ESCAPE_HATCHES=wat "$PLAN" script run "$LUA" 2>/dev/null)"
rc=$?
[ "$rc" -eq 2 ] || fail "case 8: malformed escape budget must block, got rc=$rc out='$out'"
[ "$out" = "blocked:podman-sync-bounded:invalid-escape-hatches:wat" ] \
    || fail "case 8: malformed escape budget verdict changed: '$out'"
echo "ok: case 8 — malformed escape budget is explicit"

# --- case 9: CRLF hatch diagnostics retain the matched source bytes ----------
mkdir -p "$WORK/crlf/crates/fixture/src"
printf 'fn a() { let _ = cmd.spawn_caller_owned_lifetime(); }\r\nfn b() { let _ = cmd.spawn_caller_owned_lifetime(); }\r\n' \
    > "$WORK/crlf/crates/fixture/src/hatch.rs"
if raw="$(TILLANDSIAS_REPO_ROOT="$WORK/crlf" PODMAN_SYNC_SEARCH_ROOT=crates PODMAN_SYNC_ESCAPE_HATCHES=1 "$PLAN" script run "$LUA" 2>&1)"; then
    fail "case 9: CRLF escape hatch growth must be refused"
elif grep -q "$(printf '\r')" <<<"$raw"; then
    echo "ok: case 9 — CRLF hatch diagnostic retains matched source CR byte"
else
    fail "case 9: CRLF hatch diagnostic normalized the matched source line"
fi

# --- case 10: follow an absolute starting symlink, but not interior links ----
ln -s "$EXT/crates" "$EXT/scan alias"
out="$(PODMAN_SYNC_SEARCH_ROOT="$EXT/scan alias" "$PLAN" script run "$LUA" 2>/dev/null)"
rc=$?
[ "$rc" -ne 0 ] || fail "case 10: starting symlink must not hide a direct podman Command"
case "$out" in
    violation:direct-command:1) ;;
    *) fail "case 10: starting symlink verdict changed: '$out'" ;;
esac
echo "ok: case 10 — absolute starting symlink is followed"

# --- case 11: a broken external start cannot become a green empty scan --------
ln -s "$EXT/missing" "$EXT/broken scan"
out="$(PODMAN_SYNC_SEARCH_ROOT="$EXT/broken scan" "$PLAN" script run "$LUA" 2>/dev/null)"
rc=$?
[ "$rc" -eq 2 ] || fail "case 11: broken external root must block, got rc=$rc out='$out'"
case "$out" in
    blocked:podman-sync-bounded:search-root-unreadable:*) ;;
    *) fail "case 11: broken external root verdict changed: '$out'" ;;
esac
echo "ok: case 11 — broken external root cannot report green"

echo "PASS: podman sync budgets (11/11)"
