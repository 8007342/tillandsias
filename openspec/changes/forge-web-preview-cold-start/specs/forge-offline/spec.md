## MODIFIED Requirements

### Requirement: Forge containers have no credential mounts

Forge containers SHALL NOT have any credential mounts. No GitHub token file, no Claude directory, no D-Bus socket. Credentials are exclusively owned by the git service container. `~/.config/gh` and `~/.ssh` exist only as EMPTY quarantine directories owned by the forge user (consistent with `default-image`'s forge-owned empty overlays), so tools report "not logged in" instead of a permission error.

> Delta: the previous scenario said these paths "SHALL NOT exist", which disagreed with `default-image` ("masked with forge-owned empty overlays") and with the code. The code mounts a ROOT-owned 0700 tmpfs, which made `gh` fail with a misleading "permission denied" (2026-10-12, packet 1625-bax2). The forge stays credential-free.

#### Scenario: Forge launched without credentials
- **WHEN** a forge container is launched
- **THEN** no volume mount SHALL contain tokens, keys, or authentication files
- **AND** the environment SHALL NOT contain `GIT_ASKPASS`, `ANTHROPIC_API_KEY`, or `GH_TOKEN`

#### Scenario: Agent inspects credential paths
- **WHEN** an AI agent inside the forge inspects `~/.config/gh/` or `~/.ssh/`
- **THEN** each is an empty directory owned by the forge user
- **AND** `gh auth status` reports that no host is logged in, not a permission error
- **AND** `/run/secrets/` SHALL NOT exist

#### Scenario: Agent reports an upstream finding
- **WHEN** an AI agent inside the forge needs to report a finding upstream
- **THEN** the forge instructions name the sanctioned route: commit the write-up to a `research/` branch and push it through the mirror
- **AND** no GitHub credential is required in the forge
