## 1. Prerequisites

- [x] 1.1 Generate Tauri Ed25519 signing keypair: `cargo tauri signer generate -w ~/.tauri/tillandsias.key`
- [x] 1.2 Update `src-tauri/tauri.conf.json` with the actual public key
- [x] 1.3 Configure GitHub repo secret `TAURI_SIGNING_PRIVATE_KEY` with the private key content
- [x] 1.4 Configure GitHub repo secret `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` with the key password
- [ ] 1.5 Install Cosign locally for verification testing

## 2. Release Pipeline Verification (from release-pipeline archive)

- [ ] 2.1 Push a release candidate tag (`v0.0.5.1-rc.1`) and verify all three platform builds succeed
- [ ] 2.2 Verify artifact naming matches `tillandsias-{version}-{os}-{arch}.{ext}` for all platforms
- [ ] 2.3 Download `SHA256SUMS` and verify `sha256sum -c SHA256SUMS` passes for all artifacts
- [ ] 2.4 Verify GitHub Release is created with all assets attached

## 3. Cosign Signing Verification (from cosign-signing archive)

- [ ] 3.1 Verify all artifacts in the release have corresponding `.cosign.sig` and `.cosign.cert` files
- [ ] 3.2 Download a signed artifact and run `cosign verify-blob` locally — confirm verification succeeds
- [ ] 3.3 Modify a downloaded artifact (append a byte) and verify `cosign verify-blob` fails
- [ ] 3.4 Search for the artifact hash in the Rekor transparency log and confirm entry exists
- [ ] 3.5 Follow the verification instructions from the release notes on a clean machine (no prior Cosign state)
