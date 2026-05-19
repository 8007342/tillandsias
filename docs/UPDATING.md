# Updating Tillandsias

Tillandsias v0.2 updates are installed by re-running the release installer. The
current release lane publishes a Linux musl-static binary named
`tillandsias-linux-x86_64`; there is no active AppImage/Tauri auto-updater.

## Update

```bash
curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash
```

The installer replaces `~/.local/bin/tillandsias` atomically. It does not
install host packages, fetch Chromium, or run container initialization.

After updating:

```bash
tillandsias --init --debug
tillandsias --debug --tray
```

## Verification

Every release publishes `SHA256SUMS` and Cosign bundle signatures. See
[VERIFICATION.md](VERIFICATION.md) for the signature verification flow.

## Offline Behavior

Tillandsias continues running the installed version when the network is
unavailable. Updating requires access to the GitHub Release assets or manually
placing a previously downloaded `tillandsias-linux-x86_64` binary at
`~/.local/bin/tillandsias`.

## Troubleshooting

| Issue | Solution |
|---|---|
| Installer cannot download the binary | Check access to GitHub Releases or download the asset manually |
| Checksum verification fails | Do not use the artifact; retry the download or inspect the release |
| `tillandsias` still resolves to an old path | Check `command -v tillandsias` and adjust `PATH` so `~/.local/bin` wins |
| Runtime launch fails after update | Re-run `tillandsias --init --debug` and inspect the Podman error |
