# tray-app Specification

## Purpose
TBD - created by archiving change tillandsias-bootstrap. Update Purpose after archive.
## Requirements
### Requirement: System tray presence
The application SHALL run exclusively as a system tray icon with no main window. The tray icon MUST be the only visible surface of the application.

#### Scenario: Application startup
- **WHEN** the application is launched
- **THEN** a system tray icon appears with the Tillandsia icon in idle state and no main window is created

#### Scenario: Application idle
- **WHEN** no projects are detected and no apps are running
- **THEN** the tray icon displays the minimal Tillandsia idle state

### Requirement: Dynamic tray menu
The tray menu SHALL rebuild and display updated content whenever the application state changes.

#### Scenario: Menu shows discovered projects
- **WHEN** the scanner discovers projects in ~/src
- **THEN** the tray menu rebuilds to show each project with its available actions

#### Scenario: Quit exits the application
- **WHEN** the user clicks Quit in the tray menu
- **THEN** the application exits immediately

#### Scenario: Menu events reach handlers
- **WHEN** the user clicks any menu item
- **THEN** the corresponding handler is invoked

### Requirement: Tray icon state management
The main tray icon SHALL visually reflect the overall system state.

#### Scenario: Idle state icon
- **WHEN** no projects are detected and no apps are running
- **THEN** the tray icon displays a minimal Tillandsia design (seedling/bud)

#### Scenario: Project detected icon
- **WHEN** at least one project is detected but no apps are running
- **THEN** the tray icon displays a subtle bloom variant

#### Scenario: Running apps icon
- **WHEN** one or more apps are running
- **THEN** the tray icon displays a colorful flower variant

#### Scenario: Multiple running apps icon
- **WHEN** multiple apps are running simultaneously
- **THEN** the tray icon displays a multiple blooms variant

### Requirement: Tillandsia genus iconography system
Each running environment SHALL be assigned a tillandsia genus from a curated pool, with a matching SVG icon that appears in the filesystem tree, running environment chip, and container name to create intuitive visual linking.

#### Scenario: New environment gets a genus
- **WHEN** the user clicks "Attach Here" on a project
- **THEN** a tillandsia genus is assigned from the curated pool (Aeranthos, Ionantha, Xerographica, Caput-Medusae, Bulbosa, Tectorum, Stricta, Usneoides) and its icon appears next to the project name

#### Scenario: Icon reflects container lifecycle
- **WHEN** a container transitions through lifecycle states
- **THEN** the tillandsia icon reflects the plant lifecycle: bud (creating/booting), full bloom (running/healthy), dried bloom (stopping/stopped), pup (spawning rebuild/new process)

#### Scenario: User sees bloom progress
- **WHEN** a container is booting and takes time to become ready
- **THEN** the icon transitions from bud to bloom as the container becomes healthy, giving users a natural metaphor for progress ("the little flower takes about two minutes to bloom")

#### Scenario: Second concurrent environment for same project
- **WHEN** the user launches a second concurrent environment for a project that already has one running
- **THEN** the new environment gets a different tillandsia genus from the pool, visually distinguishing it from the first

### Requirement: SVG icon assets
Tillandsia icons SHALL be abstract SVG silhouettes with 4 state variants per genus, embedded as compile-time assets in the binary.

#### Scenario: Icon variant for each lifecycle state
- **WHEN** the icon system loads
- **THEN** each genus has 4 SVG variants available: bud, bloom, dried, pup

#### Scenario: Icon rendering at tray resolution
- **WHEN** icons are displayed in the system tray menu
- **THEN** SVG icons render cleanly at small sizes (16x16 to 32x32 pixels) as abstract geometric silhouettes

### Requirement: Cross-platform tray behavior
The tray application SHALL function correctly on Linux, macOS, and Windows using Tauri v2's native tray support.

#### Scenario: Linux tray
- **WHEN** the application runs on Linux
- **THEN** the tray icon integrates with the desktop environment via StatusNotifier/libappindicator

#### Scenario: macOS tray
- **WHEN** the application runs on macOS
- **THEN** the tray icon appears in the macOS menu bar as a native NSStatusItem

#### Scenario: Windows tray
- **WHEN** the application runs on Windows
- **THEN** the tray icon appears in the Windows system tray notification area

### Requirement: Minimal resource footprint
The tray application SHALL consume near-zero CPU when idle and less than 100MB of memory.

#### Scenario: Idle resource usage
- **WHEN** the application is running with no active operations
- **THEN** CPU usage is approximately 0% and memory usage is below 100MB

