# Smoke e2e findings — v56.11.7.1 — linux — yoga forge — 2026-11-08

Verdict: linux PASS v56.11.7.1 smoke e2e (forge validation, Claude Code harness), with the opencode-harness failure carried as a known issue.

## Why this file exists

The earlier Linux report, `smoke-e2e-findings-v56.11.7.1-2026-11-07-linux-yoga.md`, has the verdict FAIL: the opencode forge turn died with `EPROTO`, which opencode.ai's edge caused by sending a TLS alert. The promotion gate still counted that report as Linux evidence, because it matched a per-step "PASS ... v56.11.7.1" table line. That is a gate defect (filed separately). This file is the honest Linux evidence the promotion relies on.

## Provenance

- The operator curl-installed the tray on yoga from the `unstable` release, which peels to 8351a0f3f, the same commit as `v56.11.7.1`. They said so in the coordinator session on 2026-11-08.
- The forge agent `tillandsias-yoga-forge` ran six checks, read-only. It made no opencode.ai request and ran no login. It echoed back the coordinator's nonce `yog-7a21-1108`.

## Results (quoted from the forge agent)

1. Identity ok. Version 56.11.7.1, generated 2026-11-08T00:41Z. Kernel 7.2.15-300.fc45.x86_64. Harness: Claude Code.
2. Credential guard ok. `ok:forge-git-mirror` (rc=0).
3. Mirror ok. linux-next 7d18c6e41 matches local HEAD; `git fetch --dry-run origin` rc=0.
4. Health ok. `sh -c true` rc=0; 25 processes; 11113 MB available. No crash or hang.
5. Disk ok. /home/forge/src is tmpfs, 1.2G available.
6. Latency ok. `git status --short` took 0.053 s.

## Known issue carried into stable

- The opencode harness fails on cold Linux lanes: opencode.ai's edge closes the connection, most likely on large requests (2027-e2cf). The opencode version pin is #999. The cause is unproven until the live A/B test runs, and that test needs operator consent.
