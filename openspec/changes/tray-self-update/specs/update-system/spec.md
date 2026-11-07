## ADDED Requirements

### Requirement: a stable update is verified by signature before anything is replaced

The tray SHALL verify the release's `update-manifest.json` against an Ed25519
public key compiled into the running binary, then each artifact's SHA256 from that
manifest, and SHALL replace nothing unless every check passes. A version not newer
than the running one SHALL be refused.

#### Scenario: a tampered manifest

- **WHEN** the manifest's signature does not verify with the compiled-in key
- **THEN** the tray reports `refused:update:signature` and keeps running the current version

#### Scenario: a tampered artifact

- **WHEN** a downloaded artifact's SHA256 differs from the signed manifest
- **THEN** the tray reports `refused:update:digest` and replaces nothing

### Requirement: a tray update does not stop running forges

Applying an update SHALL leave each running forge running (Linux, Windows) or
frozen and resumed (macOS), and SHALL tell each forge of the update.

#### Scenario: a forge across an update

- **WHEN** the tray updates from one stable release to the next with a forge running
- **THEN** the forge keeps its session, and `forge.update_status` reports both versions and `stale: true`

### Requirement: a required restart never discards unpushed work

A forge SHALL be restarted for a `required` component only when its workspace is
clean and has no commits ahead of its upstream. Otherwise it SHALL keep running on
the old version, be asked to push, and be shown as waiting.

#### Scenario: unpushed commits

- **WHEN** a release requires a forge restart and the forge has a commit not on its upstream
- **THEN** the forge is not restarted and the tray shows it as waiting for a push

### Requirement: a tray that fails to start after an update is rolled back

If the new tray does not reach Ready within 120 seconds, the previous binary SHALL
be restored and started, the failed version SHALL not be offered again, and no data
or image SHALL be rolled back.

#### Scenario: the new tray never reaches Ready

- **WHEN** the updated tray does not reach Ready within 120 seconds
- **THEN** the previous tray runs again and the update reports `rolled-back:<version>`

### Requirement: the operator can opt out or delay

The tray SHALL offer `auto`, `notify` and `off` update modes and a postpone
action, and SHALL check for releases only on tray start and menu open unless the
operator approves a background cadence.

#### Scenario: notify mode

- **WHEN** the mode is `notify` and a verified update is ready
- **THEN** nothing is applied until the user chooses to update
