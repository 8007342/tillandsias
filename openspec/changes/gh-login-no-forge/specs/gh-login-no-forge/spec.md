## MODIFIED Requirements (gh-auth-script)

### Requirement: GitHub Login works on first run without pre-built forge image
`handle_github_login()` SHALL build the forge image if it is not present before opening the authentication terminal.

#### Scenario: First-run — forge image absent
- **GIVEN** the forge image `tillandsias-forge:latest` does not exist in the local podman image store
- **WHEN** the user clicks "GitHub Login" in the tray menu
- **THEN** a "Building environment..." progress chip appears in the tray menu
- **AND** `build-image.sh forge` runs via the embedded binary pipeline (same as Attach Here)
- **AND** after the image is confirmed present, a terminal opens running `gh-auth-login.sh`
- **AND** the progress chip transitions to completed and fades after 10 seconds

#### Scenario: First-run — forge image build fails
- **GIVEN** the forge image is absent
- **AND** `build-image.sh forge` exits with a non-zero status
- **WHEN** the user clicks "GitHub Login"
- **THEN** a "Failed" chip remains visible in the tray menu
- **AND** no terminal is opened
- **AND** an error is logged

#### Scenario: Subsequent run — forge image already present
- **GIVEN** the forge image `tillandsias-forge:latest` already exists
- **WHEN** the user clicks "GitHub Login"
- **THEN** the image check passes immediately (no build triggered)
- **AND** a terminal opens running `gh-auth-login.sh` as before
- **AND** no build chip appears

### Requirement: Build progress chip shown during GitHub Login image build
The tray menu SHALL display a build progress chip during the forge image build triggered by GitHub Login.

#### Scenario: Progress chip lifecycle
- **GIVEN** GitHub Login triggers a forge image build
- **WHEN** the build starts
- **THEN** the tray menu shows a chip labelled "forge" with InProgress status
- **WHEN** the build completes
- **THEN** the chip transitions to Completed and is removed after the standard 10-second fadeout
- **WHEN** the build fails
- **THEN** the chip remains as Failed until the next build attempt clears it