#### Scenario: State change resource spike
- **WHEN** a state change triggers a menu rebuild
- **THEN** the operation completes in under 5ms and CPU returns to idle immediately after

### Requirement: Permanent src/ attachment point
The tray menu SHALL always display the watch path root (~/src/) as a top-level "Attach Here" entry, regardless of whether any projects exist.

#### Scenario: Empty src directory
- **WHEN** ~/src/ contains no projects
- **THEN** the menu shows "~/src/ — Attach Here" as the only actionable entry

#### Scenario: Projects exist alongside src entry
- **WHEN** ~/src/ contains projects
- **THEN** the menu shows "~/src/ — Attach Here" at the top, followed by individual project submenus

### Requirement: Settings submenu
The tray menu SHALL include a Settings submenu that contains configuration, setup actions, and remote project management.

#### Scenario: GitHub Login label when not authenticated
- **WHEN** the Settings submenu is built and GitHub credentials are missing
- **THEN** the submenu contains an item labeled "GitHub Login"

#### Scenario: GitHub Login label when authenticated
- **WHEN** the Settings submenu is built and GitHub credentials are present
- **THEN** the submenu contains an item labeled "GitHub Login Refresh"

#### Scenario: Remote Projects submenu present
- **WHEN** the Settings submenu is built and GitHub credentials are present
- **THEN** a "Remote Projects" submenu appears below the GitHub Login Refresh item

#### Scenario: Remote Projects hidden when not authenticated
- **WHEN** the Settings submenu is built and GitHub credentials are missing
- **THEN** no "Remote Projects" submenu appears

### Requirement: GitHub Login delegates to embedded script
The tray GitHub Login handler SHALL use the binary-embedded `gh-auth-login.sh` content, not a filesystem script.

#### Scenario: Script not found on disk
- **WHEN** no `gh-auth-login.sh` exists at any filesystem location
- **THEN** the handler still works by extracting the embedded script to temp

#### Scenario: Tampered script on disk ignored
- **WHEN** a modified `gh-auth-login.sh` exists at `~/.local/share/tillandsias/`
- **THEN** the handler ignores it and uses the embedded version

### Requirement: Attach Here lifecycle emoji
Each "Attach Here" menu item SHALL display a lifecycle emoji prefix reflecting whether a container is running for that project.

#### Scenario: No container running for project
- **WHEN** the tray menu is built and no tillandsias container is running for a scanned project
- **THEN** the "Attach Here" item for that project is prefixed with 🌱

#### Scenario: Container running for project
- **WHEN** the tray menu is built and a tillandsias container is in the Running state for a scanned project
- **THEN** the "Attach Here" item for that project is prefixed with 🌺

#### Scenario: Container stops
- **WHEN** a running container for a project stops or is destroyed
- **THEN** the menu is rebuilt and the "Attach Here" item reverts to the 🌱 prefix

### Requirement: GitHub Login delegates to embedded script
The tray GitHub Login handler SHALL use the binary-embedded `gh-auth-login.sh` content, not a filesystem script.

#### Scenario: User clicks GitHub Login in tray
- **WHEN** the user clicks GitHub Login in the Settings submenu
- **THEN** the embedded script is extracted to temp and executed in a new terminal window

### Requirement: Single tray icon guarantee
The system SHALL guarantee that at most one tray icon exists per user session, regardless of how many times the application is launched.

#### Scenario: User double-clicks launcher
- **WHEN** the user launches Tillandsias from the desktop launcher while it is already running
- **THEN** no second tray icon appears and the existing instance continues unaffected

#### Scenario: Autostart plus manual launch
- **WHEN** tillandsias starts via autostart on login and the user later launches it manually
- **THEN** only one tray icon exists and the manual launch exits silently

### Requirement: Terminal launches fish with welcome
The Terminal (Ground) tray menu action SHALL launch the fish shell with the welcome message displayed.

#### Scenario: Terminal opens with fish
- **WHEN** the user clicks "Ground" for a project
- **THEN** a ptyxis terminal opens with fish running inside the forge container, showing the welcome message and landing in the project directory

### Requirement: Tray waits for background init
The tray app SHALL detect an in-progress background init and wait for it instead of starting a duplicate build.

#### Scenario: Init running on tray startup
- **WHEN** the tray starts and the forge image is missing but a build lock is active
- **THEN** the tray shows "Preparing environment..." in the menu and waits for the build to complete

#### Scenario: Init completes while tray is waiting
- **WHEN** the background init finishes and the forge image becomes available
- **THEN** the tray menu updates normally with project actions enabled

