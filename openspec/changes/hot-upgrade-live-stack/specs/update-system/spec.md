## MODIFIED Requirements

### Requirement: Platform-appropriate artifact selection

Status of this spec changes from `obsolete` to `draft`: the native crates
gain an updater whose install path is the SOFT tier of `host-state-lifecycle`.
The updater SHALL select the release artifact matching the current platform
(the Linux musl binary, the macOS tray bundle, the Windows tray executable —
the artefacts the release workflow publishes today, not the retired
AppImage/.dmg/.exe set) and resolve it by channel tag per `versioning`
"Rolling channel tags", never `releases/latest`.

#### Scenario: Platform-appropriate artifact selection
- **WHEN** an update is available and the updater downloads it
- **THEN** it selects the artifact matching the current platform and the
  channel tag it was asked for.
- Pre-fix result: FAILS — no updater exists; `UpdatesConfig` (`config.rs:328`)
  is read by nothing.

## ADDED Requirements

### Requirement: `tillandsias --update` upgrades through the SOFT tier

`tillandsias --update [--check-only] [--channel <stable|next>]` SHALL resolve
the release by channel tag, download and verify the artifact (checksum, and
signature when `binary-signing` provides one), install it atomically beside
the running binary, and exec it with `--upgrade-handoff`. Every run SHALL end
with exactly one printed outcome: `upgraded:<from>-><to>`, `up-to-date:<version>`,
`deferred:<reason>` or `refused:<reason>`. A downgrade SHALL be refused by the
existing downgrade guard. When the handoff is refused the installed file is
left staged, the running instance is untouched, and the outcome names the
relaunch command — the upgrade never degrades to a stop-everything reset on
its own.

@trace spec:update-system, spec:host-state-lifecycle

#### Scenario: Update with a live forge
- **WHEN** `--update` runs while a forge is active
- **THEN** the outcome is `upgraded`, the forge container id is unchanged, and
  the agent inside observed no signal.
- Pre-fix result: FAILS — unknown flag.

#### Scenario: Unsafe upgrade falls back loudly
- **WHEN** the handoff is refused for any reason
- **THEN** the running instance is untouched, the outcome is `refused:<reason>`,
  and the message names `tillandsias --quit && tillandsias`.

#### Scenario: Check only
- **WHEN** `--update --check-only` runs against a `file://` release fixture
- **THEN** it prints `up-to-date:<version>` or the available version and
  changes nothing on disk.

### Requirement: Background update check is periodic, opt-out and never interrupts

The tray SHALL check for updates every `[updates] check_interval_hours` hours
(default 24; `0` disables) and on launch when `check_on_launch` is true. A
background check SHALL only download and stage under `downloads/updates/`
(recorded in the download manifest). Installation SHALL happen only when the
stack is idle (no lane launched in the last 10 minutes and no interactive
session open) or when the operator asks from the tray. A staged update older
than 7 days SHALL be re-verified before install. `--diagnose` SHALL report the
updater state (`disabled`, `checked <ts>`, `staged <version>`).

@trace spec:update-system

#### Scenario: Opt-out disables the timer
- **WHEN** `check_interval_hours = 0`
- **THEN** no network request for updates is made and `--diagnose` reports
  `updates: disabled`.
- Pre-fix result: FAILS — the field is never read.

#### Scenario: Busy stack defers the install
- **WHEN** a staged update exists and a lane was launched 2 minutes ago
- **THEN** the install is `deferred:busy` and is retried at the next idle
  check.
