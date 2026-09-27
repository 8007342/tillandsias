# Smoke e2e — v56.9.27.2, Linux (Fedora Silverblue), yoga, 2026-09-27

Verdict: **PASS** for v56.9.27.2 on Linux — install, installer signature and checksum, exact version, provision, and the enclave status check. The installer's destructive `--reset-state` leg was DELIBERATELY UNMEASURED on this host (see below). Two findings are recorded; neither blocks the release.

Host: Fedora Linux 44.20260925.0 (Silverblue), kernel 7.2.7-200.fc44.x86_64, podman 5.8.7, cosign v3.0.5 linux/amd64 (sha256 matches sigstore's cosign_checksums.txt). Previously installed: Tillandsias v56.9.21.2.

## Steps

| Step | Result | Evidence |
|---|---|---|
| 0 — installer integrity, BEFORE execution | PASS | `install.sh` downloaded from the v56.9.27.2 release assets; `cosign verify-blob --bundle install.sh.cosign.bundle` with identity `^https://github\.com/8007342/tillandsias/\.github/workflows/release\.yml@refs/(tags\|heads)/`, issuer `https://token.actions.githubusercontent.com` -> `Verified OK` (rc 0); `SHA256SUMS` -> `install.sh: OK` (rc 0); the script read before running (no sudo; refuses root; installs to `~/.local/bin`) |
| 0 — pinned to the exact tag (resolve-only) | PASS | `TILLANDSIAS_RELEASE_BASE=https://github.com/8007342/tillandsias/releases/download/v56.9.27.2 TILLANDSIAS_INSTALL_RESOLVE_ONLY=1` -> `resolved-channel: stable (default of this installer copy) base: https://github.com/8007342/tillandsias/releases/download/v56.9.27.2` (a plain run would have taken the stable channel, not this prerelease) |
| 1 — exact-tag install | PASS | `bash install.sh` with that base -> exit 0, 08:29:42Z–08:31:31Z; log: `Verifying SHA256 checksum...`, `Installed /var/home/tlatoani/.local/bin/tillandsias`, desktop launcher installed, `PENDING: none` |
| 1 — exact version | PASS | `tillandsias --version` -> `Tillandsias v56.9.27.2` |
| 2 — destructive reset | NOT RUN (deliberate) | see "The reset leg" below |
| 3 — provision | PASS | the reprovision ran through plain `--init` (reset opted out): `init: version changed (cached 56.9.21.2, current 56.9.27.2)`, git image rebuilt, proxy re-tagged, exit 0 |
| 3 — enclave | PASS | `tillandsias --ensure-enclave` -> exit 0, `ok:enclave-ensured:proxy=running`, Vault bootstrap complete |
| 3 — status check | PASS | `tillandsias --status-check` -> exit 0, `status-check completed`, 0 warnings; `tillandsias-vault` and `tillandsias-proxy` Up (healthy) |

## The reset leg — DELIBERATELY UNMEASURED

`install.sh` ends by running `tillandsias --reset-state --debug`, which wipes Vault, the host-held vault credentials, the Vault store and ALL podman images before reprovisioning. On yoga that destroys the GitHub credential only the operator may re-seed, and the coordinator's smoke go was not the operator's approval to do so. The installer's documented opt-out was used, `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0`, and the log confirms it took effect:

    [tillandsias] --reset-state: reset skipped by TILLANDSIAS_DESTRUCTIVE_RESET_OK=0 — reprovisioning through the platform's plain init instead.

This leg is recorded as UNMEASURED on Linux for v56.9.27.2 — not as passed. macOS and Windows measured the reset path for this tag with the operator's wipe authorisation.

## Finding 1 — 1437-dypk: status-check green with Vault down

The FIRST `--status-check`, before `--ensure-enclave` (plain `--init` builds images and does not bring the enclave up), also exited 0 and printed `status-check completed`, while warning `Vault container is not running` and launching the git mirror credential-less. Filed as 1437-dypk; fixed and landed at 888548574 (status-check now prints a machine-readable `status-check:ok` / `status-check:degraded:<reasons>` verdict before the completion line).

## Finding 2 — 1438-zqtn: the debug init leaves /tmp/tillandsias-init-vault.log

After the install, `/tmp/tillandsias-init-vault.log` remained (mode 644, 3865 bytes, written at 08:30Z by the release's `--init --debug`), which reddened `litmus:binary-e2e-smoke` step 5. Severity measured without printing content: 0 lines matching `Unseal Key|Root Token|hvs\.|s\.[A-Za-z0-9]{24}`; the lines matching a broader keyword search were image-build output. Cause: `cleanup_init_logs` omitted `vault` and `web` (same at stable v56.9.25.2). Filed as 1438-zqtn (hygiene, p3); fixed and landed at 888548574 (one `INIT_IMAGES` list for build and cleanup).
