#!/usr/bin/env bash
# @trace spec:ci-release, plan 1324-ujvb
#
# test-ensure-cosign.sh — POSITIVE CONTROL FIRST, then the negatives.
#
# The row's decision names a positive-control fixture as a requirement, and the
# reason is the one this fleet keeps relearning: a verifier that answers
# "Verified OK" tells you nothing until you have watched it answer anything
# else. `cosign:verified:1/1` from a check that cannot fail is the same artifact
# as a green test over dead code — true about itself, false about the world.
#
# So arm 1 proves the happy path works on real artifacts, and arms 2-4 prove the
# verification REJECTS a tampered blob, a wrong signing identity and a wrong
# OIDC issuer. If any negative arm passes verification, this suite fails loudly:
# that is the state where every downstream `cosign:verified` becomes worthless
# while continuing to read as proof.
#
# NETWORK. These arms need the sigstore release and the transparency log. A
# host that cannot reach them reports `skip:no-network` and exits 0 — the same
# could-not-run/failed distinction the script itself draws. An unreachable
# network is not a failed verification.
#
# Usage: scripts/test-ensure-cosign.sh

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

PIN="scripts/cosign-release.pin"
pass=0; fail=0
ok()  { echo "  PASS  $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $*"; fail=$((fail + 1)); }

_pin() { grep -E "^$1=" "$PIN" 2>/dev/null | head -1 | sed "s/^$1=//"; }

VERSION="$(_pin version)"
CHECKSUMS="$(_pin checksums)"
CHECKSUMS_SHA256="$(_pin checksums_sha256)"
CERT_ID="$(_pin certificate_identity)"
CERT_ISSUER="$(_pin certificate_oidc_issuer)"

echo "ensure-cosign fixture — pin $VERSION / manifest $CHECKSUMS"

# arm 0: the pin parses and every field is non-empty. A pin with a missing
# field would make every later arm test nothing while looking busy.
echo "arm 0 — the pin is complete"
missing=""
for v in VERSION CHECKSUMS CHECKSUMS_SHA256 CERT_ID CERT_ISSUER; do
    [ -n "${!v}" ] || missing="$missing $v"
done
if [ -z "$missing" ]; then ok "all five pin fields present"; else bad "pin fields empty:$missing"; fi

