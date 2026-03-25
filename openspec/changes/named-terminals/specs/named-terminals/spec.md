## NEW Requirements

### Requirement: Terminal window title

Each terminal window opened by Tillandsias SHALL have a title that matches the tray menu item that triggered it.

#### Scenario: Attach Here terminal title
- **GIVEN** a project "my-project" with an allocated genus whose flower is 🌸
- **WHEN** the user clicks "Attach Here"
- **THEN** the terminal window title is set to "🌸 my-project"

#### Scenario: Maintenance terminal title
- **GIVEN** a project "my-project" with an allocated genus whose flower is 🌺
- **WHEN** the user clicks the Maintenance terminal item
- **THEN** the terminal window title is set to "🌺 my-project"

#### Scenario: Title flag per emulator
- **WHEN** a terminal window is opened
- **THEN** the title flag used is:
  - ptyxis: `-T "<title>"` (inserted before `-s --new-window -x`)
  - gnome-terminal: `--title="<title>"`
  - konsole: `-p tabtitle="<title>"`
  - xterm: `-T "<title>"`
  - Windows cmd: first positional argument to `start` (window title slot)

---

### Requirement: Flower-to-genus mapping

Each `TillandsiaGenus` SHALL have a unique, fixed flower emoji. The mapping is:

| Genus | Flower |
|-------|--------|
| Aeranthos | 🌸 |
| Ionantha | 🌺 |
| Xerographica | 🌻 |
| CaputMedusae | 🌼 |
| Bulbosa | 🌷 |
| Tectorum | 🌹 |
| Stricta | 🏵️ |
| Usneoides | 💮 |

#### Scenario: No two genera share a flower
- **WHEN** `TillandsiaGenus::flower()` is called for every variant
- **THEN** all returned emoji are distinct

---

### Requirement: Menu-to-window 1:1 match

The flower emoji shown in a tray menu item SHALL be identical to the flower in the corresponding terminal window title.

#### Scenario: Running attach item label
- **GIVEN** a project with an active Attach Here container whose genus is Aeranthos (🌸)
- **WHEN** the tray menu is built
- **THEN** the "Attach Here" menu item label reads "🌸 Attach Here"

#### Scenario: Idle attach item label
- **GIVEN** a project with no running Attach Here container
- **WHEN** the tray menu is built
- **THEN** the "Attach Here" menu item label reads "Attach Here" (no flower prefix)

---

### Requirement: Don't-relaunch protection

Tillandsias SHALL NOT spawn a second container or terminal if one is already running for the same project slot.

#### Scenario: Attach Here duplicate prevented
- **GIVEN** a container for project "my-project" is present in `state.running`
- **WHEN** the user clicks "Attach Here" for "my-project"
- **THEN** no new container is started
- **AND** a desktop notification is shown with the message "Already running — look for '🌸 my-project' in your windows" (flower matches the running container's genus)

#### Scenario: Maintenance terminal duplicate prevented
- **GIVEN** a maintenance container named `tillandsias-my-project-terminal` is present in `state.running`
- **WHEN** the user clicks the Maintenance terminal item for "my-project"
- **THEN** no new container is started
- **AND** a desktop notification is shown with the matching flower and project name

#### Scenario: Notification only — no modal
- **WHEN** the don't-relaunch guard fires
- **THEN** the feedback is a desktop notification (OS notification area), not a dialog box or blocking prompt
