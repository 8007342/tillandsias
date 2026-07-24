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

# --- Test 4: new branch push with legacy archive content should succeed ---
# This tests the diff-base fix (order 462): a new branch that inherits frozen
# legacy archive files with invalid YAML should not be rejected, because the
# hook diffs against the parent ref instead of validating the whole tree.
BARE4="$TMPDIR_WORK/test-mirror4.git"
WORK3="$TMPDIR_WORK/worktree3"
git init --bare "$BARE4" 2>/dev/null
git -C "$BARE4" config core.hooksPath "$BARE4/hooks"
mkdir -p "$BARE4/hooks"
cp "$HOOK_SRC" "$BARE4/hooks/pre-receive"
cp "$PROJECT_ROOT/images/git/relay-refs.sh" "$BARE4/hooks/tillandsias-relay-refs"
chmod +x "$BARE4/hooks/pre-receive" "$BARE4/hooks/tillandsias-relay-refs"

git init "$WORK3" 2>/dev/null
git -C "$WORK3" config core.hooksPath ""
git -C "$WORK3" remote add origin "$BARE4"
mkdir -p "$WORK3/plan" "$WORK3/openspec/changes/archive/2026-03-22-legacy"

# Seed the parent branch with valid YAML
cat > "$WORK3/plan/index.yaml" <<'VALID'
plan:
  version: v1
  name: test-parent
VALID
git -C "$WORK3" add -A && git -C "$WORK3" commit -m "seed parent" --quiet 2>/dev/null
git -C "$WORK3" push origin HEAD:main 2>/dev/null

# Add a broken legacy archive file to the parent (simulating frozen legacy content)
cat > "$WORK3/openspec/changes/archive/2026-03-22-legacy/.openspec.yaml" <<'BROKEN'
openspec:
  broken: [[[
BROKEN
git -C "$WORK3" add -A && git -C "$WORK3" commit -m "add broken legacy archive" --quiet 2>/dev/null
git -C "$WORK3" push origin HEAD:main 2>/dev/null

# Create a new branch that only changes plan/index.yaml (valid YAML)
git -C "$WORK3" checkout -b feature/new-branch 2>/dev/null
cat > "$WORK3/plan/index.yaml" <<'VALID'
plan:
  version: v1
  name: test-new-branch
VALID
git -C "$WORK3" add -A && git -C "$WORK3" commit -m "new branch change" --quiet 2>/dev/null

if ! git -C "$WORK3" push origin feature/new-branch 2>/dev/null; then
    echo "FAIL: new branch push with valid changes was rejected (diff-base should have excluded legacy archive)"
    exit 1
fi
echo "PASS: new branch push with valid changes succeeded (legacy archive excluded via diff-base)"

echo "ALL TESTS PASSED"
