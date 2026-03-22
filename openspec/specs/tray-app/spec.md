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
The tray menu SHALL be rebuilt on every state change and display a hierarchical view of discovered projects and running environments with tillandsia iconography linking related elements.

#### Scenario: Menu with discovered projects
- **WHEN** the user clicks the tray icon and projects exist in the watch directory
- **THEN** a menu displays showing each project as a submenu under the watch path, with available actions per project

#### Scenario: Menu with running environments
- **WHEN** one or more environments are running
- **THEN** each running environment appears as a top-level item below the project tree, showing its assigned tillandsia genus icon, project name, and Stop/Destroy actions

#### Scenario: Visual linking between tree and running environments
- **WHEN** an environment is running for a project
- **THEN** the same tillandsia genus icon appears both next to the project in the filesystem tree and in the running environment chip, creating an intuitive visual link

#### Scenario: Multiple concurrent environments for same project
- **WHEN** two environments are running for the same project
- **THEN** each has a different tillandsia genus icon, and both icons appear in the project's tree entry

#### Scenario: Empty state
- **WHEN** no projects exist in the watch directory
- **THEN** the menu displays the watch path with a disabled "No projects found" item

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

