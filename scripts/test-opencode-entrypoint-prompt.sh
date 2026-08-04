#!/usr/bin/env bash
# @trace spec:forge-opencode-onboarding
set -euo pipefail

# HERMETICITY. This script drives the entrypoint through several input
# combinations, each case setting exactly the variables it means to test. Any of
# those variables inherited from the AMBIENT environment silently changes a case
# it was not meant to touch — and the entrypoint is correct to honour them, so
# the failure looks like a product regression rather than a leaky test.
#
# That is not hypothetical: run inside a forge lane, which exports
# TILLANDSIAS_OPENCODE_PROMPT (and, under a structured-result run,
# TILLANDSIAS_AGENT_RESULT_FORMAT), TWO cases flipped and
# litmus:forge-opencode-onboarding-shape STEP 4 reported a defect that did not
# exist. Found 2026-08-04 by /smoke-curl-install-and-test-e2e on v0.4.260804.1.
#
# Clear them ONCE here rather than per-case: a per-case fix leaves the next case
# added below exposed to the same trap.
unset TILLANDSIAS_OPENCODE_PROMPT
unset TILLANDSIAS_AGENT_RESULT_FORMAT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ENTRYPOINT_UNDER_TEST="$TMP_DIR/entrypoint-forge-opencode.sh"
CALLS_FILE="$TMP_DIR/opencode.calls"
PROJECT_DIR="$TMP_DIR/project"
mkdir -p "$PROJECT_DIR"

sed "s|source /usr/local/lib/tillandsias/lib-common.sh|source \"$TMP_DIR/lib-common.sh\"|" \
    "$PROJECT_ROOT/images/default/entrypoint-forge-opencode.sh" > "$ENTRYPOINT_UNDER_TEST"
chmod +x "$ENTRYPOINT_UNDER_TEST"

cat > "$TMP_DIR/opencode-fake" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
    for arg in "$@"; do
        printf '[%s]' "$arg"
    done
    printf '\n'
} >> "${OPENCODE_CALLS_FILE:?}"
exit "${OPENCODE_FAKE_EXIT:-0}"
EOF
chmod +x "$TMP_DIR/opencode-fake"

cat > "$TMP_DIR/openspec-fake" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP_DIR/openspec-fake"

cat > "$TMP_DIR/lib-common.sh" <<EOF
OC_BIN="$TMP_DIR/opencode-fake"
OS_BIN="$TMP_DIR/openspec-fake"
PROJECT_DIR="$PROJECT_DIR"
trace_lifecycle() { :; }
populate_hot_paths() { :; }
clone_project_from_mirror() { :; }
require_opencode() { :; }
require_openspec() { :; }
apply_opencode_config_overlay() { :; }
prepare_opencode_vault_auth() { :; }
opencode_actual_auth_ok() { :; }
ensure_forge_prebuilt_tools() { :; }
ensure_forge_harnesses() { :; }
inject_startup_context() { :; }
curl() { return 1; }
export_ssh_env() { :; }
find_project_dir() { PROJECT_DIR="$PROJECT_DIR"; }
export_project_env() { :; }
configure_git_identity() { :; }
show_banner() { :; }
EOF

assert_call() {
    local expected="$1"
    local actual

    actual="$(cat "$CALLS_FILE")"
    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: expected OpenCode call "%s", got "%s"\n' "$expected" "$actual" >&2
        exit 1
    fi
}

rm -f "$CALLS_FILE"
OPENCODE_CALLS_FILE="$CALLS_FILE" \
TILLANDSIAS_OPENCODE_PROMPT="Use the /forge-continuous-enhancement skill" \
"$ENTRYPOINT_UNDER_TEST"
assert_call "[run][--auto][Use the /forge-continuous-enhancement skill]"

rm -f "$CALLS_FILE"
set +e
OPENCODE_CALLS_FILE="$CALLS_FILE" \
OPENCODE_FAKE_EXIT=37 \
TILLANDSIAS_OPENCODE_PROMPT="exit propagation probe" \
"$ENTRYPOINT_UNDER_TEST"
status=$?
set -e
if [[ "$status" -ne 37 ]]; then
    printf 'FAIL: expected prompted OpenCode run to propagate exit 37, got %s\n' "$status" >&2
    exit 1
fi
assert_call "[run][--auto][exit propagation probe]"

# Order 429: structured output is OPT-IN. Without the env var the lane must
# keep the human-facing formatted default; with it, --format json must be
# passed so a dispatcher can parse the run.
rm -f "$CALLS_FILE"
OPENCODE_CALLS_FILE="$CALLS_FILE" \
TILLANDSIAS_AGENT_RESULT_FORMAT=json \
TILLANDSIAS_OPENCODE_PROMPT="structured probe" \
"$ENTRYPOINT_UNDER_TEST"
assert_call "[run][--auto][--format][json][structured probe]"

# The "no prompt configured" case must CONTROL its inputs, not inherit them.
# The "no prompt configured" case. Depends on the script-level unset above; it
# is the most obviously exposed case, but NOT the only one — an ambient
# TILLANDSIAS_AGENT_RESULT_FORMAT also flipped an earlier case, which is why the
# sanitize is at the top rather than here.
rm -f "$CALLS_FILE"
OPENCODE_CALLS_FILE="$CALLS_FILE" "$ENTRYPOINT_UNDER_TEST"
assert_call ""

printf 'ok: opencode entrypoint prompt routing\n'
