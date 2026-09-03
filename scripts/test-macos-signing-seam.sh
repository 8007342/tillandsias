#!/usr/bin/env bash
# @trace spec:macos-tray-build-and-release
#
# test-macos-signing-seam.sh — the macOS signing seam behaves in BOTH modes.
#
# Orders 739-6r6n lineage / 935-6fzk. build-macos-tray.sh signs ad-hoc by
# default and with a Developer ID when TILLANDSIAS_MACOS_SIGN_IDENTITY is set.
# The Developer-ID half cannot be exercised here — it needs a credential this
# host does not have — so this fixture pins the parts that DO NOT need one, and
# says plainly which part it cannot reach.
#
# WHAT IT PROTECTS. The release path must not change shape on the day a
# credential appears in someone's keychain, and the one silent failure in that
# path is `com.apple.security.get-task-allow`: it is required for local
# debugging, and NOTARIZATION REJECTS ANY BUILD CARRYING IT. A seam that forgot
# to strip it would sail through every local check and fail at Apple, days
# later, with the release already tagged.
#
# GRAMMAR — exactly one line:
#   ^(ok:macos-signing-seam:[0-9]+|violation:macos-signing-seam:.*)$
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/scripts/build-macos-tray.sh"
ENT="$ROOT/crates/tillandsias-macos-tray/assets/Tillandsias.entitlements"
fail=0
n=0
ok()  { n=$((n+1)); echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }

[ -f "$BUILD" ] || { echo "violation:macos-signing-seam:no-build-script"; exit 1; }
[ -f "$ENT" ]   || { echo "violation:macos-signing-seam:no-entitlements"; exit 1; }

# 1. Default is ad-hoc. A release that silently started requiring a credential
#    would break every contributor's build.
if grep -q 'SIGN_IDENTITY="${TILLANDSIAS_MACOS_SIGN_IDENTITY:--}"' "$BUILD"; then
    ok "unset identity defaults to ad-hoc"
else
    bad "the default signing identity is no longer ad-hoc"
fi

# 2. The hardened runtime is on in BOTH arms. Notarization requires it, and a
#    build that only sets it in the Developer-ID arm would differ between the
#    thing developers test and the thing users receive.
if [ "$(grep -c -- '--options runtime' "$BUILD")" -ge 2 ]; then
    ok "--options runtime present in both signing arms"
else
    bad "--options runtime is missing from an arm (notarization requires it)"
fi

# 3. --timestamp ONLY with a real identity: an ad-hoc signature cannot carry
#    one, so an unconditional flag would break the default build.
if grep -q -- '--timestamp' "$BUILD" \
   && ! grep -A2 'sign - ' "$BUILD" | grep -q -- '--timestamp'; then
    ok "--timestamp is scoped to the Developer ID arm"
else
    bad "--timestamp must be present for Developer ID and absent for ad-hoc"
fi

# 4. THE ONE THAT MATTERS, in two halves — and the second half exists because
#    the first is SELF-CERTIFYING. Running the derivation here proves PlistBuddy
#    can delete a key; it says nothing about whether the BUILD does it. Caught
#    by mutating the build to skip the strip and watching this fixture stay
#    green. So: assert the build performs the deletion, THEN assert the
#    derivation produces the right plist.
if grep -q 'Delete :com.apple.security.get-task-allow' "$BUILD"; then
    ok "the build script itself strips get-task-allow for release signing"
else
    bad "build-macos-tray.sh no longer strips get-task-allow — notarization would reject every release"
fi
tmp_ent="$(mktemp -t seam-ent).plist"
cp "$ENT" "$tmp_ent"
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$tmp_ent" 2>/dev/null || true
if /usr/libexec/PlistBuddy -c "Print :com.apple.security.get-task-allow" "$tmp_ent" >/dev/null 2>&1; then
    bad "get-task-allow SURVIVED the release derivation — notarization would reject this build"
else
    ok "release entitlements drop get-task-allow"
fi
if /usr/libexec/PlistBuddy -c "Print :com.apple.security.virtualization" "$tmp_ent" >/dev/null 2>&1; then
    ok "release entitlements KEEP com.apple.security.virtualization"
else
    bad "virtualization entitlement was lost — the VM would refuse to start"
fi
rm -f "$tmp_ent"

# 5. Stapling happens BEFORE the tarball. `stapler` cannot staple an archive,
#    so the reverse order ships an un-stapled app that works only while Apple's
#    notary service is reachable.
staple_line="$(grep -n 'stapler staple' "$BUILD" | head -1 | cut -d: -f1)"
tar_line="$(grep -n 'tar -czf' "$BUILD" | head -1 | cut -d: -f1)"
if [ -n "$staple_line" ] && [ -n "$tar_line" ] && [ "$staple_line" -lt "$tar_line" ]; then
    ok "stapling precedes packaging"
else
    bad "staple must run before the tarball is created (staple_line=$staple_line tar_line=$tar_line)"
fi

# 6. Notarization is gated on credentials, and says so when they are absent
#    rather than producing a signed-but-unnotarized release silently.
if grep -q 'TILLANDSIAS_NOTARY_KEY' "$BUILD" && grep -q 'notarize: SKIPPED' "$BUILD"; then
    ok "notarization is credential-gated and announces when it is skipped"
else
    bad "notarization must be gated and must say so when skipped"
fi

# 7. THE CONTAINER IS SIGNED TOO (order 935-6fzk). The .app was signed and
#    stapled while the DMG holding it shipped unsigned, and the DMG is what the
#    user downloads — Gatekeeper assesses the IMAGE before anyone reaches the
#    signed app inside.
DMG="$ROOT/scripts/build-macos-dmg.sh"
if [ -f "$DMG" ] && grep -q 'codesign --force --sign "$DMG_SIGN_IDENTITY"' "$DMG"; then
    ok "the DMG itself is signed, not just the app inside it"
else
    bad "build-macos-dmg.sh must sign the DMG container"
fi

# 8. Same credential gating as the tray script. Identity absent => the build is
#    byte-for-byte what it was; the release path must not change shape on the
#    day a credential appears in someone's keychain.
if grep -q 'codesign dmg: SKIPPED' "$DMG" && grep -q 'notarize dmg: SKIPPED' "$DMG"; then
    ok "DMG signing and notarization are gated and announce when skipped"
else
    bad "DMG signing/notarization must be gated and must say so when skipped"
fi

# 9. THE SHA IS TAKEN AFTER SIGNING. Both codesign and stapler rewrite the DMG
#    in place, so hashing first publishes a SHA256SUMS line describing a file
#    nobody ships — green everywhere, and wrong for every user who verifies it.
sign_line="$(grep -n 'codesign --force --sign "\$DMG_SIGN_IDENTITY"' "$DMG" | head -1 | cut -d: -f1)"
sha_line="$(grep -n '^DMG_SHA=' "$DMG" | head -1 | cut -d: -f1)"
if [ -n "$sign_line" ] && [ -n "$sha_line" ] && [ "$sign_line" -lt "$sha_line" ]; then
    ok "the DMG hash is computed after signing, not before"
else
    bad "DMG_SHA must be computed after signing (sign_line=$sign_line sha_line=$sha_line)"
fi

# NOT COVERED, said out loud: signing with a real Developer ID identity,
# notarytool submission and stapler both need a credential this host lacks.
# Their first real exercise is the day enrollment completes.
if [ "$fail" -ne 0 ]; then
    echo "violation:macos-signing-seam:see-failures-above"
    exit 1
fi
echo "ok:macos-signing-seam:$n"
