## ADDED Requirements

### Requirement: the coordinator serves the personal fleet only, through Cloudflare Access

The coordinator SHALL be reachable only through a Cloudflare Access application on the operator's account. The Worker SHALL verify the `Cf-Access-Jwt-Assertion` JWT on every request, against the team domain's public certificates and the application's AUD tag, and SHALL refuse any request whose JWT is missing or invalid. No secret SHALL be stored in the Worker's configuration. Hosts and forges SHALL authenticate with Access service tokens held only in the vault.

#### Scenario: an unauthenticated request

- **WHEN** a request without Access credentials reaches the coordinator
- **THEN** it is refused, and no Durable Object state is read or written

#### Scenario: a host token

- **WHEN** a host presents its vault-held service token
- **THEN** Access admits it, and the Worker accepts the JWT that Access forwards

### Requirement: the coordinator stores and returns without computing

The Worker and its single SQLite-backed Durable Object SHALL only store and return data: messages, overviews, freshness bumps and claim overlays. They SHALL NOT fold plan ledgers, call any model, or fetch anything except the Access certificates.

#### Scenario: an overview read

- **WHEN** a client reads a namespace's overview
- **THEN** the response is the stored overview, plus `synced_sha`, `synced_at`, `age_s` and `might_be_outdated`, with no server-side folding

### Requirement: git is the source of truth and the coordinator a warm cache

The forge that creates a project's queue SHALL push an initial overview it folded itself. After a successful upstream push to GitHub, the git mirror's post-receive hook SHALL send the new head SHA and a staleness bump, and optionally a refreshed overview. A failed coordinator call SHALL NOT affect the push. No GitHub webhook SHALL be used.

#### Scenario: after a push

- **WHEN** a push is relayed to GitHub through the mirror
- **THEN** within one minute a read of that namespace reports the new head SHA as `synced_sha`

#### Scenario: coordinator down during a push

- **WHEN** the coordinator is unreachable during a mirror push
- **THEN** the push succeeds, and the hook logs one line without the token

### Requirement: per-project namespaces are created on join and never listed

Joining a namespace that does not exist SHALL create it. An agent MAY subscribe to several namespaces: its project, declared related-project groups, and an opt-in global namespace. The coordinator SHALL expose no endpoint that lists, enumerates or publishes namespace names.

#### Scenario: first subscriber

- **WHEN** an agent joins `owner/new-project`, and no queue exists for it
- **THEN** the queue is created and the agent is subscribed

#### Scenario: no enumeration

- **WHEN** any client requests a list of namespaces
- **THEN** no route serves it

### Requirement: messages are best effort with a bounded TTL

Messages SHALL carry a TTL of 6 hours by default and at most 24 hours; a larger requested TTL SHALL be clamped. Expired messages SHALL NOT be returned. The coordinator SHALL issue no read receipts and SHALL make no delivery guarantee.

#### Scenario: an expired message

- **WHEN** a message's TTL has passed
- **THEN** no receive returns it

### Requirement: clients call on demand with an adaptive heartbeat and limits

The client SHALL call the coordinator only:

- at forge start;
- after a push;
- when seeking work;
- on a heartbeat.

The heartbeat interval SHALL be self-measured and never exceed 120 seconds. It SHALL back off while the host is busy, and SHALL emit nothing while a gate or an agent turn is in progress. The client SHALL apply a local rate limit, the server SHALL answer 429 past its own limit, and a batch endpoint SHALL let one client turn send one request. When the coordinator is unreachable or rate-limited, the client SHALL answer from the local git ledger and mark the answer `source: git-ledger`.

#### Scenario: during a gate

- **WHEN** a build.sh gate holds the lane marker
- **THEN** no heartbeat request is sent until the marker is released

#### Scenario: offline

- **WHEN** the coordinator cannot be reached and an agent asks what's next
- **THEN** the answer comes from the local fold and is marked `source: git-ledger`

### Requirement: short-TTL claim overlays hide claimed rows fleet-wide

A client SHALL be able to place a claim overlay on a ready row in a namespace, with a short TTL. While the overlay is live, `next` on every client in that namespace SHALL omit the row. An expired overlay SHALL vanish. Overlays SHALL NOT replace the git claim, which still flips the row's status.

#### Scenario: two hosts seek work

- **WHEN** host A places an overlay on a row, and host B asks for the next work within seconds
- **THEN** host B is not offered that row
