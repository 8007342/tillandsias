## ADDED Requirements

### Requirement: Forge CLI tillandsias-logs is embedded in the tray binary

The tray binary SHALL embed `images/default/cli/tillandsias-logs` and
write it to `cli/tillandsias-logs` in the extracted image-sources
directory used by `--init`. The forge `Containerfile`'s
`COPY cli/tillandsias-logs /opt/agents/tillandsias-cli/bin/tillandsias-logs`
directive SHALL resolve on every platform and every code path
(workspace builds, deployed builds, Linux build-image.sh,
Windows direct-podman builds). The binary SHALL be `chmod 0755` on
Unix alongside the other discoverability CLIs (`tillandsias-inventory`,
`tillandsias-services`, `tillandsias-models`).

#### Scenario: deployed tray builds the forge image

- **GIVEN** the tray binary is installed (no workspace on disk)
- **WHEN** `tillandsias --init` runs
- **THEN** the embedded extraction at
  `<temp>/image-sources-<pid>/images/default/cli/tillandsias-logs`
  exists and is non-empty
- **AND** the forge build's `COPY cli/tillandsias-logs ...` step
  succeeds

#### Scenario: external-logs reader is invokable

- **GIVEN** a forge container is running an image built from the
  workspace
- **WHEN** the agent invokes `tillandsias-logs ls`
- **THEN** the binary at `/opt/agents/tillandsias-cli/bin/tillandsias-logs`
  (symlinked from `/usr/local/bin/tillandsias-logs`) is executable and
  prints the available log streams
