#!/usr/bin/env bash
# @trace spec:ci-release
#
# check-guard-asset-skew.sh — does the INSTALLED binary carry the assets the
# CHECKOUT's guards require? (order 783-6rik.)
#
# THE CLASS THIS DETECTS. A guard lives in the checkout and runs from it. The
# artifact that guard inspects is built from assets EMBEDDED IN THE INSTALLED
# BINARY. When a guard lands in the checkout before a release ships the asset
# it depends on, every host fails that guard for a reason no host can fix:
#
#   * check-credential-channel.sh demands an upstream-auth verdict ref;
#     only images/git/probe-upstream-auth.sh publishes one; the probe landed
#     2026-08-15 and the installed release is commit 0548ee1f2 (2026-08-14).
#     Three forge lanes blocked on it in one night.
#   * 791-swxt is the same shape from the other side: 755-qcxh's CA-key heal
#     lives in the binary, so hosts running the pre-fix release kept a
#     world-readable key for three days after the packet closed.
#
# Twice in one night is a class, not a coincidence, and the symptom is always
# misleading: the host reports a runtime failure (unpublished verdict, absent
# index, world-readable key) when the real fact is a VERSION SKEW between a
# checkout-side rule and a release-side asset.
#
# WHAT IT COMPARES. The checkout's images/ tree against the SAME tree
# materialized from the installed binary at
# $XDG_DATA_HOME/tillandsias/runtime/<version>/images/. Only files a guard
# actually depends on are listed — this is not a general diff, and it must not
# become one: images/ legitimately drifts ahead of the last release all the
# time, and flagging that would make the check noise.
#
# Output grammar (exactly one line):
#   ^(ok:guard-asset-skew:(none|no-runtime-root)|skew:guard-asset-missing:[a-z0-9,-]+)$
#
# Advisory by design: exit 0 always. A skew is a fact about release timing, not
# a defect in the tree being pushed, and blocking a push on it would punish the
# wrong change.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Assets that a CHECKOUT-SIDE GUARD depends on. Add an entry only when a guard
# actually reads the artifact built from it; the name is what gets reported.
#   <name>|<path under images/>
GUARD_ASSETS='upstream-auth-probe|git/probe-upstream-auth.sh'

_runtime_root() {
    local v
    v="$(tillandsias --version 2>/dev/null | sed 's/^Tillandsias v//' | tr -d '[:space:]')"
    [ -n "$v" ] || return 1
    printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/tillandsias/runtime/$v"
}

_scan() {
    local checkout="$1" runtime="$2" missing="" name rel
    while IFS='|' read -r name rel; do
        [ -n "$name" ] || continue
        # Only compare assets the CHECKOUT has. One the checkout lacks is not
        # a skew — it is simply not a rule yet.
        [ -f "$checkout/images/$rel" ] || continue
        if [ ! -f "$runtime/images/$rel" ]; then
            missing="${missing:+$missing,}$name"
        fi
    done <<EOF
$GUARD_ASSETS
EOF

    if [ -n "$missing" ]; then
        echo "skew:guard-asset-missing:$missing"
        {
            echo "The installed binary's embedded assets predate a guard in this checkout."
            echo "Affected: $missing"
            echo "This is a RELEASE-TIMING fact, not a defect in the working tree: the"
            echo "guard cannot pass on this host until a build/release carrying the asset"
            echo "is installed. Rebuilding containers does not help — the tray rebuilds"
            echo "them from these same embedded assets (order 783-6rik)."
        } >&2
        return 0
    fi
    echo "ok:guard-asset-skew:none"
    return 0
}

if [ "${1:-}" = "--selftest" ]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    fail=0
    mkdir -p "$tmp/checkout/images/git" "$tmp/runtime/images/git"

    # Both sides carry it -> no skew.
    : > "$tmp/checkout/images/git/probe-upstream-auth.sh"
    : > "$tmp/runtime/images/git/probe-upstream-auth.sh"
    out="$(_scan "$tmp/checkout" "$tmp/runtime" 2>/dev/null)"
    [ "$out" = "ok:guard-asset-skew:none" ] || { echo "SELFTEST-FAIL: matched pair reported skew ($out)"; fail=1; }

    # NEGATIVE CONTROL: checkout has it, runtime does not -> skew. This is the
    # live 2026-08-17 state and the whole reason the check exists.
    rm -f "$tmp/runtime/images/git/probe-upstream-auth.sh"
    out="$(_scan "$tmp/checkout" "$tmp/runtime" 2>/dev/null)"
    [ "$out" = "skew:guard-asset-missing:upstream-auth-probe" ] \
        || { echo "SELFTEST-FAIL: real skew not detected ($out)"; fail=1; }

    # The REVERSE is not a skew: an asset the checkout no longer carries is a
    # retired rule, not a stale host. Reporting it would invert the meaning.
    rm -f "$tmp/checkout/images/git/probe-upstream-auth.sh"
    : > "$tmp/runtime/images/git/probe-upstream-auth.sh"
    out="$(_scan "$tmp/checkout" "$tmp/runtime" 2>/dev/null)"
    [ "$out" = "ok:guard-asset-skew:none" ] \
        || { echo "SELFTEST-FAIL: a retired checkout asset was reported as skew ($out)"; fail=1; }

    [ "$fail" -eq 0 ] || { echo "selftest:guard-asset-skew:FAIL"; exit 1; }
    echo "selftest:guard-asset-skew:3 cases PASS"
    exit 0
fi

runtime="$(_runtime_root)" || { echo "ok:guard-asset-skew:no-runtime-root"; exit 0; }
[ -d "$runtime" ] || { echo "ok:guard-asset-skew:no-runtime-root"; exit 0; }
_scan "$ROOT" "$runtime"
