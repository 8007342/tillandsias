#!/usr/bin/env bash
# @trace gap:OBS-008
# Test that post-commit hook infrastructure is correctly installed and functional

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[TEST] Verifying post-commit hook files exist..."

# Check post-commit hook script exists
if [[ ! -f "$REPO_ROOT/scripts/hooks/post-commit-dashboard-refresh.sh" ]]; then
    echo "✗ post-commit hook script not found"
    exit 1
fi
echo "✓ post-commit hook script exists"

# Check install script was updated
if ! grep -q "post-commit-dashboard-refresh.sh" "$REPO_ROOT/scripts/install-hooks.sh"; then
    echo "✗ install-hooks.sh not updated with post-commit hook"
    exit 1
fi
echo "✓ install-hooks.sh contains post-commit hook setup"

# Check hook is executable
if [[ ! -x "$REPO_ROOT/scripts/hooks/post-commit-dashboard-refresh.sh" ]]; then
    echo "✗ post-commit hook script is not executable"
    exit 1
fi
echo "✓ post-commit hook script is executable"

# Check dashboard script has OBS-008 annotation
if ! grep -q "gap:OBS-008" "$REPO_ROOT/scripts/update-convergence-dashboard.sh"; then
    echo "✗ dashboard script missing gap:OBS-008 annotation"
    exit 1
fi
echo "✓ dashboard script has gap:OBS-008 annotation"

# Verify actual installed hook in the repo
if [[ -f "$REPO_ROOT/.git/hooks/post-commit" ]]; then
    if grep -q "post-commit-dashboard-refresh.sh" "$REPO_ROOT/.git/hooks/post-commit"; then
        echo "✓ post-commit hook properly installed in .git/hooks"
    else
        echo "✗ installed post-commit hook missing reference to refresh script"
        exit 1
    fi
else
    echo "✗ post-commit hook not installed in .git/hooks"
    exit 1
fi

# Verify hook is executable
if [[ ! -x "$REPO_ROOT/.git/hooks/post-commit" ]]; then
    echo "✗ installed post-commit hook is not executable"
    exit 1
fi
echo "✓ installed post-commit hook is executable"

# Verify dashboard file has refresh metadata
if ! grep -q "Last regenerated:" "$REPO_ROOT/docs/convergence/centicolon-dashboard.md"; then
    echo "✗ dashboard file missing refresh timestamp metadata"
    exit 1
fi
echo "✓ dashboard file has refresh timestamp metadata"

# Verify dashboard has OBS-008 annotation
if ! grep -q "gap:OBS-008" "$REPO_ROOT/docs/convergence/centicolon-dashboard.md"; then
    echo "✗ dashboard file missing gap:OBS-008 annotation"
    exit 1
fi
echo "✓ dashboard file has gap:OBS-008 annotation"

# Verify refresh policy mentions auto-detection
if ! grep -q "Committing changes to.*TRACES.md.*triggers an automatic" "$REPO_ROOT/docs/convergence/centicolon-dashboard.md"; then
    echo "✗ dashboard refresh policy doesn't mention TRACES.md auto-detection"
    exit 1
fi
echo "✓ dashboard refresh policy documents auto-detection"

echo ""
echo "[TEST] All infrastructure tests passed!"
