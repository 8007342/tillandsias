## ADDED Requirements

### Requirement: Single tray icon guarantee
The system SHALL guarantee that at most one tray icon exists per user session, regardless of how many times the application is launched.

#### Scenario: User double-clicks launcher
- **WHEN** the user launches Tillandsias from the desktop launcher while it is already running
- **THEN** no second tray icon appears and the existing instance continues unaffected

#### Scenario: Autostart plus manual launch
- **WHEN** tillandsias starts via autostart on login and the user later launches it manually
- **THEN** only one tray icon exists and the manual launch exits silently
