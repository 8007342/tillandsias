#!/usr/bin/env bash
# @trace spec:ci-release, plan 1324-ujvb
#
# ensure-cosign.sh — put a VERIFIED cosign in the builder toolbox, idempotently.
#
# THE DECISION THIS IMPLEMENTS (operator, relayed by macuahuitl 2026-09-22):
# toolbox-first — cosign arrives through the same ensure-style idempotent
# scripts everything already runs, transparent to callers. SIGNING STAYS IN THE
# CLOUD RELEASE: local builds are not durable, only the verified cloud artifacts
# are, so the local lane VERIFIES and never signs. Nothing here signs anything.
#
# THE BOOTSTRAP PROBLEM, stated plainly because the whole design is its answer.
# cosign verifies our release assets. Who verifies cosign? A tool fetched from
# "whatever the release API answers today" can authenticate everything we ship
# while being, itself, unauthenticated — the row's defect one level up. The
# first link is the only one that cannot be checked by the tool it bootstraps,
# so it is checked twice, by two different means, in this order:
#
#   1. SHA256 against scripts/cosign-release.pin, BEFORE the binary is executed.
#      This is what permits execution at all. A downloaded binary that fails the
#      pin is never run, never installed, and never chmod +x.
#   2. The now-executable cosign verifies ITS OWN release signature against
#      sigstore's certificate and transparency log, with the identity and issuer
#      from the pin.
#
# Step 2 looks circular and is not: step 1 already fixed WHICH bytes are
# running, so step 2 asks a different question — whether sigstore actually
# published those bytes, i.e. whether the pin itself is honest. Drop step 1 and
# you execute an unverified binary to ask it whether it should have been
# executed. Drop step 2 and you trust whoever wrote the pin line.
#
# GRAMMAR (one line on stdout, nothing else):
#   cosign:verified:1/1                 installed and both checks passed
#   cosign:already-verified:1/1         already present at the pinned version
#   cosign:could-not-run:<reason>       this host cannot complete the install
#
# `could-not-run` is a REPORT, never a failure of the caller, and it is the
# honest answer rather than a degraded pass — the smoke's §1 keeps its
# unverified headline on such a host (criterion 4's recorded floor-host skip).
# This script therefore exits 0 for `could-not-run` and non-zero ONLY when a
# verification it actually performed FAILED, which is a different event and
# must never be confused with an absent tool. A host with no toolbox and a host
# whose cosign failed its signature check are not the same finding.
#
# Usage:  scripts/ensure-cosign.sh [--print-path]

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="$REPO_ROOT/scripts/cosign-release.pin"
TOOLBOX_NAME="${TILLANDSIAS_BUILDER_TOOLBOX:-tillandsias-builder}"
CACHE_DIR="${TILLANDSIAS_COSIGN_CACHE:-$HOME/.cache/tillandsias/cosign}"
print_path=0
[ "${1:-}" = "--print-path" ] && print_path=1

_emit() { echo "$1"; }

# Read one `key=value` from the pin. Anchored at the key, never a substring —
# the census lesson (1329-m8dk): a comment mentioning `sha256=` must not be read
# as the value.
_pin() {
    local key="$1" line
    line="$(grep -E "^${key}=" "$PIN" 2>/dev/null | head -1)" || return 1
    [ -n "$line" ] || return 1
    printf '%s' "${line#*=}"
}

[ -f "$PIN" ] || { _emit "cosign:could-not-run:no-pin-file"; exit 0; }

VERSION="$(_pin version)"
CHECKSUMS="$(_pin checksums)"
CHECKSUMS_SHA256="$(_pin checksums_sha256)"
CERT_ID="$(_pin certificate_identity)"
CERT_ISSUER="$(_pin certificate_oidc_issuer)"

for v in VERSION CHECKSUMS CHECKSUMS_SHA256 CERT_ID CERT_ISSUER; do
    [ -n "${!v}" ] || { _emit "cosign:could-not-run:pin-field-missing:${v,,}"; exit 0; }
done

