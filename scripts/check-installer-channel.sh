#!/usr/bin/env bash
# @trace spec:ci-release
#
# check-installer-channel.sh — resolve the release base URL an installer WOULD
# use, without installing anything.
#
# Order 621-2re2. The litmus that guards channel selection used to grep for a
# literal default expression in the installers. That pinned an expression, not a
# property: introducing the unstable channel changed the expression while every
# property the check existed to protect still held, so the guard failed for the
# wrong reason. A grep cannot tell those two cases apart. This can — it executes
# the installer's own channel-resolution prologue and reports the answer.
#
# Usage:
#   scripts/check-installer-channel.sh <installer-path> [channel]
#
# Environment passthrough: TILLANDSIAS_RELEASE_BASE still overrides everything
# (the curl-install smoke uses it to pin one exact release), so this reports the
# same precedence a real run would apply.
#
# Grammar — exactly one line on stdout:
#   ^(base:https://\S+|refused:(no-installer|unknown-channel|no-base-resolved):.*)$
# Exit 0 on `base:`, non-zero on any `refused:`.

set -uo pipefail

INSTALLER="${1:-}"
CHANNEL_ARG="${2:-}"

if [ -z "$INSTALLER" ] || [ ! -f "$INSTALLER" ]; then
    echo "refused:no-installer:${INSTALLER:-<empty>}"
    exit 1
fi

# The prologue is everything from the REPO assignment through the line that
# assigns the resolved base. Both installers are written so this range is
# side-effect free: it defines variables and helper functions, parses "$@"
# (empty here), and performs no I/O.
PROLOGUE="$(sed -n '/^REPO=/,/^RELEASE_BASE[A-Z_]*=/p' "$INSTALLER")"
if [ -z "$PROLOGUE" ]; then
    echo "refused:no-base-resolved:${INSTALLER} (no REPO=..RELEASE_BASE= range)"
    exit 1
fi

if [ -n "$CHANNEL_ARG" ]; then
    export TILLANDSIAS_CHANNEL="$CHANNEL_ARG"
else
    unset TILLANDSIAS_CHANNEL
fi

# `set --` clears positional args so the installers' flag loops see none.
# install-macos.sh's prologue defines its own say/die; install.sh's uses printf
# directly. Both are self-contained.
BASE="$(bash -c 'set --; '"$PROLOGUE"'
printf "%s\n" "${RELEASE_BASE:-${RELEASE_BASE_LATEST:-}}"' 2>/dev/null)"

case "$BASE" in
    https://*)
        echo "base:${BASE}"
        ;;
    *)
        echo "refused:unknown-channel:${INSTALLER} channel=${CHANNEL_ARG:-<default>}"
        exit 1
        ;;
esac
