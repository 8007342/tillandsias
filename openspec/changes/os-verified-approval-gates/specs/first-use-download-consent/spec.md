## ADDED Requirements

### Requirement: large first-use downloads are approved in an informed window

Before a first-use download larger than a threshold (default 1 GB), the tray
SHALL show a window stating the download size, a storage bar and Tillandsias'
share, and SHALL start the download only after the operator approves it.

#### Scenario: the size is stated before anything downloads

- **WHEN** a first launch needs about 5.5 GB
- **THEN** the window says it will download about 5.5 GB, and nothing is
  fetched until Approve

### Requirement: the storage bar uses the OS's own figures

The storage bar SHALL show used and free space from OS APIs (macOS volume
resource values including purgeable space, Windows `GetDiskFreeSpaceExW`,
Linux `statvfs`), SHALL split out the operating system, apps and backups only
where the platform reports them, and SHALL fold anything unmeasured into
"Other" rather than estimate it.

#### Scenario: an unmeasurable segment is not guessed

- **WHEN** the platform does not report backup size
- **THEN** no backups segment is drawn

### Requirement: Tillandsias' share comes from the download manifest

Tillandsias' share SHALL be read from the download manifest specified in PR
#650's change, split into needed items (forge and web images) and removable
items (models and caches, deleted and recreated on demand), each with its
size.

#### Scenario: removable items are labelled as such

- **WHEN** the manifest lists a model as removable
- **THEN** the window shows it under removable with its size and says it is
  downloaded again when needed
