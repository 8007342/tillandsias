#!/usr/bin/env bash
# @trace spec:default-image
# tillandsias-brew-shim-exec — central runner behind the on-demand tool
# shims (plan order 294, operator-approved 2026-07-11).
#
# Usage (called by generated shims, not by hand):
#   tillandsias-brew-shim-exec <command> <formula> [args...]
#
# Contract:
# - VERIFIABLE PACKAGES ONLY: homebrew-core formulae with Sigstore build
#   provenance, verified at install (HOMEBREW_VERIFY_ATTESTATIONS=1).
#   Casks and third-party taps are structurally rejected.
# - First use installs the tool in userspace (Homebrew-on-Linux under
#   /home/linuxbrew/.linuxbrew), then execs the real binary transparently.
# - With TILLANDSIAS_BREW_AUTOINSTALL=0 the shim instead prints the
#   distro-style hint: install this tool in userspace with `brew install X`.
set -uo pipefail

CMD="${1:-}"
FORMULA="${2:-}"
shift 2 2>/dev/null || { echo "usage: tillandsias-brew-shim-exec <command> <formula> [args...]" >&2; exit 2; }

BREW_PREFIX="${TILLANDSIAS_BREW_PREFIX:-/home/linuxbrew/.linuxbrew}"
# Pinned Homebrew release tag: deliberate updates only (image package-source
# policy — no floating pipe-to-shell installer).
BREW_PIN_TAG="${TILLANDSIAS_BREW_PIN_TAG:-4.5.8}"
ALLOWLIST="${TILLANDSIAS_BREW_ALLOWLIST:-/usr/local/lib/tillandsias/brew-tools-allowlist.txt}"

hint_and_exit() {
    echo "tillandsias: '$CMD' is not installed." >&2
    echo "Install it in userspace with: brew install $FORMULA" >&2
    exit 127
}

# Formulae-only guard: no taps (name with /), no casks, no path tricks.
case "$FORMULA" in
    */*|*..*|-*|"" ) echo "tillandsias: refusing non-core or malformed formula '$FORMULA' (verifiable homebrew-core formulae only)" >&2; exit 2 ;;
esac

# The pair must come from the shipped allowlist — a shim forged for an
# unlisted tool gets refused here, not silently installed.
if ! grep -Eq "^${CMD} ${FORMULA}([[:space:]]|\$)" "$ALLOWLIST" 2>/dev/null; then
    echo "tillandsias: '$CMD -> $FORMULA' is not in the on-demand tool allowlist ($ALLOWLIST)" >&2
    exit 2
fi

brew_env() {
    export PATH="$BREW_PREFIX/bin:$BREW_PREFIX/sbin:$PATH"
    export HOMEBREW_VERIFY_ATTESTATIONS=1
    export HOMEBREW_NO_ANALYTICS=1
    export HOMEBREW_NO_AUTO_UPDATE=1
    export HOMEBREW_NO_ENV_HINTS=1
    export HOMEBREW_CACHE="${TILLANDSIAS_PROJECT_CACHE:-$HOME/.cache}/brew-cache"
}

# Already installed (e.g. by a parallel shim)? exec it directly.
if [ -x "$BREW_PREFIX/bin/$CMD" ]; then
    brew_env
    exec "$BREW_PREFIX/bin/$CMD" "$@"
fi

[ "${TILLANDSIAS_BREW_AUTOINSTALL:-1}" = "0" ] && hint_and_exit

# Lazy Homebrew bootstrap: pinned-tag clone into the standard prefix
# (bottles are only prebuilt for this exact prefix). Fail-soft to the hint.
# A recent failed bootstrap (typically dead enclave egress) is remembered
# for 10 minutes so successive shim hits don't re-attempt the clone and
# re-print the same failure every shell init (order 299 noise finding).
FAIL_STAMP="${TILLANDSIAS_PROJECT_CACHE:-$HOME/.cache}/brew-bootstrap-fail-stamp"
if [ ! -x "$BREW_PREFIX/bin/brew" ]; then
    if [ -f "$FAIL_STAMP" ]; then
        now="$(date +%s)"; last="$(cat "$FAIL_STAMP" 2>/dev/null || echo 0)"
        case "$last" in *[!0-9]*|"") last=0 ;; esac
        if [ $((now - last)) -lt 600 ]; then
            echo "tillandsias: Homebrew bootstrap failed recently (network/proxy?); backing off." >&2
            hint_and_exit
        fi
    fi
    echo "tillandsias: bootstrapping userspace Homebrew ($BREW_PIN_TAG) for on-demand tools..." >&2
    mkdir -p "$BREW_PREFIX" 2>/dev/null
    if ! git clone --quiet --depth 1 --branch "$BREW_PIN_TAG" \
        https://github.com/Homebrew/brew "$BREW_PREFIX" 2>&1 | tail -2 >&2; then
        echo "tillandsias: Homebrew bootstrap failed (network/proxy?)." >&2
        date +%s > "$FAIL_STAMP" 2>/dev/null || true
        hint_and_exit
    fi
    rm -f "$FAIL_STAMP" 2>/dev/null || true
fi

brew_env
echo "tillandsias: installing '$FORMULA' in userspace via brew (attested bottle)..." >&2
# BOUND THE INSTALL. Homebrew's attestation path retries 5 times with an
# exponential backoff of 1+3+9+27+81 = 121 SECONDS PER FORMULA, and exposes no
# knob to shorten it. On 2026-08-01 that stalled forge startup past the
# liveness probe's budget and failed the post-build e2e gate with
# FORGE_EXIT=125 "dead_crashed" — a tool install taking the whole lane down.
#
# The specific cause then was egress (Sigstore was not allowlisted, fixed in
# images/proxy/allowlist.txt), but this bound is deliberately INDEPENDENT of
# that: any future attestation failure produces the same 121s ladder, and a
# forge must degrade to "this tool is unavailable" rather than to "the lane
# appears dead". Defence in depth, not a substitute for the fix.
#
# `timeout` returns 124 on expiry; hint_and_exit already tells the agent how to
# proceed without the tool.
BREW_INSTALL_TIMEOUT="${TILLANDSIAS_BREW_INSTALL_TIMEOUT:-150}"
if command -v timeout >/dev/null 2>&1; then
    set -- timeout "$BREW_INSTALL_TIMEOUT" "$BREW_PREFIX/bin/brew" install --formula "$FORMULA"
else
    set -- "$BREW_PREFIX/bin/brew" install --formula "$FORMULA"
fi
if ! "$@" >&2; then
    rc=$?
    if [ "$rc" = 124 ]; then
        echo "tillandsias: brew install $FORMULA TIMED OUT after ${BREW_INSTALL_TIMEOUT}s (bounded on purpose — attestation retries alone cost 121s)." >&2
    else
        echo "tillandsias: brew install $FORMULA failed (attestation verification is REQUIRED and may be the cause — that is by design)." >&2
    fi
    hint_and_exit
fi

# Re-resolve strictly inside the brew prefix so we never re-enter the shim.
if [ -x "$BREW_PREFIX/bin/$CMD" ]; then
    exec "$BREW_PREFIX/bin/$CMD" "$@"
fi
echo "tillandsias: '$FORMULA' installed but did not provide '$CMD' in $BREW_PREFIX/bin — allowlist mapping bug, please file it." >&2
exit 127
