## MODIFIED Requirements

### Requirement: Token Rotation and Expiration Management

GitHub App user-to-server access tokens expire after 8 hours. The system MUST persist and manage refresh tokens in Vault, supporting automatic and explicit token rotation. Automatic rotation MUST be RUN by the resident process that holds this installation's Vault, not only specified.

@trace spec:gh-auth-script, spec:secret-rotation, spec:tillandsias-vault, order:1461-8tyy

#### Scenario: Refresh token rotation
- **WHEN** an access token nears expiration (within 30 minutes) or has expired
- **AND** a valid refresh token exists in Vault
- **THEN** the system MUST exchange the refresh token at `https://github.com/login/oauth/access_token` for a new access token and rotated refresh token
- **AND** the rotation MUST hold an exclusive lock from reading the stored refresh token until the new pair is written (refresh tokens are single-use)
- **AND** the rotated refresh token MUST be written to `secret/github/refresh` BEFORE the new access token is written to `secret/github/token`, and a failed write MUST leave the previous records intact
- **AND** an accountability audit event MUST be recorded under `spec:secret-rotation`

#### Scenario: Explicit refresh is an operator action
- **WHEN** `tillandsias --refresh-github-token` runs without a desktop session
- **THEN** it MUST refuse with a non-zero exit and record the audit event
- **AND** when Vault holds no refresh token (or no token), the command MUST exit non-zero rather than report success

#### Scenario: The resident process rotates on a schedule
- **WHEN** the Linux tray starts, or the guest's resident service starts on macOS or Windows
- **THEN** it MUST run a due-check at start and at least every 15 minutes
- **AND** the due-check MUST take the exclusive rotation lock BEFORE reading the stored bundle and decide under it, so two concurrent due-checks exchange the single-use refresh token exactly once
- **AND** it MUST exchange only when `expires_at - now <= 30 minutes`, and otherwise report `ok:github-token-rotation:not-due` without contacting GitHub
- **AND** each rotation and each failed rotation MUST record the accountability audit event with operation `github_token_auto_rotation`

#### Scenario: Automatic rotation needs no desktop session and never runs in a forge
- **WHEN** the due-check runs
- **THEN** it MUST NOT consult the desktop-session gate, which stays on the explicit `--refresh-github-token` only
- **AND** inside a forge (`TILLANDSIAS_HOST_KIND=forge`) it MUST refuse with `skip:github-token-rotation:forge` without reading or writing the store

#### Scenario: A failed rotation is named and retried
- **WHEN** GitHub rejects the refresh token, or Vault cannot be read or written
- **THEN** the previous records MUST stay intact and the failure MUST be reported as `blocked:github-token-rotation-failed:<reason>`, with no token or response body in the reason
- **AND** the scheduler MUST retry with a backoff that starts at 1 minute, doubles, and never exceeds the 15-minute interval
