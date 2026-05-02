# tray-ux Specification

## Purpose
Define the minimalistic tray UX flow for Tillandsias, showing only essential elements at each stage of the application lifecycle.

<!-- @trace spec:tray-minimal-ux -->

## Requirements

### Requirement: First-launch minimal tray
At launch, the tray SHALL show only four elements:
1. `<Checklist> Verifying environment ...` (with spinner/animation)
2. Divider
3. `Version X.Y.Z + Attributions`
4. `Quit Tillandsias`

#### Scenario: Initial state
- **WHEN** Tillandsias starts for the first time
- **THEN** only the four elements above are visible in the tray menu
- **AND** no Projects, Cloud, or GitHub login items are shown

### Requirement: Dynamic environment verification status
The first element SHALL change dynamically as containers are initialized:
- Initial: `<Checklist> Verifying environment ...`
- During proxy build: `<Checklist><Network> Building enclave ...`
- During git build: `<Checklist><Network><Mirror> Building git mirror ...`
- Final success: `<Checklist><Network><Mirror><Browser><DebugBrowser> ✓ Environment OK`
- Final failure: `<WhiteRose> Unhealthy environment`

#### Scenario: Proxy container ready
- **WHEN** the proxy container is successfully built and running
- **THEN** the first element shows `<Checklist><Network> Building enclave ...`

#### Scenario: Git mirror ready
- **WHEN** the git container is successfully built and running
- **THEN** the first element shows `<Checklist><Network><Mirror> Building git mirror ...`

#### Scenario: All images built successfully
- **WHEN** all enclave images (proxy, forge, git, inference, chromium-core, chromium-framework) are built
- **THEN** the first element shows `<Checklist><Network><Mirror><Browser><DebugBrowser> ✓ Environment OK`

#### Scenario: Build failure
- **WHEN** any enclave image fails to build
- **THEN** the first element shows `<WhiteRose> Unhealthy environment`

### Requirement: Post-initialization menu items
Once all images are built successfully, the UX SHALL show:
- `<Home> ~/src >` (local projects) if projects exist
- `<Cloud> Cloud >` if GitHub credentials are present AND remote projects are read successfully
- `<Key> GitHub login` if no GitHub credentials are present

#### Scenario: With GitHub auth and local projects
- **WHEN** all images are built AND GitHub credentials exist AND local projects exist
- **THEN** the menu shows `<Home> ~/src >` and `<Cloud> Cloud >`

#### Scenario: Without GitHub auth
- **WHEN** all images are built AND no GitHub credentials exist
- **THEN** the menu shows only `<Key> GitHub login`

#### Scenario: No local projects
- **WHEN** all images are built AND no local projects exist
- **THEN** the menu shows `<Home> ~/src >` (empty) or omits it
- **AND** shows `<Cloud> Cloud >` if authenticated

### Requirement: Project click launches OpenCode Web
When clicking on a project in the tray menu:
1. If remote project not cloned locally, clone it first
2. Launch OpenCode Web container for the project
3. Once container is healthy, launch a safe browser window inside `tillandsias-chromium-core` container

#### Scenario: Click local project
- **WHEN** user clicks a local project
- **THEN** OpenCode Web container is launched for that project
- **AND** once healthy, a safe browser window opens via `tillandsias-chromium-core` container

#### Scenario: Click remote project (not cloned)
- **WHEN** user clicks a remote project that isn't cloned locally
- **THEN** the project is cloned to local machine first
- **AND** then OpenCode Web container is launched

#### Scenario: Browser launches in chromium container
- **WHEN** OpenCode Web container is healthy
- **THEN** the browser window is launched using `tillandsias-browser-tool` 
- **AND** the browser runs inside `tillandsias-chromium-core` container for isolation
- **AND** communicates with OpenCode Web via the tray socket mount

### Requirement: Stale container cleanup
The system SHALL clean up stale Tillandsias containers on startup:
- Remove any containers with `tillandsias-*` pattern that are not currently tracked
- Allow new containers to regenerate accordingly

#### Scenario: Startup cleanup
- **WHEN** Tillandsias starts
- **THEN** all stopped/orphaned `tillandsias-*` containers are removed
- **AND** only actively tracked containers remain
