# v56.11.3.1 e2e smoke — linux PASS (published release binary: install, signature, Ready, forge prompt, clean quit) (2026-11-03)

- run_start: 2026-11-03T13:53Z
- evidence_dir: the yoga session scratchpad (release assets, tray and forge logs); the lines below are quoted from it
- forge_lane_outcome: completed one-turn prompt. The agent (OpenCode, big-pickle) answered `pong`, exit 0. The installer SOFT-reset podman (see CORRECTION), so images were cold; Vault and models were kept.
- signature_verification: cosign:verified:3/3

Release under test: v56.11.3.1 (prerelease), tag commit bf1668fd1df1b3363b826d083f060234cd2e1d0c. Installed from the PUBLISHED asset: the release's own `install.sh` (itself cosign-verified), with `TILLANDSIAS_RELEASE_BASE=https://github.com/8007342/tillandsias/releases/download/v56.11.3.1`, not from a local build. Host: yoga (Fedora Silverblue, immutable, x86_64, Radeon 840M).

Scope: a published-release smoke on a fleet host. The coordinator asked for NO reset; one happened anyway, see CORRECTION. This is not the clean-room curl-install reset: Vault and its keyring share were kept.

## CORRECTION (the first push of this file said "no podman system reset"; that was false)

The release's install.sh runs `tillandsias --reset-state` after it places the binary (install.sh lines 320-367, order 1286-4437 and 1738-wqmt); only `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0` makes it reprovision through plain `--init`. yoga ran it without that variable. Its own log (~/.local/state/tillandsias/setup.log) says: "reset: SOFT", "WILL BE DESTROYED: ALL podman images on this host (podman system reset --force)", "WILL BE PRESERVED: ... vault-data ... Verified:KEEP", "reset: Vault store kept (Verified:KEEP)", then reprovisioning. The journal shows the removals at 13:54:58Z (pid 2756680), including the non-Tillandsias toolboxes tillandsias-builder and tillandsias-nix. So steps 2-4 ran on images the installer had just rebuilt (v56.11.3.1 images created during the install), which makes this run closer to cold than intended, not warmer. The verdicts below stand; the scope statement did not.

```
1 signature        PASS  cosign verify-blob (ghcr.io/sigstore/cosign/cosign:v3.0.2 in podman; cosign is not on the host) "Verified OK" for tillandsias-linux-x86_64, install.sh and verify.sh, identity regexp https://github.com/.*/tillandsias/, issuer token.actions.githubusercontent.com
  checksum         PASS  sha256sum -c "tillandsias-linux-x86_64: OK", "install.sh: OK" against SHA256SUMS; sha256 5b977bf7a883944f6a37bcfbae5c81d2615218cd4e9bc295b0cab276bbeb3aac
  install          PASS  install.sh exit 0, "PENDING: none" (it SOFT-reset podman and reprovisioned: CORRECTION); installed ~/.local/bin/tillandsias cmp-equal to the verified asset; --version "Tillandsias v56.11.3.1"
2 tray launch      PASS  `tillandsias --tray`: "event:service_ready service=vault container=tillandsias-vault status=vault_unsealed" 14:02:47Z, "event:service_ready service=proxy container=tillandsias-proxy status=proxy_listening" 14:03:18Z; `tillandsias --status-check` "status-check:ok"
3 forge + prompt   PASS  `tillandsias --cloud 8007342/tillandsias --opencode --prompt ping`: proxy ready-earlier, "mirror_seeded_(1)" (bringup step=mirror-seed ms=20297), "[forge] Seed branch: 'linux-next'", the agent answered pong, rc=0 in 94 s
4 clean quit       PASS  SIGTERM to the tray pid: "Received shutdown signal", "Graceful shutdown completed", exited in 6 s; tillandsias-vault and tillandsias-proxy "Exited (0)"; no tillandsias container left running
```

The signing certificate's SAN is `https://github.com/8007342/tillandsias/.github/workflows/release.yml@refs/heads/main`: a verify pinned to the tag ref (`@refs/tags/v56.11.3.1`) refuses it. The identity regexp that verify.sh ships accepts it. Recorded as observed, not as a defect.

## Notes

- Token rotation ran before Vault: the tray's first lines included `[tillandsias] blocked:github-token-rotation-failed:read:vault-unavailable`, printed before `note:cloudflare-store:vault-not-running:starting-the-vault-enclave-only` and the vault bootstrap. yoga has no GitHub token stored (`[forge] push: no-credential`), so nothing was lost here. On a host with a token, the rotation at startup would not have run.
- A stale socket was left at quit: after "Graceful shutdown completed", `/run/user/1000/tillandsias/mcp/tillandsias-default/mcp.sock` was still on disk, with no tray running. The next `--tray` came up over it at once (pid 2804668), so it is cosmetic today. Filed as 1976-9iw3.

## Ledger claims

- EXERCISED: the release's install.sh pinned by TILLANDSIAS_RELEASE_BASE, cosign keyless verify of the Linux assets, Vault unseal and proxy at tray start, the CLI `--cloud` opencode lane with `--prompt`, 1922-lrdy (proxy `ready-earlier`), and graceful tray shutdown.
- NOT CHECKED: the menu's forge click (no GUI scripting); the full clean-room reset (credentials were kept: the installer's soft reset preserves Vault and the keyring share); `image.generate` on the release build; the swap helper (`tillandsias --swap on` was offered, not run).
