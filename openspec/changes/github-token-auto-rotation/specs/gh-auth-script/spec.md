## MODIFIED Requirements

### Requirement: Token Rotation and Expiration Management
GitHub App user-to-server access tokens expire after 8 hours. The system MUST
persist refresh tokens in Vault and MUST rotate the access token AUTOMATICALLY
before it expires, without operator action, for as long as the refresh token is
valid. Explicit rotation remains an operator action.

#### Scenario: Refresh token rotation
- **WHEN** an access token nears expiration (within 30 minutes) or has expired
- **AND** a valid refresh token exists in Vault
- **THEN** the system MUST exchange the refresh token at `https://github.com/login/oauth/access_token` for a new access token and rotated refresh token
- **AND** the rotation MUST hold an exclusive lock from reading the stored refresh token until the new pair is written (refresh tokens are single-use)
- **AND** the rotated refresh token MUST be written to `secret/github/refresh` BEFORE the new access token is written to `secret/github/token`, and a failed write MUST leave the previous records intact
- **AND** an accountability audit event MUST be recorded

#### Scenario: Explicit refresh is an operator action
- **WHEN** `tillandsias --refresh-github-token` runs without a desktop session
- **THEN** it MUST refuse with a non-zero exit and record the audit event
- **AND** when Vault holds no refresh token (or no token), the command MUST exit non-zero rather than report success

## ADDED Requirements

### Requirement: A resident due-check keeps the token alive
The resident process that holds the installation's Vault client (the Linux
tray; the guest's resident service on macOS and Windows) MUST run a rotation
due-check at start and at least every 15 minutes, and MUST rotate through the
locked exchange when the access token is within 30 minutes of `expires_at`.
The due-check MUST NOT require a desktop session, and MUST NOT run inside a
forge.

#### Scenario: A token issued eight hours ago is still usable
- **WHEN** the access token's `expires_at` is 20 minutes away and the resident process is running
- **THEN** within one due-check interval Vault holds a new access token whose `expires_at` is later than the old one, with no operator action

#### Scenario: Two due-checks on one host spend the refresh token once
- **WHEN** two due-checks fire concurrently on one host
- **THEN** exactly one exchange reaches GitHub and the other observes the rotated pair

#### Scenario: A token that is not due is left alone
- **WHEN** the access token has more than 30 minutes left
- **THEN** the due-check makes no exchange

### Requirement: Consumers read the token at use time
Every consumer of `secret/github/token` (the git mirror's upstream push, the
credential helper) MUST read it at the moment of use and MUST NOT cache it past
its `expires_at`, so a rotation reaches the next use without a restart.

#### Scenario: A push after a rotation uses the new token
- **WHEN** the token rotates while the mirror is running
- **THEN** the mirror's next upstream push authenticates with the new token

### Requirement: Rotation failure and refresh expiry are named, not silent
A failed rotation MUST retry with backoff until the access token expires; the
credential verdict MUST then name the cause
(`blocked:github-token-rotation-failed:<reason>`). Fourteen days before
`refresh_token_expires_at` the tray MUST tell the operator to run
`tillandsias --github-login`.

#### Scenario: A rejected refresh token is named
- **WHEN** GitHub rejects the refresh token
- **THEN** the previous records stay intact and the credential verdict names `github-token-rotation-failed`, with the login remedy
