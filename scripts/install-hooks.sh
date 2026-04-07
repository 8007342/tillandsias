#!/usr/bin/env bash
# install-hooks.sh — Install OpenSpec pre-commit hook
# @trace spec:spec-traceability
#
# Idempotent: safe to run multiple times. If a pre-commit hook already
# exists and isn't ours, warns but does not overwrite.
#
# Usage: ./scripts/install-hooks.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_SOURCE="$REPO_ROOT/scripts/hooks/pre-commit-openspec.sh"
HOOK_TARGET="$REPO_ROOT/.git/hooks/pre-commit"

# For worktrees, .git may be a file pointing to the actual git dir
if [[ -f "$REPO_ROOT/.git" ]]; then
    GIT_DIR="$(grep '^gitdir:' "$REPO_ROOT/.git" | cut -d' ' -f2)"
    # Resolve relative path
    if [[ ! "$GIT_DIR" = /* ]]; then
        GIT_DIR="$REPO_ROOT/$GIT_DIR"
    fi
    HOOK_TARGET="$GIT_DIR/hooks/pre-commit"
fi

MARKER="# openspec-pre-commit-hook"

if [[ ! -f "$HOOK_SOURCE" ]]; then
    echo "error: $HOOK_SOURCE not found" >&2
    exit 1
fi

# Ensure hooks directory exists
mkdir -p "$(dirname "$HOOK_TARGET")"

if [[ -f "$HOOK_TARGET" ]]; then
    # Check if our hook is already installed
    if grep -qF "$MARKER" "$HOOK_TARGET" 2>/dev/null; then
        echo "OpenSpec pre-commit hook already installed — nothing to do."
        exit 0
    fi

    # Existing hook that isn't ours — append
    echo ""
    echo "Existing pre-commit hook found at: $HOOK_TARGET"
    echo "Appending OpenSpec checks..."
    echo "" >> "$HOOK_TARGET"
    echo "$MARKER" >> "$HOOK_TARGET"
    echo "bash \"$HOOK_SOURCE\"" >> "$HOOK_TARGET"
    echo "OpenSpec pre-commit hook appended to existing hook."
else
    # No existing hook — create one
    cat > "$HOOK_TARGET" <<HOOK
#!/usr/bin/env bash
$MARKER
bash "$HOOK_SOURCE"
HOOK
    chmod +x "$HOOK_TARGET"
    echo "OpenSpec pre-commit hook installed at: $HOOK_TARGET"
fi
