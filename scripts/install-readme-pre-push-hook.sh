#!/bin/bash
# @trace spec:project-bootstrap-readme

set -euo pipefail

# Find project root
PROJECT_ROOT="${1:-.}"
while [ "$PROJECT_ROOT" != "/" ]; do
  if [ -d "$PROJECT_ROOT/.git" ]; then
    break
  fi
  PROJECT_ROOT="$(dirname "$PROJECT_ROOT")"
done

if [ ! -d "$PROJECT_ROOT/.git" ]; then
  PROJECT_ROOT="$1"
fi

HOOK_PATH="$PROJECT_ROOT/.git/hooks/pre-push"
HOOK_DIR="$(dirname "$HOOK_PATH")"

mkdir -p "$HOOK_DIR"

# Define the hook content
HOOK_CONTENT=$(cat <<'HOOK_EOF'
#!/bin/bash
# @trace spec:project-bootstrap-readme
# Pre-push hook: best-effort regenerate README.md before each push.
# Never blocks the push (any non-zero is swallowed).

set +e

# Try to regenerate README.md
if command -v regenerate-readme.sh >/dev/null 2>&1; then
    regenerate-readme.sh "$PWD" 2>/dev/null

    # If README changed, commit it
    if ! git diff --cached --quiet README.md 2>/dev/null; then
        git add README.md 2>/dev/null
        git commit --no-verify -m "chore(readme): regenerate at $(date -u -Iminutes)" 2>/dev/null || true
    fi
elif [ -x /usr/local/bin/regenerate-readme.sh ]; then
    /usr/local/bin/regenerate-readme.sh "$PWD" 2>/dev/null

    if ! git diff --cached --quiet README.md 2>/dev/null; then
        git add README.md 2>/dev/null
        git commit --no-verify -m "chore(readme): regenerate at $(date -u -Iminutes)" 2>/dev/null || true
    fi
fi

# Always allow push to proceed
exit 0
HOOK_EOF
)

# Check if hook already exists with same content
if [ -f "$HOOK_PATH" ]; then
    EXISTING=$(cat "$HOOK_PATH" 2>/dev/null || echo "")
    if [ "$EXISTING" = "$HOOK_CONTENT" ]; then
        # Hook already installed and matches, no-op
        exit 0
    fi
fi

# Write or update hook
echo "$HOOK_CONTENT" > "$HOOK_PATH"
chmod +x "$HOOK_PATH"

echo "[install-readme-pre-push-hook] Installed at $HOOK_PATH"
exit 0
