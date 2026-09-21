## MODIFIED Requirements

### Requirement: Post-initialization menu items
Once `forge_available = true`, the UX MUST show at the top level the root
terminal, the GitHub login item when not authenticated, and the cloud project
list when authenticated. There is no local-projects section: every project the
menu shows is a remote repository the seeded token can see, and a project's
submenu carries its four action buttons whether or not it has ever been
launched.

#### Scenario: Authenticated
- **WHEN** `forge_available = true` AND GitHub credentials exist
- **THEN** the menu MUST show the root terminal and the cloud project list
- **AND** MUST NOT show a "local projects" section or "No projects detected"

#### Scenario: Not authenticated
- **WHEN** `forge_available = true` AND no GitHub credentials exist
- **THEN** the menu MUST show the root terminal and the GitHub login item only

## ADDED Requirements

### Requirement: The cloud project list is idempotent from remote state
The project list SHALL be a pure function of the remote repository list (cached
per boot, refreshed on demand and after a login) and the per-project running
state; rendering it twice from the same inputs SHALL produce the same menu; a
repository that disappears remotely SHALL disappear from the menu on the next
refresh; and when the list exceeds the menu's page size it SHALL fan out into
paged submenus rather than end in a dead item; the overflow label SHALL state
how many more remain (the page size is an implementation constant read from
one place, not a number the user can act on).

@trace spec:tray-ux

#### Scenario: Overflow pages
- **WHEN** the remote list holds more repositories than one page
- **THEN** the menu SHALL show the first page and a "more …" submenu per
  further page, each item launchable
- **AND** no item SHALL advertise an environment variable that nothing reads

#### Scenario: Refresh is idempotent
- **WHEN** the tray refreshes the list twice with no remote change
- **THEN** the two menus SHALL be identical item for item
