## Why

The release-pipeline and cosign-signing changes were archived with incomplete verification tasks. The implementation is done but has never been tested against a real CI run. These 9 tasks require pushing a tag, observing the GitHub Actions workflow, and manually verifying artifacts — they cannot be completed without a configured CI environment with signing secrets.

## What Changes

- Verify the GitHub Actions release workflow produces correct artifacts for all 3 platforms
- Verify Cosign keyless signing produces valid signatures and transparency log entries
- Verify checksums and artifact naming conventions
- No code changes — this is a verification-only change

## Capabilities

### New Capabilities
<!-- None — verification only -->

### Modified Capabilities
- `ci-release`: Verification that the existing pipeline works correctly
- `binary-signing`: Verification that Cosign signing and verification work end-to-end

## Impact

- Requires GitHub repo secrets: `TAURI_SIGNING_PRIVATE_KEY`, `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`
- Requires pushing a release candidate tag to trigger the workflow
- May reveal issues that need fixes in the workflow files
