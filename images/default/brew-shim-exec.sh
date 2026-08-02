#!/usr/bin/env bash
# @trace spec:default-image
# tillandsias-brew-shim-exec — central runner behind the on-demand tool
# shims (plan order 294, operator-approved 2026-07-11).
#
# Usage (called by generated shims, not by hand):
#   tillandsias-brew-shim-exec <command> <formula> [args...]
#
# Contract:
# - HOMEBREW-CORE FORMULAE ONLY. Casks and third-party taps are structurally
#   rejected, and the command/formula pair must appear in the shipped allowlist.
# - INTEGRITY TODAY, PROVENANCE PENDING — stated precisely because this header
#   previously claimed Sigstore verification that could not run. What holds now:
#   our pinned homebrew-1.pem verifies a PS512 JWS over the formula index, whose
#   bottle_checksum is checked against the downloaded bytes. That is authenticated
#   integrity from a SINGLE publisher (Homebrew signs the index and builds the
#   bottle), so it defeats MITM, a hostile mirror and corruption — but it does NOT
#   establish which commit or workflow produced the bytes.
#   Sigstore verification is OFF because it requires a GitHub credential to FETCH
#   the bundle, and no GitHub token may exist in a forge (operator directive
#   2026-08-01). See brew_env() for the credential-free replacement.
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
    # ATTESTATION IS EXPLICITLY OFF, and this is a correction rather than a
    # relaxation. Declared rather than merely omitted so the state is auditable:
    # an absent variable would leave a reader guessing whether it was a decision
    # or an oversight.
    #
    # We used to set HOMEBREW_VERIFY_ATTESTATIONS=1 here. Homebrew's attestation
    # path calls `gh attestation verify`, which FETCHES the Sigstore bundle from
    # GitHub's API — and gh refuses any API call without a credential, so
    # attestation.rb raises GhAuthNeeded before gh is even spawned. Under the
    # operator's absolute directive (no GitHub token in a forge, at runtime or at
    # image build), that flag could never succeed. It was not protecting us; it
    # was guaranteeing that every on-demand install failed.
    #
    # WHAT WE STILL GET BY DEFAULT, and it is more than "a checksum": our own
    # pinned homebrew-1.pem (RSA-4096, inside our clone at the pinned tag)
    # verifies a PS512 JWS over the formula index, which carries the
    # bottle_checksum, which is checked against the downloaded bytes. That is
    # AUTHENTICATED INTEGRITY FROM A SINGLE PUBLISHER — it defeats MITM (including
    # a proxy holding our own CA), a hostile ghcr mirror, and corruption.
    #
    # WHAT IT IS NOT: provenance. Homebrew signs the index AND builds the bottle,
    # so one publisher sits on both ends; nothing here says which commit, workflow
    # or builder produced the bytes. Do not describe this as provenance.
    #
    # THE REPLACEMENT IS REAL AND NEEDS NO CREDENTIAL: ship the Sigstore bundle
    # and a pinned trusted root in the image, then verify here ourselves with
    # `gh attestation verify <bottle> --repo Homebrew/homebrew-core --bundle
    # <shipped> --custom-trusted-root <shipped-root>`. That returns 0 with no
    # token, no gh config, and even with --network=none, and gh is ALREADY in the
    # base image. Tracked by packet
    # own-the-attestation-fetch-so-lanes-need-no-github-identity.
    export HOMEBREW_NO_VERIFY_ATTESTATIONS=1
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
echo "tillandsias: installing '$FORMULA' in userspace via brew (signed formula index, checksum-verified bottle)..." >&2
# BOUND THE INSTALL, but not for the reason an earlier version of this comment
# gave — that reason was wrong and is corrected here rather than deleted, because
# the wrong number was quoted downstream.
#
# CORRECTION: the 1+3+9+27+81 = 121s ladder (ATTESTATION_MAX_RETRIES, verified at
# attestation.rb:200 and :269-277 of tag 4.5.8) only ever catches
# InvalidAttestationError. GhAuthNeeded is declared at :47 as a SIBLING class,
# never rescued by that block — so a missing-credential failure is IMMEDIATE, not
# 121 seconds. The 121s stall observed on 2026-08-01 came from a different
# situation entirely: a token WAS present and Sigstore egress was blocked, so the
# failure kept landing in the retried branch.
#
# The bound stays, because a network stall, a slow mirror, or a future retried
# failure can still hang an install, and a forge must degrade to "this tool is
# unavailable" rather than to "the lane appears dead" — which is exactly what
# took down the post-build e2e gate with FORGE_EXIT=125. Defence in depth against
# a class of failure, not against one incident.
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
        echo "tillandsias: brew install $FORMULA TIMED OUT after ${BREW_INSTALL_TIMEOUT}s (bounded on purpose — a stalled fetch can hang an install indefinitely)." >&2
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
