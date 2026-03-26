## CHANGED Requirements

### Requirement: GitHub Login item carries a key icon

The "GitHub Login" menu item in the Settings submenu SHALL be prefixed with the key emoji when the user is not authenticated.

#### Scenario: Not authenticated
- **GIVEN** `needs_github_login()` returns `true`
- **THEN** the menu item label is `"🔑 GitHub Login"`

### Requirement: GitHub Login Refresh item carries a lock icon

The "GitHub Login Refresh" menu item in the Settings submenu SHALL be prefixed with the closed lock emoji when the user is already authenticated.

#### Scenario: Authenticated
- **GIVEN** `needs_github_login()` returns `false`
- **THEN** the menu item label is `"🔒 GitHub Login Refresh"`