# ── WHICH ASSET IS THIS HOST'S? ────────────────────────────────────────────
# ORDER 1324-ujvb, lenovinha's review. This script used to hardcode
# cosign-linux-amd64 and select nothing. On a Mac the download succeeded, the
# hash matched, chmod succeeded, and the self-verification EXECUTED A LINUX
# BINARY -- so the host reported `cosign:verification-failed:sigstore`, exit 1.
# A host that cannot RUN the file reported that its SIGNATURE was bad: the worst
# misreport the design can produce, and the exact could-not-run/failed
# conflation this script polices everywhere else. Reasoned from the code path by
# a reviewer who could not run macOS, and right.
#
# An unsupported platform is a could-not-run and exits 0. Nothing was
# downloaded, run or checked, so there is no verification result to report.
_os="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
_arch="$(uname -m 2>/dev/null | tr '[:upper:]' '[:lower:]')"
ASSET="$(grep -E "^platform=${_os}/${_arch}=" "$PIN" 2>/dev/null | head -1 | sed 's/^platform=[^=]*=//')"
if [ -z "$ASSET" ]; then
    echo "[ensure-cosign] no pinned cosign asset for ${_os}/${_arch}." >&2
    echo "  This is NOT a verification failure -- nothing was downloaded, run or" >&2
    echo "  checked. The host simply has no entry in scripts/cosign-release.pin." >&2
    echo "  REMEDY: add a 'platform=${_os}/${_arch}=<asset>' line to the pin if" >&2
    echo "  sigstore publishes a build for it, and re-run." >&2
    _emit "cosign:could-not-run:unsupported-platform:${_os}/${_arch}"
    exit 0
fi

INSTALLED="$CACHE_DIR/cosign-$VERSION"

# ── Already present? Re-ask the BINARY, never a marker file. ─────────────────
# ensure_toolbox.sh's contract names this explicitly: "The gate is a PROBE, not
# a marker file … so a half-built toolbox is repaired rather than certified."
# A stamp saying we installed cosign is not evidence that cosign is there now.
if [ -x "$INSTALLED" ]; then
    if "$INSTALLED" version 2>/dev/null | grep -qF "$VERSION"; then
        [ "$print_path" -eq 1 ] && echo "$INSTALLED" >&2
        _emit "cosign:already-verified:1/1"
        exit 0
    fi
    # Present but not the pinned version: fall through and re-install. Never
    # trust a binary whose version disagrees with the anchor it was verified
    # against.
fi

command -v curl >/dev/null 2>&1 || { _emit "cosign:could-not-run:no-curl"; exit 0; }
command -v sha256sum >/dev/null 2>&1 || { _emit "cosign:could-not-run:no-sha256sum"; exit 0; }

