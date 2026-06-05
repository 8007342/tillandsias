# Updating Tillandsias

Tillandsias v0.3 updates are installed by re-running the release installer or downloading the latest platform bundle.

## Update Flow

### Linux
```bash
curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash
```

### macOS
```bash
curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install-macos.sh | bash
```

### Windows
Download the latest [`tillandsias-tray-windows-x64.zip`](https://github.com/8007342/tillandsias/releases/latest) and run `scripts\install-windows.ps1 -Provision`.

## The Fedora Pivot (v0.3.0)
If you are updating from v0.2.x, the first run after update will re-provision your utility VM using the new **official Fedora images**. This is a one-time migration that improves reliability and eliminates the need for custom rootfs downloads.

After updating, initialize the new runtime:

```bash
tillandsias --init --debug
```

## Verification
Every release publishes `SHA256SUMS` and Sigstore bundle signatures. See [VERIFICATION.md](VERIFICATION.md) for the signature verification flow.

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
