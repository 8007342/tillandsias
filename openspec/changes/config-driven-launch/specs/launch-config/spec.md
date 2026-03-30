## ADDED Requirements

### Requirement: Container launches are driven by declarative profiles
The Rust code SHALL use `ContainerProfile` structs to describe each container type's launch configuration, and a single `build_podman_args()` function to produce podman arguments from profiles.

#### Scenario: Profile defines entrypoint
- **WHEN** a container is launched with a profile that specifies `entrypoint = "entrypoint-forge-claude.sh"`
- **THEN** the podman run command includes `--entrypoint /usr/local/bin/entrypoint-forge-claude.sh`

#### Scenario: Profile defines mounts
- **WHEN** a container is launched with a profile that specifies mounts with logical keys ("project", "cache", "secrets/gh")
- **THEN** the logical keys are resolved to absolute host paths and the podman run command includes the corresponding `-v` flags

#### Scenario: Profile defines env vars
- **WHEN** a container is launched with a profile that specifies env vars ("TILLANDSIAS_PROJECT", "TILLANDSIAS_HOST_OS")
- **THEN** the podman run command includes `-e` flags for each env var with values resolved from the launch context

#### Scenario: Profile defines secrets
- **WHEN** a container is launched with a profile that specifies secret mounts
- **THEN** only the declared secrets are mounted into the container — no undeclared secrets leak through

### Requirement: Security flags are hardcoded, not configurable
The `build_podman_args()` function SHALL always include non-negotiable security flags regardless of the profile contents.

#### Scenario: Security flags present for every container type
- **WHEN** any container is launched via `build_podman_args()`
- **THEN** the args include `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--security-opt=label=disable`, `--rm`, `--init`, `--stop-timeout=10`

#### Scenario: Profile cannot remove security flags
- **WHEN** a profile (built-in or future custom) does not mention security flags
- **THEN** all security flags are still present in the output — they are unconditional

### Requirement: Config schema is versioned
The TOML config schema SHALL include a `version` field for forward compatibility.

#### Scenario: Config without version field
- **WHEN** a config file does not include a `version` field
- **THEN** it is treated as version 1

#### Scenario: Config with unknown future version
- **WHEN** a config file has `version = 99` (higher than the app supports)
- **THEN** a warning is logged ("Config version 99 is newer than supported. Some settings may be ignored.") and the config is parsed best-effort

#### Scenario: Unknown fields are ignored
- **WHEN** a config file contains fields not recognized by the current app version
- **THEN** those fields are silently ignored (not treated as errors)
