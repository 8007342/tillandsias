#!/usr/bin/env bash
# @trace spec:dev-build
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

write_all_pass_fixture() {
    cat > "$TMP_DIR/pre.log" <<'EOF'
running pre-build litmus
PASS:  129
FAIL:  0
note: previous implementation counted this explanatory FAIL token incorrectly
EOF

    cat > "$TMP_DIR/post.log" <<'EOF'
running post-build litmus
PASS:  6
FAIL:  0
EOF

    cat > "$TMP_DIR/runtime.log" <<'EOF'
running runtime litmus
PASS:  5
FAIL:  0
EOF
}

write_failure_fixture() {
    cat > "$TMP_DIR/pre.log" <<'EOF'
PASS:  129
FAIL:  0
EOF

    cat > "$TMP_DIR/post.log" <<'EOF'
PASS:  5
FAIL:  1
EOF
}

assert_counts() {
    local expected="$1"
    local files="$2"
    local actual

    actual="$("$SCRIPT_DIR/generate-evidence-bundle.sh" "--litmus-count-fixture=$files")"
    if [[ "$actual" != "$expected" ]]; then
        printf 'FAIL: expected "%s", got "%s"\n' "$expected" "$actual" >&2
        exit 1
    fi
}

write_all_pass_fixture
assert_counts "passed=140 failed=0" "$TMP_DIR/pre.log:$TMP_DIR/post.log:$TMP_DIR/runtime.log"

write_failure_fixture
assert_counts "passed=134 failed=1" "$TMP_DIR/pre.log:$TMP_DIR/post.log"

printf 'ok: evidence bundle litmus summary parser\n'
