## ADDED Requirements

### Requirement: Single Tillandsias root per host

Every file or directory Tillandsias creates on a host, directly or through
podman, a VM, or WSL on its behalf, SHALL live under one Tillandsias root,
except the exempt list: installed binaries and launcher entries, volatile
runtime files under the session runtime directory (tmpfs), and opt-in
privileged system integration (the swap file) that has its own removal list.
The root SHALL be the most contained per-user location the platform allows,
and SHALL be overridable with `TILLANDSIAS_HOME`.

#### Scenario: init writes nothing outside the root

- **GIVEN** a host user with no Tillandsias state and `TILLANDSIAS_HOME` unset
- **WHEN** `tillandsias --init` completes and a forge is launched and removed
- **THEN** every path created by Tillandsias is under the root or on the exempt list
- **AND** `~/.cache/tillandsias`, `~/.local/state/tillandsias` and `~/.config/tillandsias` do not exist

#### Scenario: deleting the root resets the host

- **GIVEN** Tillandsias is stopped
- **WHEN** the user deletes the root directory
- **THEN** the next launch provisions from a pristine state with no error and no leftover podman volumes or images attributable to Tillandsias

### Requirement: Linux root layout

On Linux the root SHALL be `${TILLANDSIAS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/tillandsias}`
with subtrees `config/`, `state/`, `logs/`, `cache/` (carrying a `CACHEDIR.TAG`),
`podman/` (graphroot and volume path for all Tillandsias containers),
`forges/<lane>/` and `projects/<project>/`. The user's own podman configuration
SHALL NOT be modified.

#### Scenario: podman storage is scoped to the root

- **WHEN** Tillandsias creates a forge container or volume
- **THEN** its storage resolves under `<root>/podman`
- **AND** `~/.local/share/containers/storage` gains no Tillandsias volume

### Requirement: Storage is discoverable

The tray SHALL offer an "Open storage folder" action and a storage report
listing each root subtree with its size.

#### Scenario: storage report

- **WHEN** the user opens the storage report
- **THEN** each subtree and its size is listed, with the total
