## ADDED Requirements

### Requirement: Cloudflare login is Authorization Code with PKCE and never a device grant

`tillandsias --cloudflare-login` SHALL authenticate with Cloudflare's OAuth
Authorization Code grant using PKCE with `code_challenge_method=S256`, a
`state` of at least 32 random bytes, and a public client (`token_endpoint_auth_method`
`none`; no client secret exists in the binary or in Vault). The PKCE
verifier SHALL never be written to disk, logged, encoded in a QR code or
sent anywhere but the token endpoint. The authorize and token endpoints
SHALL be read from `TILLANDSIAS_CLOUDFLARE_BASE_URL` (default
`https://dash.cloudflare.com`) so a fixture can substitute a fake server; the
client id SHALL be the public constant `CLOUDFLARE_APP_CLIENT_ID`,
overridable by `TILLANDSIAS_CLOUDFLARE_CLIENT_ID`. At login the command SHALL
read the OpenID discovery document and, if `grant_types_supported` lists
`urn:ietf:params:oauth:grant-type:device_code`, print
`note:cloudflare-login:device-grant-available` and continue with the code
grant.

#### Scenario: a state mismatch is refused before any exchange

- **WHEN** the redirect carries a `state` that differs from the one minted
  for this login
- **THEN** the command exits non-zero with `refused:cloudflare-login:state-mismatch`
- **AND** the fake server's ledger shows no request to the token endpoint

#### Scenario: the device grant is announced when it exists

- **WHEN** the fake discovery document lists the device grant
- **THEN** the login prints `note:cloudflare-login:device-grant-available`
  and still completes through the code grant

### Requirement: the redirect has three receivers and the QR one is honest about its relay

The login SHALL accept `--via loopback|qr|paste`. `loopback` SHALL listen on
`127.0.0.1` on the first free port of the registered set (48631, 48632,
48633) at path `/tillandsias/cloudflare/callback`, open the operator's
browser on the authorize URL, accept exactly one redirect, and refuse
(`refused:cloudflare-login:no-registered-port-free`) when none is free.
`qr` SHALL render the authorize URL, whose `redirect_uri` is the operator's
relay page, as a terminal QR through the existing renderer, print the same
URL as text, and then wait for the code by paste, or by polling
`TILLANDSIAS_CLOUDFLARE_RELAY_POLL_URL` when set, for at most five minutes.
`paste` SHALL read one code line from a terminal stdin and refuse without a
terminal, in the words of the GitHub `--with-token` refusal. When no relay
URL is configured, `--via qr` SHALL refuse with
`refused:cloudflare-login:no-relay-configured` and name the two other
receivers. The default receiver SHALL be `loopback` when a desktop session
and a browser opener exist, else `qr` when a relay is configured, else
`paste`.

#### Scenario: loopback completes against the fake

- **WHEN** `--cloudflare-login --via loopback` runs with the fake's
  `?auto=approve` consent
- **THEN** the command prints `ok:cloudflare-login:stored`
- **AND** Vault holds `secret/cloudflare/token` and `secret/cloudflare/refresh`

#### Scenario: the QR never encodes a secret

- **WHEN** `--cloudflare-login --via qr` renders its QR
- **THEN** decoding the QR yields the authorize URL and nothing else
- **AND** that URL contains `code_challenge` and `state` and does not
  contain the verifier, a token or a client secret

#### Scenario: denied consent is a named refusal

- **WHEN** the fake answers the consent with `error=access_denied`
- **THEN** the command exits non-zero with `refused:cloudflare-login:access-denied`
- **AND** nothing is written to Vault

### Requirement: the credential lives at two Vault paths and rotates itself

The bundle SHALL be stored as `secret/cloudflare/token` (`access_token`,
`expires_at` when `expires_in` was reported, `account_id`, `client_id`) and
`secret/cloudflare/refresh` (`refresh_token`, `refresh_token_expires_at`
when reported, `client_id`), the refresh record written first so a failed
token write leaves the previous bundle intact. Only the host's resident
process policy SHALL read the refresh path; no forge policy SHALL read
either path. A resident due-check (`spawn_cloudflare_token_rotation_scheduler`)
SHALL run from the Linux tray at start, from every lane launch and from the
guest listener, and rotate under an exclusive lock when
`expires_at - now <= 30 min`; a failure SHALL be recorded as
`blocked:cloudflare-token-rotation-failed:<reason>` and retried with
backoff. A forge SHALL never rotate. `tillandsias --cloudflare-logout` SHALL
revoke best-effort, delete both records and leave `secret/cloudflare/mesh`
untouched.

#### Scenario: due-check rotates exactly once under concurrency

- **WHEN** `expires_at = now + 20 min` and two due-checks run concurrently
  against the fake
- **THEN** the fake's ledger shows exactly one `grant_type=refresh_token`
  exchange and the stored `expires_at` is later than before

#### Scenario: removing any entry point is caught

- **WHEN** any one of the three scheduler call sites is removed from the
  source
- **THEN** `scripts/test-cloudflare-token-rotation.sh` fails naming that
  call site

#### Scenario: logout keeps the mesh credential

- **WHEN** `--cloudflare-logout` runs on a joined host
- **THEN** `secret/cloudflare/token` and `secret/cloudflare/refresh` are
  absent and `secret/cloudflare/mesh` is unchanged

### Requirement: every fixture runs against a fake Cloudflare

A test binary `tillandsias-fake-cloudflare` SHALL serve the OpenID
discovery document, `/oauth2/auth`, `/oauth2/token`, `/oauth2/revoke`,
`/oauth2/userinfo` and the `api.cloudflare.com` routes the fleet-vpn
bootstrap calls, on `127.0.0.1:0`, printing its port, and SHALL record every
call in a JSON ledger. The token endpoint SHALL enforce PKCE (`S256`),
single-use codes and refresh-token rotation, so a login test that passes
against the fake would pass the same checks Cloudflare documents. No gate,
fixture or litmus SHALL require the real OAuth client.

#### Scenario: a wrong verifier is refused by the fake

- **WHEN** a token request carries a `code_verifier` whose S256 digest is
  not the stored `code_challenge`
- **THEN** the fake answers `400 invalid_grant` and the ledger records it

#### Scenario: a code is single-use

- **WHEN** the same authorization code is exchanged twice
- **THEN** the second exchange answers `400 invalid_grant`
