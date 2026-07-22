#!/usr/bin/env bash
# @trace spec:podman-orchestration, spec:litmus-framework
# Order 443 slice 3 — concurrent forges shared-stack safety fixtures.
#
# Offline (fake stateful podman; no containers, no real podman needed):
#
#   fixture 1  second-forge ensure leaves the running shared containers
#              untouched (same IDs, no re-run). Driven end to end through the
#              real ensure code path by the env-gated Rust test
#              shared_stack_second_forge_ensure_reuses_running_containers.
#   fixture 2a an exiting lane does NOT tear the shared stack down while a
#              sibling lane container is in a non-running "created" state
#              (slice-1 predicate, now exercised END TO END via the CLI and
#              the stateful mock's new `ps` arm — before that arm existed the
#              harness could not represent container state at all).
#   fixture 2b an exiting lane does NOT tear the shared stack down while a
#              sibling launch is IN FLIGHT pre-create (no container exists
#              yet; only the slice-3 launch-in-flight flock marks it). This
#              is the slice-3 residual: at pre-slice-3 HEAD this case FAILS
#              (teardown fires under the in-flight launch).
#   fixture 2c control: with no lanes and no in-flight launches the LAST
#              exit still tears the stack down (the leak-side must not
#              regress into "never clean up").
#
# The CLI vehicle for fixture 2 is `tillandsias --headless --init --debug
# --status-check`: a real lane that runs the shared-stack cleanup on entry,
# brings the stack up, runs a one-shot forge, and runs the cleanup again on
# exit — the same cleanup_shared_stack_if_no_running_forge decision every
# forge lane uses (proven offline-runnable by litmus:binary-e2e-smoke).
#
# Run: scripts/test-concurrent-forge-shared-stack.sh   (exit 0 = pass)
# Env: TILLANDSIAS_BIN=<path> reuse a prebuilt binary (default: build
#      target/debug/tillandsias from this checkout).
set -euo pipefail

export TILLANDSIAS_DESTRUCTIVE_RESET_OK=0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCK="$ROOT/scripts/test-support/podman-mock.sh"
BIN="${TILLANDSIAS_BIN:-$ROOT/target/debug/tillandsias}"

if [[ ! -x "$BIN" ]]; then
    echo "[fixture] building tillandsias (debug) ..."
    (cd "$ROOT" && cargo build -q -p tillandsias-headless --bin tillandsias)
fi
if [[ ! -x "$BIN" ]]; then
    echo "FAIL: tillandsias binary not found/built at $BIN" >&2
    exit 1
fi

tmp="$(mktemp -d)"
flock_pid=""
cleanup() {
    [[ -n "$flock_pid" ]] && kill "$flock_pid" 2>/dev/null || true
    rm -rf "$tmp"
}
trap cleanup EXIT

# Fake podman on PATH: log the call shape, then delegate to the stateful mock.
shim_dir="$tmp/bin"
mkdir -p "$shim_dir"
cat >"$shim_dir/podman" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'podman %s\n' "\$*" >>"\${LITMUS_PODMAN_CALLS_FILE:?}"
exec "$MOCK" "\$@"
EOF
chmod 755 "$shim_dir/podman"

export PATH="$shim_dir:$PATH"
export LITMUS_PODMAN_MODE=fake
export LITMUS_PODMAN_STATEFUL_CONTAINERS=1
export TILLANDSIAS_ROOT="$ROOT"
export TILLANDSIAS_NO_SINGLETON=1
unset TILLANDSIAS_PODMAN_BIN 2>/dev/null || true
# Pin toolchain homes to the REAL home before the cases go hermetic, or the
# fixture-1 `cargo test` loses its rustup default (source-built litmus trick).
export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"

fail() {
    echo "FAIL: $1" >&2
    shift
    for f in "$@"; do
        echo "----- $f -----" >&2
        cat "$f" >&2 || true
    done
    exit 1
}

case_env() {
    # $1 = case label. Fresh hermetic HOME/runtime/state per case.
    case_dir="$tmp/$1"
    mkdir -p "$case_dir/home" "$case_dir/runtime" "$case_dir/state"
    chmod 700 "$case_dir/runtime"
    export HOME="$case_dir/home"
    export XDG_RUNTIME_DIR="$case_dir/runtime"
    export LITMUS_PODMAN_STATE_DIR="$case_dir/state"
    export LITMUS_PODMAN_CALLS_FILE="$case_dir/podman-calls.log"
    : >"$LITMUS_PODMAN_CALLS_FILE"
    case_log="$case_dir/lane.log"
}

run_lane() {
    # The status lane exercises the shared-stack cleanup decision at entry
    # AND exit; rc is captured, asserted by each case.
    set +e
    timeout 300 "$BIN" --headless --init --debug --status-check >"$case_log" 2>&1
    lane_rc=$?
    set -e
}

tracked() {
    [[ -f "$LITMUS_PODMAN_STATE_DIR/containers/$1" ]]
}

