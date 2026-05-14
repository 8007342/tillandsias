#!/usr/bin/env bash
# install-hooks.sh — Install git hooks for OpenSpec workflow
# @trace spec:spec-traceability, spec:versioning
#
# Installs two git hooks:
#   1. pre-commit: OpenSpec trace warnings and spec-cheatsheet drift checks
#   2. pre-push: VERSION guard (prevents VERSION modifications on non-main branches)
#
# Idempotent: safe to run multiple times. If hooks already exist and aren't ours,
# warns but does not overwrite (appends to existing).
#
# Usage: ./scripts/install-hooks.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# For worktrees, .git may be a file pointing to the actual git dir
GIT_HOOKS_DIR="$REPO_ROOT/.git/hooks"
if [[ -f "$REPO_ROOT/.git" ]]; then
    GIT_DIR="$(grep '^gitdir:' "$REPO_ROOT/.git" | cut -d' ' -f2)"
    # Resolve relative path
    if [[ ! "$GIT_DIR" = /* ]]; then
        GIT_DIR="$REPO_ROOT/$GIT_DIR"
    fi
    GIT_HOOKS_DIR="$GIT_DIR/hooks"
fi

# Ensure hooks directory exists
mkdir -p "$GIT_HOOKS_DIR"

# --- Install pre-commit hook -----------------------------------------------

PRECOMMIT_SOURCE="$REPO_ROOT/scripts/hooks/pre-commit-openspec.sh"
PRECOMMIT_TARGET="$GIT_HOOKS_DIR/pre-commit"
PRECOMMIT_MARKER="# openspec-pre-commit-hook"

if [[ ! -f "$PRECOMMIT_SOURCE" ]]; then
    echo "error: $PRECOMMIT_SOURCE not found" >&2
    exit 1
fi

if [[ -f "$PRECOMMIT_TARGET" ]]; then
    if grep -qF "$PRECOMMIT_MARKER" "$PRECOMMIT_TARGET" 2>/dev/null; then
        echo "✓ OpenSpec pre-commit hook already installed"
    else
        echo "Existing pre-commit hook found — appending OpenSpec checks..."
        echo "" >> "$PRECOMMIT_TARGET"
        echo "$PRECOMMIT_MARKER" >> "$PRECOMMIT_TARGET"
        echo "bash \"$PRECOMMIT_SOURCE\"" >> "$PRECOMMIT_TARGET"
        echo "✓ OpenSpec pre-commit hook appended"
    fi
else
    cat > "$PRECOMMIT_TARGET" <<HOOK
#!/usr/bin/env bash
$PRECOMMIT_MARKER
bash "$PRECOMMIT_SOURCE"
HOOK
    chmod +x "$PRECOMMIT_TARGET"
    echo "✓ OpenSpec pre-commit hook installed"
fi

# --- Install pre-push hook -------------------------------------------------

PREPUSH_SOURCE="$REPO_ROOT/scripts/hooks/pre-push-version-guard.sh"
PREPUSH_TARGET="$GIT_HOOKS_DIR/pre-push"
PREPUSH_MARKER="# version-guard-hook"

if [[ ! -f "$PREPUSH_SOURCE" ]]; then
    echo "error: $PREPUSH_SOURCE not found" >&2
    exit 1
fi

if [[ -f "$PREPUSH_TARGET" ]]; then
    if grep -qF "$PREPUSH_MARKER" "$PREPUSH_TARGET" 2>/dev/null; then
        echo "✓ VERSION guard pre-push hook already installed"
    else
        echo "Existing pre-push hook found — appending VERSION guard..."
        echo "" >> "$PREPUSH_TARGET"
        echo "$PREPUSH_MARKER" >> "$PREPUSH_TARGET"
        echo "bash \"$PREPUSH_SOURCE\" \"\$@\"" >> "$PREPUSH_TARGET"
        echo "✓ VERSION guard pre-push hook appended"
    fi
else
    cat > "$PREPUSH_TARGET" <<HOOK
#!/usr/bin/env bash
$PREPUSH_MARKER
bash "$PREPUSH_SOURCE" "\$@"
HOOK
    chmod +x "$PREPUSH_TARGET"
    echo "✓ VERSION guard pre-push hook installed"
fi

# --- Install post-commit hook -----------------------------------------------
# @trace gap:OBS-008

POSTCOMMIT_SOURCE="$REPO_ROOT/scripts/hooks/post-commit-dashboard-refresh.sh"
POSTCOMMIT_TARGET="$GIT_HOOKS_DIR/post-commit"
POSTCOMMIT_MARKER="# dashboard-refresh-hook"

if [[ ! -f "$POSTCOMMIT_SOURCE" ]]; then
    echo "error: $POSTCOMMIT_SOURCE not found" >&2
    exit 1
fi

if [[ -f "$POSTCOMMIT_TARGET" ]]; then
    if grep -qF "$POSTCOMMIT_MARKER" "$POSTCOMMIT_TARGET" 2>/dev/null; then
        echo "✓ Dashboard refresh post-commit hook already installed"
    else
        echo "Existing post-commit hook found — appending dashboard refresh..."
        echo "" >> "$POSTCOMMIT_TARGET"
        echo "$POSTCOMMIT_MARKER" >> "$POSTCOMMIT_TARGET"
        echo "bash \"$POSTCOMMIT_SOURCE\"" >> "$POSTCOMMIT_TARGET"
        echo "✓ Dashboard refresh post-commit hook appended"
    fi
else
    cat > "$POSTCOMMIT_TARGET" <<HOOK
#!/usr/bin/env bash
$POSTCOMMIT_MARKER
bash "$POSTCOMMIT_SOURCE"
HOOK
    chmod +x "$POSTCOMMIT_TARGET"
    echo "✓ Dashboard refresh post-commit hook installed"
fi

echo ""
echo "All git hooks installed successfully."
