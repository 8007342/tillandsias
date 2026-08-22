#!/usr/bin/env bash
# @trace spec:podman-orchestration
#
# Fixture for scripts/check-podman-sync-budgets.sh (order 714-4r6w).
#
# A gate that only ever passes is decoration. The negative controls below are
# the load-bearing cases: the checker must FAIL on a podman command built
# straight from std, and on an escape-hatch count above the reviewed number.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/check-podman-sync-budgets.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$GATE" ] || fail "gate not found: $GATE"

# --- case 1: the live tree is bounded ----------------------------------------
out="$(bash "$GATE")" || fail "case 1: live tree must pass, got '$out'"
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
out="$(cd "$WORK" && PODMAN_SYNC_SEARCH_ROOT=crates bash "$GATE" 2>/dev/null)"
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
out="$(cd "$WORK" && PODMAN_SYNC_SEARCH_ROOT=crates PODMAN_SYNC_ESCAPE_HATCHES=1 bash "$GATE" 2>/dev/null)"
rc=$?
[ "$rc" -ne 0 ] || fail "case 3: a second caller-owned spawn must be refused"
case "$out" in
    violation:escape-hatch-grew:2) ;;
    *) fail "case 3: expected violation:escape-hatch-grew:2, got '$out'" ;;
esac
echo "ok: case 3 — escape hatch counted, not merely allowed"

# --- case 4: the reviewed count is what makes case 3 a decision --------------
out="$(cd "$WORK" && PODMAN_SYNC_SEARCH_ROOT=crates PODMAN_SYNC_ESCAPE_HATCHES=2 bash "$GATE")" \
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
out="$(cd "$WORK" && PODMAN_SYNC_SEARCH_ROOT=crates bash "$GATE" 2>/dev/null)"
rc=$?
[ "$rc" -ne 0 ] || fail "case 5: an unbounded child-pipe capture must be refused"
case "$out" in
    violation:unbounded-capture:1) ;;
    *) fail "case 5: expected violation:unbounded-capture:1, got '$out'" ;;
esac
rm "$WORK/crates/tillandsias-podman/src/bad_capture.rs"
echo "ok: case 5 — unbounded child-pipe capture refused"

echo "PASS: podman sync budgets (5/5)"
