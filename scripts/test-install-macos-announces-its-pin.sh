#!/usr/bin/env bash
# test-install-macos-announces-its-pin.sh — ORDER 1280-58kq.
#
# install-macos.sh derives CHANNEL_BASE from $CHANNEL and then lets
# TILLANDSIAS_RELEASE_BASE override it. The announcement did not follow: the
# else-arm printed "channel: $CHANNEL" and "resolving latest release"
# unconditionally, so a pinned install logged a resolution path it never took.
# Measured on macneo: the v56.9.19.1 AND v56.9.19.2 curl-install smokes both
# opened "channel: stable" / "resolving latest release" while pinned to a base
# whose release GitHub reports isPrerelease=true — and /releases/latest/download
# cannot serve a prerelease at all. Both installs were CORRECT; only the lines
# lied, which is the 1260-2qgi family: a message that reads like a report of
# what happened, produced by something that did not observe it.
#
# WHY THIS RUNS THE RESOLUTION BLOCK AND NOT THE INSTALLER. install-macos.sh
# downloads, verifies, extracts to /Applications, and launches the tray. A
# fixture must not do any of that, so this extracts the resolution block's
# decision by sourcing the script with a harness that stops it at the point the
# decision is made. The block is short and its inputs are two environment
# variables; the alternative — a real install per arm — is not runnable in a
# gate and would make the guard something nobody runs.
#
# Arms:
#   1. PINNED: TILLANDSIAS_RELEASE_BASE set -> names the pin, and NEVER says
#      "resolving latest release".
#   2. UNPINNED (regression guard): unset -> today's exact two lines, so a real
#      operator sees no change. This arm is the reason the fix is safe.
#   3. MUTANT: with the pinned branch removed, arm 1 must FAIL — proving arm 1
#      tests the branch rather than passing for an unrelated reason.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/scripts/install-macos.sh"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

[[ -r "$SRC" ]] || { echo "could-not-run:no-installer:$SRC"; exit 3; }

# Extract the resolution block verbatim and drive it with a stub `say`, a stub
# `die`, and the two variables it reads. Nothing else from the installer runs.
run_block() { # $1 = script text to source, env comes from the caller
    local text="$1"
    bash -c '
        set -uo pipefail
        say() { printf "%s\n" "$*"; }
        die() { printf "die: %s\n" "$*"; exit 1; }
        REPO="8007342/tillandsias"
        CHANNEL="${CHANNEL:-stable}"
        case "$CHANNEL" in
            stable)   CHANNEL_BASE="https://github.com/${REPO}/releases/latest/download" ;;
            unstable) CHANNEL_BASE="https://github.com/${REPO}/releases/download/unstable" ;;
        esac
        RELEASE_BASE_LATEST="${TILLANDSIAS_RELEASE_BASE:-$CHANNEL_BASE}"
        eval "$1"
    ' _ "$text" 2>&1
}

# The block under test, lifted from the installer by anchor so the fixture
# cannot drift from the source without failing to find it.
BLOCK="$(awk '/^    BASE="\$RELEASE_BASE_LATEST"$/,/^fi$/' "$SRC" | sed '$d')"
[[ -n "$BLOCK" ]] || { echo "could-not-run:anchor-not-found — install-macos.sh resolution block changed shape"; exit 3; }

# ── ARM 1: pinned ────────────────────────────────────────────────────────
out="$(TILLANDSIAS_RELEASE_BASE="https://example.invalid/releases/download/v9.9.9.9" run_block "$BLOCK")"
if grep -q "channel: pinned https://example.invalid/releases/download/v9.9.9.9" <<<"$out"; then
    ok "ARM 1: a pinned base is announced as the pin, naming it"
else
    bad "ARM 1: pinned base not announced; got: $out"
fi
if grep -q "resolving latest release" <<<"$out"; then
    bad "ARM 1: still claims 'resolving latest release' under a pin — the defect"
else
    ok "ARM 1: does NOT claim 'resolving latest release' under a pin"
fi
if grep -q "channel: stable" <<<"$out"; then
    bad "ARM 1: still claims 'channel: stable' under a pin — the defect"
else
    ok "ARM 1: does NOT claim a channel it did not resolve"
fi

# ── ARM 2: unpinned, the regression guard ────────────────────────────────
out="$(unset TILLANDSIAS_RELEASE_BASE; run_block "$BLOCK")"
if grep -q "channel: stable" <<<"$out" && grep -q "resolving latest release" <<<"$out"; then
    ok "ARM 2 (regression guard): unpinned output is unchanged — a real operator sees no difference"
else
    bad "ARM 2: unpinned output changed; got: $out"
fi
if grep -q "pinned" <<<"$out"; then
    bad "ARM 2: announces a pin when nothing is pinned"
else
    ok "ARM 2: does not announce a pin when nothing is pinned"
fi

# ── ARM 3: MUTANT — remove the branch, arm 1 must fail ───────────────────
MUTANT="$(printf '%s\n' '    BASE="$RELEASE_BASE_LATEST"' '    say "channel: $CHANNEL"' '    say "resolving latest release"')"
out="$(TILLANDSIAS_RELEASE_BASE="https://example.invalid/releases/download/v9.9.9.9" run_block "$MUTANT")"
if grep -q "resolving latest release" <<<"$out" && ! grep -q "pinned" <<<"$out"; then
    ok "ARM 3 MUTANT: without the branch the pinned arm reproduces the defect — arm 1 has teeth"
else
    bad "ARM 3 MUTANT: the mutant did not reproduce the defect, so arm 1 proves nothing; got: $out"
fi

echo "---"
if (( fail )); then
    echo "FAIL: install-macos-announces-its-pin ${pass}/$((pass+fail)) (1280-58kq)"
    exit 1
fi
echo "PASS: install-macos-announces-its-pin ${pass}/${pass} (1280-58kq)"
