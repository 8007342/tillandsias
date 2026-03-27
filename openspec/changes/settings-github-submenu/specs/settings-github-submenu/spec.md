## MODIFIED Requirements

### Requirement: Settings submenu GitHub grouping
The Settings submenu SHALL group GitHub Login and Remote Projects under a single "GitHub" child submenu.

#### Scenario: Unauthenticated state
- **WHEN** the user opens Settings and no GitHub credentials are present
- **THEN** a "GitHub" submenu is shown containing only "🔑 GitHub Login"

#### Scenario: Authenticated state
- **WHEN** the user opens Settings and GitHub credentials are present
- **THEN** a "GitHub" submenu is shown containing "🔒 GitHub Login Refresh", a separator, and "Remote Projects ▸"

#### Scenario: Version and credit remain unchanged
- **WHEN** the Settings submenu is opened in any authentication state
- **THEN** "Tillandsias v<version>" and "by Tlatoāni" appear below the GitHub submenu, separated by a separator

#### Scenario: Event dispatch unchanged
- **WHEN** the user clicks any item inside the GitHub submenu
- **THEN** the same menu item IDs are dispatched as before (no handler changes required)
