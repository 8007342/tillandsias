#!/usr/bin/env bash
# @trace spec:litmus-framework, spec:versioning
#
# Fixture for order 677-33be: a test that mutates TRACKED files must restore
# them under every exit, and must repair a previous run's damage on the one
# exit it cannot catch.
#
# The damage this pins is not hypothetical. On 2026-08-11 a killed litmus sweep
# left `0.0.0-test-retag` in VERSION; release-preflight then refused every push
# on that host with `blocked:version-not-monotonic` until a human connected a
# dead test run to a failing push hours later.
#
# The cases are ordered by how the run actually ends:
#   1. SIGTERM — catchable, so the trap must restore.
#   2. SIGKILL — uncatchable, so the NEXT run must repair.
#   3. the sweep: no other script mutates tracked paths without protection.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
SENTINEL="0.0.0-test-retag"

# A miniature of the real script's contract: back up a tracked file, poison it,
# then linger. Driving the real convergence test needs podman and minutes; the
# property under test is the trap and the stale-sentinel repair, which is this.
make_repo() {
    local dir="$1"
    git init -q -b main "$dir"
    git -C "$dir" config user.email fixture@example.invalid
    git -C "$dir" config user.name Fixture
    git -C "$dir" config core.autocrlf false
    printf '0.4.260812.1\n' > "$dir/VERSION"
    mkdir -p "$dir/scripts"
    # Copy the real guard shape out of the script under test so the fixture
    # cannot drift away from what ships.
    sed -n '/^VERSION_TEST_SENTINEL=/,/^fi$/p' "$ROOT/scripts/test-image-build-convergence.sh" \
        > "$dir/scripts/guard.inc"
    cat > "$dir/scripts/victim.sh" <<'VICTIM'
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/guard.inc"
tmp="$(mktemp -d)"
cp "$ROOT/VERSION" "$tmp/VERSION.orig"
cleanup() {
    local rc=$?
    cp "$tmp/VERSION.orig" "$ROOT/VERSION"
    rm -rf "$tmp"
    trap - EXIT INT TERM HUP
    exit "$rc"
}
trap cleanup EXIT INT TERM HUP
printf '0.0.0-test-retag\n' > "$ROOT/VERSION"
echo ready > "$ROOT/.victim-ready"
# `sleep N & wait $!` rather than a foreground `sleep N`, and the difference is
# the point: bash defers a signal trap until the current FOREGROUND command
# returns, so a script parked inside a long `build-image.sh` call does not run
# its restore when SIGTERM arrives — only when that call finishes, if it ever
# does. A runner that follows SIGTERM with SIGKILL therefore skips the trap
# entirely. That is why layer 2 (the stale-sentinel repair in the NEXT run) is
# the load-bearing one and the trap is best-effort, and it is what case 2 pins.
sleep 20 & wait $!
VICTIM
    chmod +x "$dir/scripts/victim.sh"
    git -C "$dir" add -A
    git -C "$dir" commit -qm base
}

# `wait` on a signalled background job can block until the job's own children
# exit, and the victim's `sleep` outlives it under some runners. Poll instead:
# the property is that the SHELL is gone, and its restore already ran.
reap() {
    local pid="$1" i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    kill -0 "$pid" 2>/dev/null && fail "victim $pid outlived its signal"
}

wait_ready() {
    local dir="$1" i=0
    while [ ! -f "$dir/.victim-ready" ] && [ "$i" -lt 100 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    [ -f "$dir/.victim-ready" ] || fail "victim never reached its poisoned state"
    rm -f "$dir/.victim-ready"
}

# --- case 0: the SHIPPED script carries both layers --------------------------
# Cases 1 and 2 prove the PATTERN works, on a miniature that sources the real
# stale-sentinel guard. This case is what ties the pattern to the file that
# actually runs: without it the fixture could stay green while the shipped trap
# silently went back to EXIT-only.
VICTIM_SCRIPT="$ROOT/scripts/test-image-build-convergence.sh"
grep -qE '^trap cleanup EXIT INT TERM HUP$' "$VICTIM_SCRIPT"     || fail "case 0: the shipped trap must cover INT/TERM/HUP, not EXIT alone"
grep -qF 'VERSION_TEST_SENTINEL' "$VICTIM_SCRIPT"     || fail "case 0: the shipped script must carry the stale-sentinel repair"
echo "ok: case 0 — the shipped convergence test carries both layers"

# --- case 1: SIGTERM is catchable, so the trap must restore ------------------
R1="$WORK/term"
make_repo "$R1"
bash "$R1/scripts/victim.sh" &
victim=$!
wait_ready "$R1"
grep -qxF "$SENTINEL" "$R1/VERSION" || fail "case 1 setup: VERSION was never poisoned"
kill -TERM "$victim"
reap "$victim"
grep -qxF "$SENTINEL" "$R1/VERSION" && fail "case 1: SIGTERM left VERSION poisoned — EXIT-only trap"
echo "ok: case 1 — SIGTERM restores the tracked file"

# --- case 2: SIGKILL cannot be caught, so the NEXT run must repair -----------
R2="$WORK/kill"
make_repo "$R2"
bash "$R2/scripts/victim.sh" &
victim=$!
wait_ready "$R2"
kill -KILL "$victim"
reap "$victim"
grep -qxF "$SENTINEL" "$R2/VERSION" \
    || fail "case 2 setup: SIGKILL was expected to leave the sentinel behind"
# The next run repairs before doing anything else.
bash "$R2/scripts/victim.sh" &
victim=$!
wait_ready "$R2"
kill -TERM "$victim"
reap "$victim"
grep -qxF "$SENTINEL" "$R2/VERSION" \
    && fail "case 2: a later run did not repair the killed run's damage"
[ "$(cat "$R2/VERSION")" = "0.4.260812.1" ] \
    || fail "case 2: VERSION restored to the wrong content: $(cat "$R2/VERSION")"
echo "ok: case 2 — a SIGKILLed run's damage is repaired by the next run"

# --- case 3 (the sweep): no other script mutates a tracked path unguarded ----
# Redirections into $ROOT/<tracked path>. The convergence test is the one known
# mutator and carries both layers; anything else appearing here is a new
# offender and the reason this case exists.
offenders="$(grep -rnE '>[[:space:]]*"\$(ROOT|REPO_ROOT)"/(VERSION|Cargo\.toml|Cargo\.lock)' \
    "$ROOT/scripts" 2>/dev/null \
    | grep -v 'test-image-build-convergence.sh' \
    | grep -v 'test-litmus-tracked-file-kill-safety.sh' || true)"
if [ -n "$offenders" ]; then
    echo "$offenders" >&2
    fail "case 3: a script writes a tracked file without the 677-33be protection"
fi
echo "ok: case 3 — no unguarded tracked-file mutators in scripts/"

echo "PASS: litmus tracked-file kill safety (4/4)"
