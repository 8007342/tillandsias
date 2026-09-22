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
refresh. The list is FLAT by default — every project at one level — because the
shells that render it scroll their own popups (measured by the operator on
gnome-shell 2026-09-22; Win32 and NSMenu were never in question); the old page
cap was inferred from the DBusMenu protocol, which carries no scrolling concept,
and never measured against a screen. Paging stays as an opt-in behind
`TILLANDSIAS_MAX_CLOUD_MENU_ITEMS`, kept live rather than deleted so it cannot
survive green with no caller; when it is on, the overflow label SHALL state how
many more remain and the list SHALL never end in a dead item.

@trace spec:tray-ux

#### Scenario: Flat by default, paged only when asked
- **WHEN** the remote list holds more repositories than a screen shows
- **THEN** the menu SHALL show every project at one level and let the shell scroll
- **AND** with `TILLANDSIAS_MAX_CLOUD_MENU_ITEMS` set, the menu SHALL show that many
  and a "… N more" submenu per further page, each item launchable
- **AND** no item SHALL advertise an environment variable that nothing reads

#### Scenario: Refresh is idempotent
- **WHEN** the tray refreshes the list twice with no remote change
- **THEN** the two menus SHALL be identical item for item
