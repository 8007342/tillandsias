## MODIFIED Requirements

### Requirement: Bind-mount audit of a forge launch
Every `-v`/`--mount`/`--tmpfs` argument of any forge launch MUST resolve to one
of the four permitted categories, and no path under the user's `$HOME` MUST
appear as a bind-mount source — with no exception for a project workspace. The
project checkout inside a forge is cloned from the enclave mirror into the
container filesystem and does not survive the container.
`TILLANDSIAS_PROJECT_HOST_MOUNT` and `TILLANDSIAS_FORGE_HOST_MOUNT` are
removed; an entrypoint that finds a pre-existing `/home/forge/src/<project>`
MUST treat it as a stale layer and clone over it.

@trace spec:forge-as-only-runtime

#### Scenario: Bind-mount audit of a forge launch
- **WHEN** the launcher constructs `ContainerSpec` for any forge mode
- **THEN** every mount argument MUST resolve to a permitted category
- **AND** no path under the user's `$HOME` MUST appear as a bind-mount source
- **AND** the `launch_forge_agent_does_not_mount_user_home` regression test
  MUST cover the project path too

## ADDED Requirements

### Requirement: A forge seeds from any ref the mirror carries
The forge SHALL check out the ref named by `TILLANDSIAS_FORGE_SEED_BRANCH` from
the mirror, including `work/*` and `salvage/*` refs, and the documented way to
test an uncommitted change in a forge SHALL be: make the change a ref
(`scripts/salvage-dirty-worktree.sh`, or a `work/<order>` push), let the mirror
carry it (directly through the lane, or by an on-demand sync from GitHub), seed
the forge from it. The forge welcome and the fleet-joining skill SHALL name this
sequence.

@trace spec:forge-as-only-runtime

#### Scenario: Seeding from a salvage ref
- **WHEN** a host salvages a dirty worktree to `salvage/<host>/<date>-<slug>`
- **AND** launches a forge with that ref as the seed after the mirror carries it
- **THEN** the forge's checkout SHALL contain the salvaged bytes
- **AND** nothing on the host SHALL have been read by the forge
