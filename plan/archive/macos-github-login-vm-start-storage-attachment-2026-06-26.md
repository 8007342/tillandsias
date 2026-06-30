# macOS `--github-login` fails immediately at VM start with invalid storage attachment — 2026-06-26

**Filed:** 2026-06-26 (macOS end-to-end verification run)
**Kind:** bug / blocker
**Host:** macOS (`osx-next`)
**Trace:** `spec:macos-native-tray`, `spec:vm-provisioning-lifecycle`, `spec:gh-auth-script`

## Summary

The current macOS `--github-login` path does not reach GitHub auth or the guest
Vault flow. It fails immediately while starting the VZ guest:

```text
[github-login] starting VM…
{"error":"start: VM start failed: Invalid virtual machine configuration. The storage device attachment is invalid."}
```

That blocks both the tray menu path and the standalone CLI smoke. The failure
occurs before the guest login prompt, so this is not the earlier Vault bootstrap
timeout.

## Evidence

- Built the local tray successfully with `scripts/build-macos-tray.sh`.
- Launched `dist/Tillandsias.app` and confirmed the menubar icon rendered.
- The tray menu stayed on the provisioning shell (`Setting up...`) and never
  exposed `GitHub Login`.
- Direct CLI smoke:

```bash
printf 'Test User\ntest.user@example.com\nfake-token-for-smoke\n' \
  | dist/Tillandsias.app/Contents/MacOS/tillandsias-tray --github-login
```

returned the storage-attachment error above.

## Relevant code paths

- `crates/tillandsias-macos-tray/src/diagnose.rs::github_login_main`
- `crates/tillandsias-vm-layer/src/vz.rs::VzRuntime::start`
- `crates/tillandsias-vm-layer/src/vz.rs::generate_cidata_iso`
- `crates/tillandsias-vm-layer/src/vz.rs::build_vm_configuration`

`VzRuntime::start` generates `cidata.iso`, then constructs the VZ config with
the root disk plus the cidata attachment. The error is thrown before any guest
auth prompt, so the likely failure is in that storage attachment setup or in the
generated cidata image itself.

## Next step

Narrow the macOS VZ config failure by checking the generated `cidata.iso` and
the `VZDiskImageStorageDeviceAttachment` setup in `VzRuntime::start`, then rerun
`--github-login` once the VM starts cleanly.