# ── fixture 1: second-forge ensure reuses the running shared containers ─────
case_env fixture1
echo "[fixture 1] second-forge ensure id-stability (env-gated Rust test)"
(
    cd "$ROOT"
    cargo test -q -p tillandsias-headless --bin tillandsias \
        shared_stack_second_forge_ensure_reuses_running_containers -- --exact --nocapture
) >"$case_dir/cargo-test.log" 2>&1 ||
    fail "fixture 1: second-forge ensure re-ran or bounced a running shared container" \
        "$case_dir/cargo-test.log" "$LITMUS_PODMAN_CALLS_FILE"

# ── fixture 2a: exiting lane keeps the stack for a created (not running)
#    sibling lane container ───────────────────────────────────────────────────
case_env case2a
echo "[fixture 2a] created-state sibling blocks teardown"
podman create --name tillandsias-projB-forge mock-forge-image >/dev/null
run_lane
[[ "$lane_rc" -eq 0 ]] || fail "fixture 2a: status lane exited rc=$lane_rc" "$case_log"
grep -q "keeping shared stack alive; active lane container(s): .*tillandsias-projB-forge" "$case_log" ||
    fail "fixture 2a: cleanup did not report the created sibling lane" "$case_log"
if grep -q "no active lane containers" "$case_log"; then
    fail "fixture 2a: teardown fired despite a created sibling lane" "$case_log"
fi
tracked tillandsias-proxy ||
    fail "fixture 2a: shared proxy was torn down under a created sibling" "$case_log" "$LITMUS_PODMAN_CALLS_FILE"
tracked tillandsias-inference ||
    fail "fixture 2a: shared inference was torn down under a created sibling" "$case_log" "$LITMUS_PODMAN_CALLS_FILE"

# ── fixture 2b: exiting lane keeps the stack for a PRE-CREATE in-flight
#    launch (advisory flock marker only; no container exists yet) ────────────
case_env case2b
echo "[fixture 2b] launch-in-flight marker blocks teardown (pre-create window)"
lock_dir="$XDG_RUNTIME_DIR/tillandsias-locks"
mkdir -p "$lock_dir"
marker_file="$lock_dir/resource-launch-projB-424242.lock"
touch "$marker_file"
# Hold the same flock(2) the Rust side probes, from a separate process —
# exactly what a sibling `tillandsias` launch does across its pre-create
# window. flock(1) ships with util-linux.
command -v flock >/dev/null || fail "fixture 2b: flock(1) (util-linux) is required"
flock -x "$marker_file" -c 'sleep 240' &
flock_pid=$!
for _ in $(seq 1 50); do
    if ! flock -n -x "$marker_file" -c true 2>/dev/null; then
        break
    fi
    sleep 0.1
done
if flock -n -x "$marker_file" -c true 2>/dev/null; then
    fail "fixture 2b: background flock holder never acquired the marker"
fi
run_lane
[[ "$lane_rc" -eq 0 ]] || fail "fixture 2b: status lane exited rc=$lane_rc" "$case_log"
grep -q "keeping shared stack alive; launch in flight (pre-create window): launch-projB-424242" "$case_log" ||
    fail "fixture 2b: cleanup ignored the foreign launch-in-flight marker (slice-3 regression)" "$case_log"
if grep -q "no active lane containers" "$case_log"; then
    fail "fixture 2b: teardown fired despite an in-flight launch" "$case_log"
fi
tracked tillandsias-proxy ||
    fail "fixture 2b: shared proxy was torn down under an in-flight launch" "$case_log" "$LITMUS_PODMAN_CALLS_FILE"
tracked tillandsias-inference ||
    fail "fixture 2b: shared inference was torn down under an in-flight launch" "$case_log" "$LITMUS_PODMAN_CALLS_FILE"
kill "$flock_pid" 2>/dev/null || true
flock_pid=""

# ── fixture 2c: control — the LAST exit with no in-flight launch still
#    tears the stack down (leak side must not regress) ───────────────────────
case_env case2c
echo "[fixture 2c] last-forge exit still tears down (control)"
run_lane
[[ "$lane_rc" -eq 0 ]] || fail "fixture 2c: status lane exited rc=$lane_rc" "$case_log"
grep -q "no active lane containers; cleaning project + shared stack" "$case_log" ||
    fail "fixture 2c: last-exit teardown never fired" "$case_log"
if tracked tillandsias-proxy; then
    fail "fixture 2c: proxy survived the last-forge exit (teardown regressed)" "$case_log" "$LITMUS_PODMAN_CALLS_FILE"
fi
if tracked tillandsias-inference; then
    fail "fixture 2c: inference survived the last-forge exit (teardown regressed)" "$case_log" "$LITMUS_PODMAN_CALLS_FILE"
fi
grep -q "podman rm -f tillandsias-proxy" "$LITMUS_PODMAN_CALLS_FILE" ||
    fail "fixture 2c: shared teardown never issued rm for the proxy" "$LITMUS_PODMAN_CALLS_FILE"

echo "PASS: concurrent-forge shared-stack safety fixtures (order 443 slice 3)"
exit 0
