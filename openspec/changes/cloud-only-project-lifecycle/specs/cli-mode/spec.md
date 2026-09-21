## MODIFIED Requirements

### Requirement: Direct agent flags attach to the current terminal
- **WHEN** the user runs `tillandsias --codex <project> --debug`, `tillandsias --claude <project> --debug`, or `tillandsias --bash <project> --debug`
- **THEN** the binary SHALL start the shared enclave stack from Rust
- **AND** it SHALL run the corresponding forge entrypoint attached to the current terminal
- **AND** the forge SHALL clone the project from the enclave mirror, seeded from `TILLANDSIAS_FORGE_SEED_BRANCH` when set; no host path is mounted
- **AND** after the attached forge exits, the project stack SHALL be cleaned up if no forge containers remain active
- **AND** an unresolvable project SHALL exit non-zero with the reason on stderr (1338-i23k)

## ADDED Requirements

### Requirement: `--sync <project>` fast-forwards the mirror from upstream
`tillandsias --sync <project>` SHALL ask the project's mirror to fast-forward
its exported heads from upstream and SHALL print the sync state the mirror
reports; it SHALL exit non-zero when the mirror is absent or refuses.

@trace spec:cli-mode