mkdir -p "$CACHE_DIR" 2>/dev/null || { _emit "cosign:could-not-run:cache-dir-unwritable"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ensure-cosign.XXXXXX")" || {
    _emit "cosign:could-not-run:no-tmpdir"; exit 0; }
trap 'rm -rf "$TMP"' EXIT

BASE="https://github.com/sigstore/cosign/releases/download/$VERSION"

_fetch() { curl --proto '=https' --tlsv1.2 -sSfL "$BASE/$1" -o "$TMP/$1" 2>"$TMP/.err"; }

# THE MANIFEST IS THE ANCHOR, and it is why there is one pinned hash instead of
# one per platform. `cosign_checksums.txt` names every binary's hash; pinning
# four binary hashes would fix the platform bug and create a rot surface, four
# values to re-derive per release, any of which can go quietly stale. One
# manifest hash covers every platform and every future one -- and the manifest
# is itself signed, so it is verified below rather than merely trusted.
if ! _fetch "$CHECKSUMS" || ! _fetch "$CHECKSUMS.sigstore.json"; then
    _emit "cosign:could-not-run:download-failed:$CHECKSUMS"
    sed 's/^/  /' "$TMP/.err" >&2 2>/dev/null
    exit 0
fi

# ── CHECK 1a: the manifest is the one the pin names. ────────────────────────
got="$(sha256sum "$TMP/$CHECKSUMS" | awk '{print $1}')"
if [ "$got" != "$CHECKSUMS_SHA256" ]; then
    echo "[ensure-cosign] SHA256 MISMATCH on $CHECKSUMS against scripts/cosign-release.pin" >&2
    echo "  expected: $CHECKSUMS_SHA256" >&2
    echo "  got:      $got" >&2
    echo "  Nothing was executed. Either the pin is stale (roll it forward" >&2
    echo "  deliberately, re-reading the certificate identity) or this is not" >&2
    echo "  the release the pin names." >&2
    _emit "cosign:verification-failed:sha256"
    exit 1
fi

# ── CHECK 1b: this platform's binary matches the hash the manifest gives. ───
# Anchored on the asset name at END OF LINE, so `cosign-linux-amd64` cannot be
# satisfied by the `cosign-linux-amd64-kms` or `.sbom.json` rows that contain it
# as a prefix. The substring-vs-anchored mistake has cost this fleet three
# separate defects in a day.
want="$(grep -E "[[:space:]]${ASSET}\$" "$TMP/$CHECKSUMS" | head -1 | awk '{print $1}')"
if [ -z "$want" ]; then
    _emit "cosign:could-not-run:asset-not-in-manifest:$ASSET"
    exit 0
fi

if ! _fetch "$ASSET" || ! _fetch "$ASSET.sigstore.json"; then
    _emit "cosign:could-not-run:download-failed:$ASSET"
    sed 's/^/  /' "$TMP/.err" >&2 2>/dev/null
    exit 0
fi

got="$(sha256sum "$TMP/$ASSET" | awk '{print $1}')"
if [ "$got" != "$want" ]; then
    echo "[ensure-cosign] SHA256 MISMATCH on $ASSET against the SIGNED manifest" >&2
    echo "  expected: $want" >&2
    echo "  got:      $got" >&2
    echo "  The manifest matched its pin, so the release index is trusted and" >&2
    echo "  THIS DOWNLOAD disagrees with it. The binary was NOT executed." >&2
    _emit "cosign:verification-failed:sha256"
    exit 1
fi

chmod +x "$TMP/$ASSET"

# ── CAN THIS HOST EVEN RUN IT? ─────────────────────────────────────────────
# ORDER 1324-ujvb, second half of lenovinha's finding -- surfaced by simulating
# their scenario rather than arguing it was fixed. Selecting the asset by uname
# stops us downloading the WRONG binary; it does NOT stop "this binary will not
# execute here" from being reported as a SIGNATURE failure, which was the whole
# complaint. Every remaining way execution can fail lands in the same place:
# a pin whose platform row points at the wrong asset, a $TMPDIR mounted noexec,
# a missing dynamic loader, a kernel that refuses the format.
#
# So ask the cheapest possible question first -- `cosign version` touches no
# network, no keyring and no artifact -- and let a failure here be a
# could-not-run. After this line, a verify-blob failure means cosign RAN and
# said no, which is the only thing `verification-failed` should ever mean.
if ! "$TMP/$ASSET" version >/dev/null 2>&1; then
    echo "[ensure-cosign] the downloaded cosign does not execute on this host." >&2
    echo "  asset: $ASSET  (selected for ${_os}/${_arch})" >&2
    echo "  Its SHA256 matched the signed manifest, so the download is intact --" >&2
    echo "  this host cannot RUN it. That is NOT a verification failure and must" >&2
    echo "  never be reported as one." >&2
    echo "  LIKELY CAUSES: a wrong platform row in scripts/cosign-release.pin," >&2
    echo "  a noexec \$TMPDIR, or a missing loader." >&2
    _emit "cosign:could-not-run:binary-not-executable-here"
    exit 0
fi

# ── CHECK 2: does sigstore say it published these bytes? ─────────────────────
# Verify BOTH the binary's own bundle AND the manifest that named its hash.
# Check 1b trusted the manifest; leaving the manifest unverified would rest that
# trust on the pin alone, which is the single-source failure this design exists
# to avoid.
if ! "$TMP/$ASSET" verify-blob "$TMP/$ASSET" \
        --bundle "$TMP/$ASSET.sigstore.json" \
        --certificate-identity "$CERT_ID" \
        --certificate-oidc-issuer "$CERT_ISSUER" >"$TMP/.verify" 2>&1 \
   || ! "$TMP/$ASSET" verify-blob "$TMP/$CHECKSUMS" \
        --bundle "$TMP/$CHECKSUMS.sigstore.json" \
        --certificate-identity "$CERT_ID" \
        --certificate-oidc-issuer "$CERT_ISSUER" >>"$TMP/.verify" 2>&1; then
    echo "[ensure-cosign] SIGSTORE SELF-VERIFICATION FAILED" >&2
    echo "  The bytes matched the pin, so the pin and the download agree — and" >&2
    echo "  sigstore does not confirm them. That is the case the hash alone" >&2
    echo "  cannot see, and it is why both checks exist." >&2
    sed 's/^/  /' "$TMP/.verify" >&2 2>/dev/null
    _emit "cosign:verification-failed:sigstore"
    exit 1
fi

# Install only now, after BOTH checks. Move into place atomically so a
# concurrent reader never sees a half-written binary at the final path.
mv -f "$TMP/$ASSET" "$INSTALLED" 2>/dev/null || {
    _emit "cosign:could-not-run:install-failed"; exit 0; }

# Make it reachable inside the toolbox when there is one. The cache dir lives
# under $HOME, which toolbox shares with the host, so an installed binary is
# already visible there — this only checks that, and never fails the run over
# a toolbox that is absent by design (macOS, WSL, mutable hosts).
if command -v toolbox >/dev/null 2>&1 \
   && toolbox list 2>/dev/null | grep -q "$TOOLBOX_NAME"; then
    if ! toolbox run --container "$TOOLBOX_NAME" "$INSTALLED" version >/dev/null 2>&1; then
        echo "[ensure-cosign] installed and verified on the host, but not runnable inside $TOOLBOX_NAME." >&2
        echo "  The host copy is good; toolbox-lane callers should invoke it by path." >&2
    fi
fi

[ "$print_path" -eq 1 ] && echo "$INSTALLED" >&2
_emit "cosign:verified:1/1"
exit 0
