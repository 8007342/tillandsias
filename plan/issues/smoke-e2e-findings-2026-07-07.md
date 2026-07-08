# Smoke E2E Findings — 2026-07-07

## Result: PASS

## Summary
Full curl-install e2e cycle completed successfully on `linux_immutable`:
- Release v0.3.260707.2 installed from GitHub
- `podman system reset --force` — clean
- `tillandsias --debug --init` — all containers built, Vault healthy, networks created
- Forge run with `/meta-orchestration` — completed order 227 (container-dependency-graph-satisfier-typestate)

## Orders Advanced
| Order | Title | Status |
|-------|-------|--------|
| 236 | container-microdnf-gpg-workaround | completed (plan ledged updated, fix already landed) |
| 227 | container-dependency-graph-satisfier-typestate | completed (by forge inside container) |

## Known Issues (non-blocking)
1. **forge-mirror HTTPS credential issue** — The git-mirror inside the forge cannot push to GitHub over HTTPS (`fatal: could not read Username for 'https://github.com'`). Commits reach the local forge mirror (`git://tillandsias-git/tillandsias`) but are not forwarded to GitHub. This is a persistent infrastructure limitation; the forge mirror is configured with no SSH/HTTPS credential for GitHub upstream.
2. **forge container mirror unreachable from host** — The forge mirror container (`tillandsias-git`) is on the `egress` network and cannot be resolved from the host. Forge commits that fail upstream forwarding require manual cherry-pick or a push from the original agent's session.
