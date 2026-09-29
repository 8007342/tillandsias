## ADDED Requirements

### Requirement: the grounded expert endpoint can bind the mesh only behind a bearer

`tillandsias-plan expert-serve` SHALL accept `--bind <addr>` (default
`127.0.0.1`, unchanged) and `--bearer-file <path>`. A bind to any
non-loopback address without a bearer file SHALL be refused with
`refused:expert-serve:non-loopback-without-bearer`. With a bearer, every
request SHALL carry `Authorization: Bearer <value>` or be answered `401`
with a JSON body `{"error":"unauthorized"}`; loopback binds without a bearer
SHALL keep answering as today. The answer envelope SHALL be produced by the
same `run_grounded` call path as before (spec
`expert-serve-grounded-pipeline` R1 is unchanged).

#### Scenario: a mesh bind refuses to start naked

- **WHEN** `expert-serve --bind 100.96.0.7` runs without `--bearer-file`
- **THEN** it exits non-zero with `refused:expert-serve:non-loopback-without-bearer`

#### Scenario: a request without the bearer is 401

- **WHEN** `GET /v1/models` reaches a bearer-protected server without the
  header
- **THEN** the status is 401 and the body is `{"error":"unauthorized"}`

### Requirement: the hub serves and advertises FLEET EXPERTS

`tillandsias --fleet-experts serve` SHALL run `expert-serve` bound to this
host's Mesh IP from `secret/cloudflare/mesh.mesh_ip` on port 11436 with the
bearer at `secret/fleet/experts` (`bearer`, `hub_hostname`, `url`), minting
a 32-byte bearer on `--mint` and refusing to serve without one; it SHALL
advertise the Mesh hostname route `fleet-experts.tillandsias-vpn.internal`
for this node and refuse with `refused:fleet-experts:not-joined` when the
host has no Mesh IP.

#### Scenario: serve without a join is refused

- **WHEN** `--fleet-experts serve` runs on a host with no `secret/cloudflare/mesh`
- **THEN** it exits non-zero with `refused:fleet-experts:not-joined`

### Requirement: every forge can ask the fleet experts and knows which expert answered

The forge overlay SHALL carry a provider `tillandsias-fleet-experts` with
`baseURL` `http://fleet-experts.tillandsias-vpn.internal:11436/v1` and an
API key read from `secret/fleet/experts.bearer` at launch, beside the
existing `tillandsias-experts` provider, and the local-experts agent prompt
SHALL name which provider produced each relayed answer.
`tillandsias --fleet-experts status` SHALL resolve the route, call
`GET /v1/models` with the bearer and print `reachable:<url>:<index_digest>`
or `unreachable:<why>`; the tray SHALL show a `Fleet Experts:` row with
`reachable`, `unreachable` or `not configured`.

#### Scenario: status against a local bearer-protected server

- **WHEN** `--fleet-experts status` runs with the route resolved to a
  loopback test server that requires the stored bearer
- **THEN** it prints `reachable:` with that server's index digest

#### Scenario: a wrong bearer is unreachable with a reason

- **WHEN** the stored bearer differs from the server's
- **THEN** it prints `unreachable:unauthorized` and the tray row reads
  `unreachable`
