# Parallel workstreams — 2026-07-15 (operator starting Linux + Windows + macOS workers)

The Tlatoāni is spinning up concurrent workers on all three platforms. This
note prevents collision and directs each lane at non-overlapping work. Claim
nodes with `scripts/claim-ledger-node.sh claim <id>` before editing — leases
are advisory but they stop two workers producing the same edit.

## Lane ownership (who takes what)

### Linux coordinator (macuahuitl — this agent): the enclave service-catalog build
OWNS the service-catalog implementation rungs, worked in critical-path order:
- **357 web-publish-local-mvp** (in progress — the thinnest end-to-end slice)
- **358 service-catalog-allowlist-enforcement** (after 357)
- **360 transparent-https-localhost** (parallel-ish, after 357)
- **361 container-share-policy-and-debug-ports** (after 358)
Other Linux workers: DO NOT claim 357/358/360/361 — coordinator is on them.

### Other Linux workers: take these (no overlap with the catalog build)
- **359 forge-github-token-injection** — high value, small, fixes brew
  attestation + git rate-limits for EVERY forge session (independent of the
  catalog build; grab this first).
- Stable-milestone Linux verification: **352 provider-login-live-verify**
  (needs operator for device codes — coordinate), **307 antigravity-launch-crash**
  (now unblockable: agy device-auth shipped; collapses into 352's live verify).
- Architecture audits (any-host, Linux-capable): 245-251, 309, 329, 330, 333.
- Stream/transport refactors: 148, 150, 153, 156, 157, 158.

### Windows worker: stable-milestone-v1 platform criteria (RELEASE-GATING)
- **312 windows-tray-requires-elevation-hcsdiag** — TOP PRIORITY, release-gating:
  a standard-user tray cannot connect until this ships (curl-install Windows
  is dead-on-arrival). Do this first.
- **323 wsl-platform-preflight-classification**, **324 installer-wsl-absent-reboot-affordance**,
  **326 wsl-guest-forge-user-src-ownership**, **350 windows-forge-config-trust-live-parity**.
- Also 154 (windows tray stream refactor), 279 (host lifecycle race).

### macOS worker: stable-milestone-v1 platform criteria
- **331 macos-opencode-host-path-translation** (forge lane currently FAILS
  on host paths — highest macOS value).
- **332 macos-opencode-firstuse-silent-build-idle-timeout**,
  **349 macos-forge-config-trust-live-parity**, **342 macos-forge-owned-checkout-isolation**.
- Also 155 (macos tray stream refactor).

## Two milestones, two convergence goals
- **stable-milestone-v1 (334)**: needs the Windows + macOS criteria above to
  converge before the next `stable` promotion. This is why siblings matter.
- **enclave-service-catalog (353)**: Linux-host-only by operator scope (VM
  boundaries later) — the coordinator's lane; siblings are NOT needed here.

## Ground rules
- Ledger writes (plan/) push to linux-next; platform CODE pushes to your
  platform branch. Merge origin/linux-next before pushing a sibling branch.
- File `provisional_id` + `order: provisional` when filing new packets;
  the Linux coordinator assigns final integers at integration
  (methodology `order_number_assignment`).
- Release-targeted packets outrank the backlog (methodology
  `release_aware_packets`); a milestone packet is a criteria holder — claim
  its children, never the milestone.