# arm 0b: the pin is read KEY-ANCHORED, not as a substring. This file's own
# header discusses `sha256=` in prose; if the reader matched anywhere on the
# line it would pick up a comment and compare against nonsense.
echo "arm 0b — pin reader is key-anchored"
if [ "${#CHECKSUMS_SHA256}" -eq 64 ] && [[ "$CHECKSUMS_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    ok "sha256 parsed as a 64-hex digest, not a comment"
else
    bad "checksums_sha256 did not parse as a digest: '$CHECKSUMS_SHA256'"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-ensure-cosign.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT
BASE="https://github.com/sigstore/cosign/releases/download/$VERSION"

echo "arm 1 — POSITIVE CONTROL: the real thing verifies"
_os="$(uname -s | tr '[:upper:]' '[:lower:]')"; _arch="$(uname -m | tr '[:upper:]' '[:lower:]')"
ASSET="$(grep -E "^platform=${_os}/${_arch}=" "$PIN" | head -1 | sed 's/^platform=[^=]*=//')"
if [ -z "$ASSET" ]; then
    echo "skip:unsupported-platform:${_os}/${_arch}"
    echo "  (this host has no pinned asset; verification was NOT exercised)"
    exit 0
fi
if ! curl --proto '=https' --tlsv1.2 -sSfL "$BASE/$ASSET" -o "$TMP/c" 2>/dev/null \
   || ! curl --proto '=https' --tlsv1.2 -sSfL "$BASE/$ASSET.sigstore.json" -o "$TMP/c.json" 2>/dev/null; then
    echo "skip:no-network"
    echo "  (the release could not be fetched; verification was NOT exercised —"
    echo "   this is a could-not-run, never a pass)"
    exit 0
fi

curl --proto '=https' --tlsv1.2 -sSfL "$BASE/$CHECKSUMS" -o "$TMP/sums" 2>/dev/null
sums_got="$(sha256sum "$TMP/sums" | awk '{print $1}')"
if [ "$sums_got" = "$CHECKSUMS_SHA256" ]; then
    ok "signed manifest matches the pinned checksums_sha256"
else
    bad "pin is stale or the manifest is wrong: expected $CHECKSUMS_SHA256, got $sums_got"
    echo "ensure-cosign fixture: $pass passed, $fail failed"
    exit 1
fi
# Anchored at end-of-line: `cosign-linux-amd64` must not be satisfied by the
# `-kms` or `.sbom.json` row that contains it as a prefix.
want="$(grep -E "[[:space:]]${ASSET}\$" "$TMP/sums" | head -1 | awk '{print $1}')"
got="$(sha256sum "$TMP/c" | awk '{print $1}')"
if [ -n "$want" ] && [ "$got" = "$want" ]; then
    ok "$ASSET matches the hash the signed manifest gives it"
else
    bad "manifest/download disagree for $ASSET: manifest='$want' got='$got'"
    echo "ensure-cosign fixture: $pass passed, $fail failed"
    exit 1
fi

chmod +x "$TMP/c"
if "$TMP/c" verify-blob "$TMP/c" --bundle "$TMP/c.json" \
        --certificate-identity "$CERT_ID" \
        --certificate-oidc-issuer "$CERT_ISSUER" >/dev/null 2>&1; then
    ok "cosign verifies its OWN release against sigstore"
else
    bad "self-verification failed — the pin's identity/issuer may be wrong"
fi

# ── NEGATIVE CONTROLS. Each must be REJECTED. ───────────────────────────────
# A pass here is not a cosmetic defect: it means the verification is inert and
# every `cosign:verified:1/1` downstream is decorative.

echo "arm 2 — a TAMPERED blob must be rejected"
cp "$TMP/c" "$TMP/tampered" && printf 'X' >> "$TMP/tampered"
if "$TMP/c" verify-blob "$TMP/tampered" --bundle "$TMP/c.json" \
        --certificate-identity "$CERT_ID" \
        --certificate-oidc-issuer "$CERT_ISSUER" >/dev/null 2>&1; then
    bad "a MUTATED binary verified — the signature check is inert"
else
    ok "mutated binary rejected"
fi

echo "arm 3 — a WRONG signing identity must be rejected"
if "$TMP/c" verify-blob "$TMP/c" --bundle "$TMP/c.json" \
        --certificate-identity "attacker@example.com" \
        --certificate-oidc-issuer "$CERT_ISSUER" >/dev/null 2>&1; then
    bad "an arbitrary identity verified — identity is not being checked"
else
    ok "wrong certificate identity rejected"
fi

echo "arm 4 — a WRONG OIDC issuer must be rejected"
if "$TMP/c" verify-blob "$TMP/c" --bundle "$TMP/c.json" \
        --certificate-identity "$CERT_ID" \
        --certificate-oidc-issuer "https://token.actions.githubusercontent.com" >/dev/null 2>&1; then
    bad "an arbitrary issuer verified — issuer is not being checked"
else
    ok "wrong OIDC issuer rejected"
fi

# arm 5: the script's own grammar. A caller greps these strings; a typo makes
# every consumer silently take the wrong branch.
# ── ARM 4b: THE DIVERGENCE ARM lenovinha asked for. ────────────────────────
# A host that is not this one must report could-not-run, NEVER
# verification-failed. Both halves are exercised, because fixing only the first
# leaves the original complaint intact:
#
#   (a) a platform with NO pinned row               -> unsupported-platform
#   (b) a platform WITH a row whose binary will not
#       execute here (simulating macOS on Linux)    -> binary-not-executable-here
#
# (b) is the one that matters and is the one that survived the first fix. The
# original defect was never "we pick the wrong asset" -- it was "a host that
# cannot RUN cosign reports that cosign's SIGNATURE is bad", and asset selection
# alone does not close that. Reproduced by simulation rather than argued closed.
echo "arm 4b — a non-native host reports could-not-run, never verification-failed"
mkdir -p "$TMP/shim"
printf '#!/usr/bin/env bash\ncase "${1:-}" in -s) echo SunOS ;; -m) echo sparc64 ;; *) echo SunOS ;; esac\n' > "$TMP/shim/uname"
chmod +x "$TMP/shim/uname"
out="$(PATH="$TMP/shim:$PATH" TILLANDSIAS_COSIGN_CACHE="$TMP/ca" bash scripts/ensure-cosign.sh 2>/dev/null)"
rc=$?
case "$out" in
    cosign:could-not-run:unsupported-platform:*)
        ok "unpinned platform -> $out (rc=$rc)" ;;
    cosign:verification-failed:*)
        bad "AN UNPINNED PLATFORM REPORTED A VERIFICATION FAILURE: $out" ;;
    *)  bad "unexpected verdict for an unpinned platform: '$out'" ;;
esac
[ "$rc" -eq 0 ] && ok "could-not-run exits 0 (it is not a failure)" || bad "could-not-run exited $rc"

printf '#!/usr/bin/env bash\ncase "${1:-}" in -s) echo Darwin ;; -m) echo arm64 ;; *) echo Darwin ;; esac\n' > "$TMP/shim/uname"
out="$(PATH="$TMP/shim:$PATH" TILLANDSIAS_COSIGN_CACHE="$TMP/cb" bash scripts/ensure-cosign.sh 2>/dev/null)"
rc=$?
if [ "$_os" = "darwin" ]; then
    # On a real Mac this shim describes the truth, so the run should SUCCEED.
    case "$out" in
        cosign:verified:1/1|cosign:already-verified:1/1) ok "native darwin verifies ($out)" ;;
        *) bad "darwin host did not verify: '$out'" ;;
    esac
else
    case "$out" in
        cosign:could-not-run:binary-not-executable-here)
            ok "a darwin binary on a non-darwin host -> could-not-run, not verification-failed" ;;
        cosign:verification-failed:*)
            bad "THE ORIGINAL DEFECT: a host that cannot RUN cosign reported a signature failure ($out)" ;;
        *)  bad "unexpected verdict for a cross-platform binary: '$out'" ;;
    esac
    [ "$rc" -eq 0 ] && ok "could-not-run exits 0" || bad "could-not-run exited $rc"
fi

echo "arm 5 — ensure-cosign.sh emits exactly one grammar line"
out="$(TILLANDSIAS_COSIGN_CACHE="$TMP/cache" bash scripts/ensure-cosign.sh 2>/dev/null)"
lines="$(printf '%s\n' "$out" | grep -c .)"
if [ "$lines" -eq 1 ]; then ok "one line on stdout"; else bad "expected 1 stdout line, got $lines: $out"; fi
case "$out" in
    cosign:verified:1/1|cosign:already-verified:1/1|cosign:could-not-run:*)
        ok "verdict matches the pinned grammar ($out)" ;;
    *)  bad "verdict outside the grammar: '$out'" ;;
esac

echo "ensure-cosign fixture: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ok:ensure-cosign-fixture:$pass"
exit 0
