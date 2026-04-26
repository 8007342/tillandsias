## ADDED Requirements

### Requirement: Control socket joins the managed-IPC class

The system SHALL treat the tray-host control socket at
`$XDG_RUNTIME_DIR/tillandsias/control.sock` (or `/tmp/tillandsias-$UID/control.sock`
fallback) as a managed credential-adjacent transport: it carries secret
material (per-window OTPs, future session bootstraps) between the tray and
bind-mounted consumer containers. The handling rules below MUST mirror the
`secrets-management` discipline already enforced for GitHub tokens.

1. **Loopback only.** The socket SHALL be a Unix-domain `SOCK_STREAM` node on
   the local filesystem. It MUST NOT be exposed via TCP, abstract namespace,
   D-Bus, or any cross-host transport. The kernel-enforced filesystem
   permission (`0600` on the node, `0700` on the parent directory) is the
   sole authentication mechanism.
2. **Never at rest.** Frame payloads SHALL exist only in process memory (tray,
   accepted-connection task buffers, consumer client buffers). Frames MUST
   NOT be written to disk, persisted to logs in cleartext, or copied into
   any cache directory. Postcard envelopes that carry secret material (e.g.,
   `IssueWebSession.cookie_value`) SHALL be redacted in any debug or
   accountability log.
3. **Lifetime bounded by tray lifetime.** The socket node SHALL exist only
   while the tray is running: bound at startup, unlinked at graceful
   shutdown, replaced at next-start stale-recovery if the tray crashed. No
   long-lived socket file SHALL persist across tray-down windows.
4. **Bind-mount surface is opt-in per container.** Containers SHALL receive
   the bind-mount only when their profile declares `mount_control_socket =
   true`. Forge containers SHALL default to `false`. The default-deny posture
   prevents a compromised forge from sending any control message — the same
   reasoning that keeps GitHub tokens off the forge.

@trace spec:secrets-management, spec:tray-host-control-socket

#### Scenario: Socket node permissions enforced at the OS layer

- **WHEN** the tray binds the control socket
- **THEN** the parent directory SHALL be mode `0700` and owned by the tray
  user
- **AND** the socket node SHALL be mode `0600` after the chmod step between
  `bind()` and `listen()`
- **AND** a `connect(2)` from a different UID SHALL fail with `EACCES` at
  the kernel layer, with no application code reached

#### Scenario: Frame contents redacted in accountability log

- **WHEN** the tray dispatches an `IssueWebSession { project_label, cookie_value }`
  frame to a consumer
- **THEN** the accountability log entry SHALL record
  `category = "secrets"`, `spec = "tray-host-control-socket"`, the
  `project_label`, and the `from` of the connected consumer
- **AND** the `cookie_value` field SHALL be absent from the log (replaced by
  `<redacted, 32 bytes>` or similar fixed-width sentinel)
- **AND** no debug-level log entry SHALL emit the cookie value either

#### Scenario: Forge container cannot reach the control socket by default

- **WHEN** an attacker who has compromised a forge container attempts to
  send any `ControlMessage` variant
- **THEN** `connect(2)` to `/run/host/tillandsias/control.sock` SHALL fail
  with `ENOENT` because the bind-mount is absent under the default forge
  profile
- **AND** the forge SHALL have no other channel to reach the tray's control
  plane (no TCP listener, no D-Bus access)

#### Scenario: Tray restart drops in-flight secret material

- **WHEN** the tray exits while a consumer holds an open connection mid-frame
- **THEN** the kernel SHALL close the connection on tray exit, dropping any
  buffered frame the tray had not yet read
- **AND** the consumer SHALL treat the disconnect as the cancellation of
  in-flight secret-bearing operations (no retry of the same `seq` against
  the new tray instance — the consumer SHALL re-handshake and re-issue
  fresh secrets)
- **AND** stale per-connection state (sequence numbers, pending acks) SHALL
  NOT survive the disconnect

## Sources of Truth

- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — the socket
  and its frames live exclusively in the ephemeral path category; no
  cross-project leakage; no persistent residue.
- `cheatsheets/security/owasp-top-10-2021.md` — A01 (access control) and
  A09 (logging failures) shape the `0600` permission gate and the cleartext-
  redaction rule for the accountability log.
- `cheatsheets/runtime/networking.md` — confirms Unix socket connect
  permission is enforced by the kernel against the file mode; no app-layer
  authentication is needed.
