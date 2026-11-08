# Smoke e2e findings — v56.11.7.1 — windows — yolanda — 2026-11-08

Verdict: windows PASS v56.11.7.1 smoke e2e (forge validation, Claude Code harness).

## Provenance

- The operator installed the tray on yolanda from the `unstable` release with `irm | iex`, and said so in the coordinator session on 2026-11-08.
- `unstable` and `v56.11.7.1` both peel to 8351a0f3ff4552b6ec0daadc3984e2a2d341f91c (`git ls-remote origin refs/tags/unstable^{} refs/tags/v56.11.7.1^{}`, checked by macuahuitl 2026-11-08).
- The forge agent `tillandsias-yolanda-forge` ran the six checks below, read-only. It pushed nothing and ran no login. It echoed back the coordinator's nonce `yol-0f3c-1108`.

## Results (quoted from the forge agent)

1. Identity ok. `.forge-startup-context.md` Version 56.11.7.1, generated 2026-11-08T00:21Z; base_state=ok, host_lane=ready. Kernel 6.18.33.2-microsoft-standard-WSL2.
2. Credential guard ok. `scripts/check-credential-channel.sh` final line: `ok:forge-git-mirror` (rc=0).
3. Mirror ok. `git ls-remote origin refs/heads/linux-next` = b7ed781a7; `git fetch --dry-run origin` rc=0.
4. Health ok. Fresh processes ran (`sh -c true` rc=0), 25 processes, 4963 MB memory available. No crash or hang.
5. Disk ok. /home/forge/src is tmpfs: 1.5G total, 1.2G available.
6. Latency ok. `git status --short` took 0.112 s.

## Not covered

- The opencode harness was not exercised on Windows. See the Linux report: the opencode turn fails against opencode.ai (2027-e2cf).
- The accelerator envelope reported cpu-only: a GPU is present but unusable (no Vulkan loader).
