# E2E smoke v56.10.15.1 — windows (yolanda-windows) — FAIL (onboarding skill not visible to the agent) (2026-10-15)

Release: https://github.com/8007342/tillandsias/releases/tag/v56.10.15.1
(ledger row on trunk at 9a0673502). Runbook:
skills/smoke-curl-install-and-test-e2e, run on yolanda-windows at the
coordinator's go. Evidence: target/smoke-e2e/ on yolanda.

| Section | Result |
|---|---|
| 0 Pre-flight | PASS. Free memory at start 46.7% (7248 MB of 15526 MB). The builder distro was stopped first; the operator's open apps were left alone. |
| 1 Install (pinned `TILLANDSIAS_VERSION=v56.10.15.1`, `install-windows.ps1`) | PASS. install_exit=0; `tillandsias-tray 56.10.15.1 (35ca3353f)` |
| 1s Signature | NOT CHECKED. `cosign:could-not-run:cosign-absent`. The zip's SHA256 (83a43454…ebd5) matches the release's SHA256SUMS-windows, which is an unsigned manifest. |
| 2 Substrate reset | PARTIAL. The tray was stopped, `wsl --unregister tillandsias` ran, and %USERPROFILE%\.cache\tillandsias was purged (%APPDATA%\tillandsias was absent). The builder vhdx was left untouched. Credential Manager was NOT cleared (operator rule: never touch real entries), so vault-shamir-share-v1 and vault-root-token-v1 were kept. This is not a full clean room for Vault. |
| 3 Fresh provision | PASS. provision_exit=0; status phase=Ready, podman_ready=True; diagnose version=56.10.15.1; the builder disk survived. |
| 4 Forge lane (in-guest `tillandsias-headless --cloud 8007342/tillandsias.org --opencode`) | PASS: cold image build, the agent answered every step and READY, rc=0. Free memory fell to 4.1% during the image build, but the lane was not reaped (it ran as a systemd unit in the guest). |
| 4 Onboarding: start-a-new-project skill | FAIL. The skill IS in the image at /opt/skills/start-a-new-project, but the OpenCode agent reported "no such skill exists in my available-skills list". It is shipped but not registered with the harness. |
| 4 Host-browser MCP | FAIL (known). `ls -la /run/host/tillandsias-mcp/` gave "Permission denied", and `service_status` is not among the agent's tools. This matches 1713-1dnx: the guest binary is built with listen-vsock only, and the lane listener needs the tray feature. |
| 4 1668-8jmq git identity | PASS for "no prompt": the identity was preset to `Tillandsias forge (tillandsias.org) (yolanda · tillandsia-fasciculata)` / `forge+tillandsias.org@users.noreply.tillandsias.invalid`. NOT VERIFIED for "commits authored from the App identity": the test commit was refused by the project's own hook (`blocked:missing-checkouts: v56.10.9.1 (run fetch-checkouts.sh)`), so no commit was made. Whether that noreply.invalid address is the intended App identity is for the 1668 owner to confirm. |
| macron.dev note | NOT RUN. Push permission is waiting for the operator's own confirmation. Per operator rule, macron.dev main is never pushed; notes go to work/ branches. |

## Deviations from the runbook

- §2 skipped the Credential Manager clear (operator rule above).
- §4 used one directed in-guest lane instead of `tillandsias . --opencode
  --prompt "Use the /meta-orchestration skill"`. On Windows there is no host
  CLI forge lane, and a single bounded lane kept memory in check.
- Two lane attempts were lost before the one that ran, and neither was a
  Tillandsias defect. (1) A `setsid nohup` job died when the wsl.exe session
  returned. (2) A systemd unit was stopped about 20 s in because nothing
  held the guest open: the tray had been stopped for §2 and
  `--provision-once` exits. With the tray running and the lane as a
  `systemd-run` unit, it completed.

## Findings to file

1. start-a-new-project is shipped in the forge image but not registered with
   OpenCode, so the onboarding release's skill is invisible to the agent.
2. The per-lane MCP directory is unreadable and the browser tools are
   missing on Windows: confirms 1713-1dnx for Windows.
