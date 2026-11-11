## ADDED Requirements

### Requirement: the gateway is a small standalone binary

The provider gateway SHALL be one standalone binary per host or per forge
network, written in Rust or Go, with no bash, python or jq on its path. It SHALL
ship with a one-page "how it works" readme and a threat model.

#### Scenario: the docs sit beside the source

- **WHEN** the gateway source is built
- **THEN** a README.md and a THREAT-MODEL.md sit in its directory, and the readme names every listener, upstream and Vault path

### Requirement: one upstream per provider

Each enabled provider SHALL map to exactly one upstream URL. A provider SHALL be
enabled only after its spike recorded "yes".

#### Scenario: an unknown path is refused

- **WHEN** a request matches no enabled provider
- **THEN** the gateway answers 404 and contacts no upstream

### Requirement: reachable only from the forges it serves

The gateway SHALL listen only on the forge network address, or on a socket
mounted into the forge it serves. The peer identity SHALL be the network or
socket a request arrives on. It SHALL NOT expose an admin, metrics or debug API.

#### Scenario: a loopback or wildcard configuration is refused

- **WHEN** the configuration names 0.0.0.0, a host loopback address or a published port
- **THEN** the gateway exits at start with a named error

#### Scenario: another forge cannot connect

- **WHEN** a forge on another network connects to the listener
- **THEN** no connection is established

### Requirement: the forge holds only a placeholder

The forge SHALL receive a placeholder credential and a base URL, never the
provider sign-in file. The gateway SHALL replace the incoming credential header
with the real token.

#### Scenario: the placeholder is swapped

- **WHEN** a forge request carries the placeholder
- **THEN** the upstream receives the real token, and the response to the forge holds no token bytes

### Requirement: small cached Vault reads and serialized refresh

The gateway's only Vault interaction SHALL be reading the provider sign-in and
writing back a refreshed one. The token SHALL be cached in memory with a TTL and
never written to disk. Refresh SHALL be serialized per provider.

#### Scenario: a concurrent expiry triggers one refresh

- **WHEN** ten requests arrive after the token expired
- **THEN** exactly one refresh call reaches the provider and one write reaches Vault

#### Scenario: no sign-in means no flow

- **WHEN** Vault holds no sign-in for the provider
- **THEN** the gateway answers with a fixed message telling the user to sign in from the tray, and never starts a sign-in

### Requirement: no header or body logging

The gateway SHALL NOT log request or response headers or bodies. Its log holds
the time, provider, status and duration of each request, and the outcome of each
refresh.

#### Scenario: a token never reaches the log

- **WHEN** a request with a known placeholder and a known real token passes through
- **THEN** neither string appears in the log output
