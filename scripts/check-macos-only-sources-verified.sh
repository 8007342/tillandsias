#!/usr/bin/env bash
# @trace spec:macos-native-tray, spec:methodology-accountability
#
# Order 739-6r6n. The macOS twin of the windows-only source verification gate.
#
# THE ASYMMETRY THIS CLOSES. `scripts/check-windows-only-sources-verified.sh`
# reports on every gate run, so the Windows blind spot stays visible. The macOS
# crate has the identical blind spot — 7 modules under
# `#[cfg(target_os = "macos")]` that a Linux or Windows build never parses,
# because the crate is fully cfg-gated and non-macOS hosts compile stubs — and
# NOTHING reported it. So the fleet had a loud warning for one platform and
# SILENCE for the other, and the silent one read as healthy. Of the two failure
# modes that is the worse one: the Windows gate at least named something a
# reader could go and check.
#
# WHY THIS FILE IS TWELVE LINES AND NOT FOUR HUNDRED. It is the same gate with
# four values swapped. The windows script already declared scope to be "a FIELD
# in one shared grammar, so a macOS writer reuses this vocabulary rather than
# minting `macos-sources-*` tokens" (738-3pft) — and a forked 450-line copy
# would have honoured that vocabulary while abandoning the reason for it. Two
# implementations drift the moment one is fixed, which is the same defect as two
# attestation formats, one layer down. The parameterisation was verified not to
# change the windows verdict: `stale:sources-drifted:windows-only:1:...` before
# and after, identical.
#
# Everything else — the shared attestation format, the blob-sha recomputation,
# the evidence gate that refuses a stamp with no transcript, the
# verified/drifted/never-verified vocabulary — is inherited, not re-stated.
set -euo pipefail
export ONLY_PLATFORM="macos"
export ONLY_CRATE="tillandsias-macos-tray"
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-windows-only-sources-verified.sh" "$@"
