## MODIFIED Requirements

### Requirement: Runtime image source digest detects stale images

Runtime image builds that use release-shipped Containerfiles MUST compare the current runtime image source digest with the digest stored after the last successful build. The runtime MUST rebuild an image when its materialized image context changes and MUST NOT rely on repository file mtimes for installed user runtime staleness. The comparison MUST happen on every on-demand ensure, not only under `tillandsias --init`, and the ensure MUST print the digest it computed and the digest the present image carries, so a reuse of a stale image is diagnosable from the launch output alone.

#### Scenario: Runtime source digest changed

- **WHEN** a versioned image exists locally but its cached source digest differs from the current release runtime asset digest
- **THEN** `tillandsias --init` MUST rebuild the affected image
- **AND** any on-demand ensure of that image MUST rebuild it before launching
- **AND** the verdict line SHOULD identify that runtime assets changed

#### Scenario: Developer override uses checkout sources

- **WHEN** `TILLANDSIAS_ROOT` is explicitly set to a valid checkout
- **THEN** runtime image source digests MAY be computed from that checkout's image context
- **AND** an invalid `TILLANDSIAS_ROOT` MUST fail loudly instead of falling back silently

#### Scenario: Same version string, different tree

- **WHEN** a binary is rebuilt from a tree whose image inputs changed but whose version string did not
- **THEN** the next on-demand ensure MUST compute a different source digest, print both digests, and decide Build
