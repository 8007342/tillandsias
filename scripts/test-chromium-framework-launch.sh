#!/usr/bin/env bash
# Test harness for chromium-framework-launch.sh probe behavior (order 612-nvf3)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCHER="$REPO_ROOT/images/chromium/chromium-framework-launch.sh"

if [[ ! -x "$LAUNCHER" ]]; then
    echo "FAIL: Launcher not executable or missing: $LAUNCHER" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-chromium-launch.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

# 1. Accepted-but-unadvertised wrapper fixture (Fedora 44 shape)
WRAPPER_FEDORA="$TMP_DIR/bin1/chromium"
mkdir -p "$TMP_DIR/bin1"
cat << 'EOF' > "$WRAPPER_FEDORA"
#!/usr/bin/env bash
if [[ "$*" == *"--help"* ]]; then
    echo "Usage: chromium [OPTIONS]"
    echo "  --version  Print version"
    exit 0
fi
if [[ "$*" == *"--version"* ]]; then
    echo "Chromium 150.0.0.0 Fedora"
    exit 0
fi
# Record execution args
echo "EXEC_ARGS: $*" > "$TMP_DIR/fedora_exec.log"
exit 0
EOF
chmod 0755 "$WRAPPER_FEDORA"

# Test Fedora wrapper shape
PATH="$TMP_DIR/bin1:$PATH" TMP_DIR="$TMP_DIR" bash "$LAUNCHER" --custom-flag >/dev/null 2>&1 || true

if [[ ! -f "$TMP_DIR/fedora_exec.log" ]]; then
    echo "FAIL: Fedora-shape wrapper was not executed" >&2
    exit 1
fi

if ! grep -q -- "--no-sandbox" "$TMP_DIR/fedora_exec.log"; then
    echo "FAIL: Fedora-shape wrapper expected --no-sandbox in final argv, got: $(cat "$TMP_DIR/fedora_exec.log")" >&2
    exit 1
fi

# 2. Rejecting wrapper fixture (wrapper that rejects --no-sandbox)
WRAPPER_REJECT="$TMP_DIR/bin2/chromium"
mkdir -p "$TMP_DIR/bin2"
cat << 'EOF' > "$WRAPPER_REJECT"
#!/usr/bin/env bash
if [[ "$*" == *"--no-sandbox"* ]]; then
    echo "chromium: unknown option --no-sandbox" >&2
    exit 1
fi
if [[ "$*" == *"--version"* ]]; then
    echo "Chromium Strict 150.0.0.0"
    exit 0
fi
# Record execution args
echo "EXEC_ARGS: $*" > "$TMP_DIR/reject_exec.log"
exit 0
EOF
chmod 0755 "$WRAPPER_REJECT"

# Test rejecting wrapper shape
PATH="$TMP_DIR/bin2:$PATH" TMP_DIR="$TMP_DIR" bash "$LAUNCHER" --custom-flag >/dev/null 2>&1 || true

if [[ ! -f "$TMP_DIR/reject_exec.log" ]]; then
    echo "FAIL: Rejecting wrapper was not executed" >&2
    exit 1
fi

if grep -q -- "--no-sandbox" "$TMP_DIR/reject_exec.log"; then
    echo "FAIL: Rejecting wrapper expected --no-sandbox to be omitted, got: $(cat "$TMP_DIR/reject_exec.log")" >&2
    exit 1
fi

echo "ok: chromium-framework-launch probe behavior verified (order 612-nvf3)"
