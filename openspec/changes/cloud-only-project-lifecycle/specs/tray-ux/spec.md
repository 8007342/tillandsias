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
refresh; and EVERY repository SHALL be launchable from the menu without the
user configuring anything.

By default the list SHALL be rendered flat — every repository at one level,
no page link — because all three host menus scroll: Win32 auto-scrolls, NSMenu
grows scroll arrows, and gnome-shell's appindicator renders a scrollable popup
(measured on GNOME, 2026-09-21; the earlier requirement assumed the opposite
from the fact that the DBusMenu *protocol* has no scrolling concept, which is a
statement about the wire format and not about the shell that draws it).

Paging SHALL remain available as a fallback for a surface that does clip, and
SHALL be reachable only by explicit configuration. When a page size is
configured the remainder SHALL fan out into nested submenus, each item
launchable, and SHALL NOT end in a dead item.

@trace spec:tray-ux

#### Scenario: Default is every repository at one level
- **WHEN** the remote list holds more repositories than the fallback page size
- **AND** no page size has been configured
- **THEN** the menu SHALL show every repository as a direct child
- **AND** SHALL emit no page link

#### Scenario: Configured paging
- **WHEN** a page size is configured and the list exceeds it
- **THEN** the menu SHALL show the first page and a "more …" submenu per
  further page, each item launchable
- **AND** the label SHALL state how many more remain

#### Scenario: Advertised remedies are real
- **WHEN** any menu item, label or log line names an environment variable
- **THEN** the code path that renders the live menu SHALL read that variable
- **AND** a reader that is reachable only from a retired builder SHALL NOT
  satisfy this requirement

#### Scenario: Refresh is idempotent
- **WHEN** the tray refreshes the list twice with no remote change
- **THEN** the two menus SHALL be identical item for item
