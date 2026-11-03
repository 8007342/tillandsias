# v56.11.3.1 e2e smoke — linux PASS (published release binary: install, signature, Ready, forge prompt, clean quit) (2026-11-03)

- run_start: 2026-11-03T13:53Z
- evidence_dir: the yoga session scratchpad (release assets, tray and forge logs); the lines below are quoted from it
- forge_lane_outcome: completed one-turn prompt. The agent (OpenCode, big-pickle) answered `pong`, exit 0. The host was not reset, so this is not a cold-host run.
- signature_verification: cosign:verified:3/3

Release under test: v56.11.3.1 (prerelease), tag commit bf1668fd1df1b3363b826d083f060234cd2e1d0c. Installed from the PUBLISHED asset: the release's own `install.sh` (itself cosign-verified), with `TILLANDSIAS_RELEASE_BASE=https://github.com/8007342/tillandsias/releases/download/v56.11.3.1`, not from a local build. Host: yoga (Fedora Silverblue, immutable, x86_64, Radeon 840M).

Scope, as the coordinator asked: a published-release smoke on a fleet host. There was NO `podman system reset`; the host's podman state, Vault store and models were kept. This is not the clean-room curl-install reset.

```
1 signature        PASS  cosign verify-blob (ghcr.io/sigstore/cosign/cosign:v3.0.2 in podman; cosign is not on the host) "Verified OK" for tillandsias-linux-x86_64, install.sh and verify.sh, identity regexp https://github.com/.*/tillandsias/, issuer token.actions.githubusercontent.com
  checksum         PASS  sha256sum -c "tillandsias-linux-x86_64: OK", "install.sh: OK" against SHA256SUMS; sha256 5b977bf7a883944f6a37bcfbae5c81d2615218cd4e9bc295b0cab276bbeb3aac
  install          PASS  install.sh exit 0, "PENDING: none"; installed ~/.local/bin/tillandsias cmp-equal to the verified asset; --version "Tillandsias v56.11.3.1"
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
- NOT CHECKED: the menu's forge click (no GUI scripting); a clean-room reset (ruled out for this run); `image.generate` on the release build; the swap helper (`tillandsias --swap on` was offered, not run).
