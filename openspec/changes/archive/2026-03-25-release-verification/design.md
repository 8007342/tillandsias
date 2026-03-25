## Context

The release pipeline (`.github/workflows/release.yml`) and Cosign signing integration were implemented and archived but never tested against a real CI run. This change tracks the deferred verification tasks from both archived changes.

## Goals / Non-Goals

**Goals:**
- Verify the complete release flow works: tag push → matrix build → checksum → sign → release
- Verify Cosign signatures can be verified locally
- Verify tampered artifacts fail verification
- Confirm Rekor transparency log entries exist

**Non-Goals:**
- Modifying the release pipeline (unless verification reveals bugs)
- Testing auto-updater (separate concern)
- Testing on all three platforms locally (CI handles cross-platform)

## Decisions

### D1: Test with release candidate tag

Use `v<version>-rc.1` tag to trigger the workflow without creating an official release. This avoids polluting the release history while testing the full pipeline.

### D2: Prerequisites checklist

Before verification can begin:
1. Generate Tauri Ed25519 signing keypair (`cargo tauri signer generate`)
2. Update `tauri.conf.json` with the public key
3. Configure GitHub repo secrets (`TAURI_SIGNING_PRIVATE_KEY`, `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`)
4. Install Cosign locally for verification testing
