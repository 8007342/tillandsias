#!/usr/bin/env bash
# @trace spec:git-mirror-service
# Litmus: pre-receive hook rejects invalid YAML in ledger files.
# Creates a temp bare repo with the hook, pushes broken plan/*.yaml,
# and asserts non-zero receive. Then pushes valid YAML and asserts success.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
HOOK_SRC="$PROJECT_ROOT/images/git/pre-receive-hook.sh"

TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# Build the production YAML validator and expose it on PATH for the hook.
cargo build --quiet --manifest-path "$PROJECT_ROOT/Cargo.toml" -p tillandsias-policy
BIN_DIR="$TMPDIR_WORK/bin"
mkdir -p "$BIN_DIR"
ln -s "$PROJECT_ROOT/target/debug/tillandsias-policy" "$BIN_DIR/tillandsias-policy"
export PATH="$BIN_DIR:$PATH"

BARE="$TMPDIR_WORK/test-mirror.git"
WORK="$TMPDIR_WORK/worktree"

git init --bare "$BARE" 2>/dev/null
git -C "$BARE" config core.hooksPath "$BARE/hooks"
mkdir -p "$BARE/hooks"
cp "$HOOK_SRC" "$BARE/hooks/pre-receive"
cp "$PROJECT_ROOT/images/git/relay-refs.sh" "$BARE/hooks/tillandsias-relay-refs"
chmod +x "$BARE/hooks/pre-receive"
chmod +x "$BARE/hooks/tillandsias-relay-refs"

git init "$WORK" 2>/dev/null
git -C "$WORK" config core.hooksPath ""
git -C "$WORK" remote add origin "$BARE"

# --- Test 1: push invalid YAML should be rejected ---
mkdir -p "$WORK/plan"
cat > "$WORK/plan/index.yaml" <<'BROKEN'
plan:
  version: v1
  broken yaml: [[[
BROKEN

git -C "$WORK" add -A
git -C "$WORK" commit -m "test: broken yaml" --quiet 2>/dev/null

if git -C "$WORK" push origin HEAD:main 2>/dev/null; then
    echo "FAIL: push with invalid YAML was accepted (should have been rejected)"
    exit 1
fi
echo "PASS: push with invalid YAML was correctly rejected"

# --- Test 2: push valid YAML should be accepted ---
cat > "$WORK/plan/index.yaml" <<'VALID'
plan:
  version: v1
  name: test
VALID

git -C "$WORK" add -A
git -C "$WORK" commit -m "test: valid yaml" --quiet 2>/dev/null

if ! git -C "$WORK" push origin HEAD:main 2>/dev/null; then
    echo "FAIL: push with valid YAML was rejected (should have been accepted)"
    exit 1
fi
echo "PASS: push with valid YAML was accepted"

# --- Test 3: multi-ref push — first ref valid, second ref has broken YAML ---
# This specifically tests the subshell variable-loss fix (order 316).
# The inner while loop must NOT run in a pipe subshell, or REJECTED=1
# from a later file is lost before the outer loop checks it.
WORK2="$TMPDIR_WORK/worktree2"
git init "$WORK2" 2>/dev/null
git -C "$WORK2" remote add origin "$BARE"
mkdir -p "$WORK2/plan"

# First commit: valid YAML
cat > "$WORK2/plan/index.yaml" <<'VALID'
plan:
  version: v1
  name: test
VALID
git -C "$WORK2" add -A && git -C "$WORK2" commit -m "valid" --quiet 2>/dev/null
git -C "$WORK2" push origin HEAD:refs/heads/valid-branch 2>/dev/null

# Second commit: broken YAML on a different branch
git -C "$WORK2" checkout -b broken-branch 2>/dev/null
cat > "$WORK2/plan/index.yaml" <<'BROKEN'
plan:
  version: v1
  broken yaml: [[[
BROKEN
git -C "$WORK2" add -A && git -C "$WORK2" commit -m "broken" --quiet 2>/dev/null

# Push both refs — the hook sees valid-branch first, broken-branch second
# Without the fix, REJECTED=1 from broken-branch is lost in the pipe subshell
if git -C "$WORK2" push origin valid-branch broken-branch 2>/dev/null; then
    echo "FAIL: multi-ref push with broken YAML was accepted"
    exit 1
fi
echo "PASS: multi-ref push with broken YAML was correctly rejected"

echo "ALL TESTS PASSED"
