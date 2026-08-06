# v0.5 refactor, dependency, and freshness audit — 2026-08-05

## Release truth

The folded ledger contains 254 v0.5 packets: 64 completed, 2 obsoleted, and 188
nonterminal (154 ready, 18 pending, 13 in progress, 1 blocked, 2 needing
clarification). `plan/loop_status.md` still reports older 87/94 and 114-total
figures and contains contradictory active-release prose. Order 407 was marked
completed even though its standing per-cycle count criterion is no longer true.

The experts milestone has 75 children: 29 completed, 44 ready, and 2 in
progress. Criteria-holder packets 334, 394, and 554 remain `ready` but are not
claimable work; expert ranking must exclude this class.

## Recent-refactor scale and regression pressure

Since 2026-07-15 base `677b46d2`, the repository accumulated 747 commits (108
merges), touched 834 files, and changed roughly +109k/-11k lines. Highest churn
is concentrated in the ledger, headless launcher, loop status, compiled plan
engine, and forge lifecycle shell. Targeted behavioral gates and dead-tail
removal are therefore higher value than broad source browsing.

`cargo check --workspace --all-targets` passed during this audit.

## Dependency findings

`cargo audit` 0.22.2 against the current RustSec database reports three
vulnerabilities in `rustls-webpki 0.101.7`:

- RUSTSEC-2026-0098
- RUSTSEC-2026-0099
- RUSTSEC-2026-0104

The dependency tail is `reqwest 0.11.27 -> rustls 0.21.12 ->
rustls-webpki 0.101.7`; affected consumers span headless, Vault client, VM
layer, host shell, and both trays. Patched webpki requires at least 0.103.13,
so this is a deliberate reqwest/rustls migration rather than a lock-only bump.

Compatible updates also clear current unsoundness warnings for `anyhow`,
`event-listener`, and `memmap2`. The migration packet owns a post-upgrade lock
refresh and requires `cargo audit` to reach zero known vulnerabilities.

The Nix forge base pins NixOS 24.11 and a 2025-06-30 nixpkgs revision. NixOS
24.11 security support ended in June 2025, while the current stable manual is
26.05. The pinned crane is correspondingly old. This host has no Nix daemon, so
the migration needs x86_64 and aarch64 flake-build evidence on capable hosts.

## Stale implementation tails

1. `images/default/mcp-server-browser.js` is an unreferenced mock that never
   contacts the tray. The live surface is the shell bridge plus Rust host MCP.
2. `images/default/tillandsias-mcp-browser` is a tracked 27 MB, dynamically
   linked x86_64 ELF copied into multi-architecture flake outputs. No source
   target builds it, and it conflicts with the default-image small-shell-bridge
   contract.
3. macOS `VzLifecycle` is explicitly dead; its trait path reaches two
   `unimplemented!` panics while the live tray provisions through
   `action_host.rs`. Remove the dead wrapper/path or delegate it to the live
   implementation, then correct stale VM-layer documentation.

## Freshness system defect

Only 7 of 1,011 inventoried components have freshness stamps. The inventory
labels every stamped component stale without applying an age threshold, even
though methodology requires threshold-based staleness. Integer rounding reports
this as 0% coverage, hiding both the small nonzero baseline and any early
improvement. A successor packet must define the threshold, fractional coverage,
coverage delta, and a negative test proving a fresh stamp is not stale.

## Tracking

New packets filed with this audit:

- `reqwest-rustls-webpki-security-migration`
- `nix-supported-release-and-crane-migration`
- `stale-browser-mcp-artifacts-cleanup`
- `macos-dead-vz-lifecycle-removal`
- `freshness-threshold-and-coverage-truth`
- `folded-loop-status-active-release-truth`

Existing packets remain the owners for append-event fragment writes (600-c266),
build trace regeneration (584-2qq2), stale worker instructions (598-c4ug),
credential leakage and package-verification gaps (576/580/588-3irh), the
OpenCode coredump (604-vmcg), and the unwired `container_profile` abstraction
(577).
