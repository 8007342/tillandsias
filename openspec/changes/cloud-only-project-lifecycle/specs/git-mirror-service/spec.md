## ADDED Requirements

### Requirement: Exported heads track upstream on demand and on a cadence
The mirror SHALL fast-forward its exported `refs/heads/*` to the corresponding
`refs/remotes/origin/*` (a) when asked — `tillandsias --sync <project>` and a
tray action — and (b) on a cadence the mirror reports, and SHALL NEVER move an
exported head that is not a strict ancestor of upstream (a locally stranded
commit is forwarded by the relay's retry, never reset). The mirror SHALL expose
a sync state readable from inside a forge: the last sync time, the cadence, and
for a named ref one of `current`, `behind-upstream:<sha>` or `absent-upstream`.

@trace spec:git-mirror-service

#### Scenario: A ref pushed to GitHub becomes seedable inside the enclave
- **WHEN** a bare-metal host pushes `work/<order>` to GitHub without passing
  through this mirror
- **AND** a forge asks the mirror to sync, or the cadence elapses
- **THEN** the mirror's `refs/heads/work/<order>` SHALL equal GitHub's
- **AND** a forge seeded from that ref SHALL check it out

#### Scenario: A forge can tell "behind" from "absent"
- **WHEN** a forge asks the sync state for a ref that exists upstream but has
  not reached the mirror
- **THEN** the answer SHALL be `behind-upstream:<sha>`, never a bare failure
  to resolve
- **AND** for a ref that exists nowhere the answer SHALL be `absent-upstream`

### Requirement: The relay records the pusher
For every ref transaction the pre-receive relay SHALL log the certificate
principal, serial and key id it received from `tillandsias-receive`, so a host
push and a forge push through the same lane are distinguishable after the fact.

@trace spec:git-mirror-service

#### Scenario: Two client classes, one lane, one log
- **WHEN** a host (`til:host-push:<host>`) and a forge (`til:forge-push:<mid>`)
  each push one ref through the same mirror
- **THEN** the accountability log SHALL carry one line per transaction naming
  the principal, serial and key id
- **AND** a renewed certificate SHALL show a different serial on its first push

## REMOVED Requirements

### Requirement: Mirror → host working-copy auto-sync on push
**Reason**: there is no host working copy the tray owns; a project exists for
Tillandsias only as a remote repository and its mirror. The user's own clones on
the host are theirs.
**Migration**: none for the mirror; T6 removes the watcher and the fast-forward.

### Requirement: Mirror sync never clobbers user work
**Reason**: with no tray-driven sync into a host working copy the protection has
no subject; the reconcile rule for the mirror itself (upstream never clobbers
exported refs) stands unchanged.
**Migration**: none.
