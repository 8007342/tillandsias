## MODIFIED Requirements

### Requirement: GitHub Login runs in git service container
When the user triggers "GitHub Login" from the tray, the system SHALL run `gh auth login` inside the git service container (which has D-Bus forwarding for host keyring access). This replaces the current approach of running in a standalone forge container. If no git service is running, the system SHALL start one temporarily for the auth flow.

@trace spec:gh-auth-script, spec:git-mirror-service, spec:secret-management

#### Scenario: Credential refresh while agents are working
- **WHEN** a forge container's push fails due to expired credentials
- **AND** the user clicks "GitHub Login" in the tray
- **THEN** `gh auth login` SHALL run in the existing git service container
- **AND** after authentication, subsequent pushes from forge containers SHALL succeed via the mirror's post-receive hook
- **AND** no forge containers need to be restarted

#### Scenario: GitHub Login with no running git service
- **WHEN** the user clicks "GitHub Login" and no git service container is running
- **THEN** the system SHALL start a temporary git service container with D-Bus forwarding
- **AND** run `gh auth login` inside it
- **AND** stop the temporary container after authentication completes
