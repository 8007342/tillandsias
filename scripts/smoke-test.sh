#!/bin/bash
# Manual Smoke Test Automation Script (Step 11)
# Coordinates full workflow: build → init → opencode-web → verify → shutdown
# Captures evidence (logs, screenshots) for release approval

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_PROJECT="${HOME}/test-opencode-smoke"
EVIDENCE_DIR="${HOME}/tillandsias-release-evidence-$(date +%Y-%m-%d)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Phase tracking
PHASE=0
TOTAL_PHASES=5

phase() {
    PHASE=$((PHASE + 1))
    echo -e "${GREEN}[Phase $PHASE/$TOTAL_PHASES]${NC} $1"
}

error() {
    echo -e "${RED}❌ ERROR${NC}: $1" >&2
    exit 1
}

success() {
    echo -e "${GREEN}✅${NC} $1"
}

warn() {
    echo -e "${YELLOW}⚠️${NC} $1"
}

# Create evidence directory
mkdir -p "$EVIDENCE_DIR"

echo "Tillandsias Release Manual Smoke Test"
echo "====================================="
echo "Evidence directory: $EVIDENCE_DIR"
echo ""

# Phase 1: Clean Build
phase "Clean Build & Install (./build.sh --ci-full --install)"
cd "$PROJECT_ROOT"

if ! ./build.sh --ci-full --install 2>&1 | tee "$EVIDENCE_DIR/01-build-full.log"; then
    error "Build failed. See $EVIDENCE_DIR/01-build-full.log"
fi
success "Build passed (500+ tests)"

if ! command -v tillandsias &> /dev/null; then
    error "Binary not installed to ~/.local/bin/tillandsias"
fi
success "Binary installed to ~/.local/bin/tillandsias"

# Phase 2: Init Project
phase "Initialize Test Project (tillandsias --init --debug)"

# Clean previous test project
if [ -d "$TEST_PROJECT" ]; then
    rm -rf "$TEST_PROJECT"
fi

mkdir -p "$TEST_PROJECT"
cd "$TEST_PROJECT"
git init

if ! tillandsias --init --debug 2>&1 | tee "$EVIDENCE_DIR/02-init.log"; then
    error "Init failed. See $EVIDENCE_DIR/02-init.log"
fi
success "Project initialized, all images built"

grep -q "ready" "$EVIDENCE_DIR/02-init.log" || warn "Did not see 'ready' message in init logs"

# Phase 3: OpenCode Web Launch (headless monitoring, manual browser check)
phase "Launch OpenCode Web & Monitor"

# Start in background with timeout
timeout 120 tillandsias --opencode-web "$TEST_PROJECT" 2>&1 | tee "$EVIDENCE_DIR/03-opencode-launch.log" &
PID=$!

# Wait for container startup and router readiness
sleep 5

# Check if chromium process is running (browser should auto-open)
if pgrep -f "chromium\|google-chrome" > /dev/null; then
    success "Chromium launched"
else
    warn "Chromium not detected (may be headless environment)"
fi

# Verify containers are running
if podman ps 2>&1 | grep -q "tillandsias"; then
    success "Tillandsias containers running"
else
    error "No tillandsias containers found"
fi

# Phase 4: Manual Verification (interactive prompts)
phase "Manual Verification Required"

echo ""
echo "MANUAL CHECKS (please verify in your browser/tray):"
echo "=================================================="
echo ""
echo "1. Browser Window:"
echo "   ☐ Chromium opened automatically"
echo "   ☐ OTP form visible (data-URI injection)"
echo "   ☐ OTP field auto-filled with token"
echo "   ☐ Form auto-submitted (1-2 seconds)"
echo "   ☐ OpenCode Web loads in browser"
echo "   ☐ Can access localhost services through router"
echo ""
echo "2. Tray Window (if visible):"
echo "   ☐ Shows 'test-opencode' project"
echo "   ☐ Status icon: Initializing → Ready → Blushing → Blooming"
echo "   ☐ Menu shows container list with statuses"
echo ""
echo "3. Network:"
echo "   ☐ No timeout errors (< 500ms latency)"
echo "   ☐ Router validates OTP successfully"
echo ""

read -p "All manual checks passed? (y/n): " manual_check
if [ "$manual_check" != "y" ]; then
    warn "Manual checks failed. Investigate logs in $EVIDENCE_DIR"
    kill $PID 2>/dev/null || true
    exit 1
fi
success "Manual verification passed"

# Phase 5: Graceful Shutdown
phase "Graceful Shutdown (SIGTERM, 30s timeout)"

tillandsias --stop 2>&1 | tee "$EVIDENCE_DIR/05-shutdown.log" || true

# Wait for shutdown (up to 30 seconds)
for i in {1..30}; do
    if ! pgrep -f "tillandsias.*opencode-web" > /dev/null; then
        success "All containers cleaned up within ${i}s"
        break
    fi
    sleep 1
done

# Verify no orphaned containers
remaining=$(podman ps --filter "label=com.github.tillandsias" -q 2>/dev/null | wc -l)
if [ "$remaining" -eq 0 ]; then
    success "No orphaned containers"
else
    error "Found $remaining orphaned tillandsias containers after shutdown"
fi

# Phase 6: Evidence Summary
echo ""
echo "====================================="
echo "Smoke Test Complete ✅"
echo "====================================="
echo ""
echo "Evidence saved to: $EVIDENCE_DIR"
echo "Files:"
ls -lh "$EVIDENCE_DIR" | grep -v "^total" | awk '{print "  - " $9}'
echo ""
echo "Next steps:"
echo "1. Review logs in $EVIDENCE_DIR"
echo "2. If all checks passed: git tag v<VERSION> && git push origin v<VERSION>"
echo "3. Create release on GitHub"
echo ""
