#!/usr/bin/env bash
# @trace spec:forge-opencode-onboarding
set -euo pipefail

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

rm -f "$CALLS_FILE"
OPENCODE_CALLS_FILE="$CALLS_FILE" "$ENTRYPOINT_UNDER_TEST"
assert_call ""

printf 'ok: opencode entrypoint prompt routing\n'
