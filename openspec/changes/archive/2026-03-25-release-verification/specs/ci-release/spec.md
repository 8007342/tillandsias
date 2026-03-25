## MODIFIED Requirements

### Requirement: Tag-triggered release workflow
The release workflow SHALL be verified to produce correct artifacts for all platforms when triggered by a tag push.

#### Scenario: Full pipeline run
- **WHEN** a `v*` tag is pushed to the repository with signing secrets configured
- **THEN** the workflow completes successfully with build, checksum, sign, and release jobs all passing

#### Scenario: Artifact naming verification
- **WHEN** the release workflow completes
- **THEN** all artifacts follow the `tillandsias-{version}-{os}-{arch}.{ext}` naming convention

#### Scenario: Checksum verification
- **WHEN** the `SHA256SUMS` file is downloaded alongside artifacts
- **THEN** running `sha256sum -c SHA256SUMS` passes for every artifact

#### Scenario: GitHub Release assets
- **WHEN** the release is created on GitHub
- **THEN** all platform binaries, signatures, certificates, and SHA256SUMS are attached
