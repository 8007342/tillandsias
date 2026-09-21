## REMOVED Requirements

### Requirement: Host filesystem scanner enumerates `~/src/` projects
**Reason**: the tray's project list is the remote list only; no local project
events feed it, and the host's source tree is not the tray's concern.
**Migration**: T6 removes the watcher and `LocalProjectEvent`; the remote list
(tray-ux) is the single source of projects.
