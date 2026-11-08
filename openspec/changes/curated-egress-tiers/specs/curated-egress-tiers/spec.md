## ADDED Requirements

### Requirement: every container declares its egress tiers and gets nothing else

Every image and studio SHALL declare its egress tiers. Each tier SHALL be one
of `none`, `siblings`, `host`, `registries`, `assets`, `providers`,
`model-hubs`, `vcs`, or `research`. A container SHALL reach only what its
declared tiers allow. A missing declaration SHALL mean `none`.

#### Scenario: an undeclared image

- **WHEN** a container is launched from an image with no egress declaration
- **THEN** it gets an internal network and no proxy environment, and every outbound connection fails

#### Scenario: a web studio reaches a font CDN

- **WHEN** a web studio declared `[siblings, assets]` requests fonts.googleapis.com
- **THEN** the proxy splices the connection, and a request from it to pypi.org is refused

### Requirement: the proxy enforces tiers per source without decrypting

The proxy SHALL decide each connection by the requesting container's tier set
and the TLS SNI. It SHALL splice allowed connections without decrypting them,
except for the existing narrow release-asset bump. It SHALL refuse any
connection whose destination does not match the SNI's resolution. It SHALL log
the client, the tier set, the SNI and the verdict.

#### Scenario: a forged SNI

- **WHEN** a client sends an allowed SNI with a CONNECT target that resolves elsewhere
- **THEN** the proxy refuses the connection and logs `refused:egress:sni-mismatch`

### Requirement: agents read the web through a curated fetch and search service

The enclave SHALL offer agents `search`, `fetch`, `feed` and `docs` through an
MCP service. That service SHALL:

- fetch only catalog sources, or URLs returned by a search in the same
  session;
- refuse private, loopback and metadata addresses after resolving them;
- obey robots.txt;
- send no cookies or credentials;
- rate-limit each client;
- write an audit record for every request.

The search key SHALL stay in Vault and never enter an agent's container.

#### Scenario: an agent reads documentation that is not on any proxy list

- **WHEN** an agent in a forge searches for a library's docs and fetches a result URL
- **THEN** it receives the page as Markdown, and an audit record names the forge, the URL and the verdict

#### Scenario: a fetch of an internal address

- **WHEN** an agent asks to fetch a URL that resolves to a private or metadata address
- **THEN** the service refuses it without connecting

### Requirement: unknown destinations are denied and offered for approval, never auto-allowed

A request for a destination outside the container's tiers SHALL be refused.
It SHALL also be queued in the tray as "<container> asked for <host>".
Approving it for the session or adding it to a tier SHALL record who approved
it, when, and why.

#### Scenario: an approval

- **WHEN** the operator adds a queued host to the `assets` tier
- **THEN** a tier entry with provenance is written, and the next request from any `assets` container is spliced

### Requirement: migration preserves today's reach until each container cuts over

Until every container has its own declaration, the union of the tier files
SHALL equal the previous allowlist. The strict port SHALL keep serving that
union.

#### Scenario: the split

- **WHEN** allowlist.txt is split into tier files
- **THEN** a check passes only if the union of the tier files equals the previous list
