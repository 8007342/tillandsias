## ADDED Requirements

### Requirement: every research packet closes on a named outcome token

Each Coding Expert research packet SHALL declare, before its measurement
runs, a closed vocabulary of outcome tokens, and SHALL close only when its
script's last stdout line is `outcome:<token>` from that vocabulary with the
regime (host, tool versions, mirror commit) on the preceding lines. Prose
without the token SHALL NOT close a packet.

#### Scenario: a measurement without its token stays open

- **WHEN** a packet's record carries conclusions but no `outcome:` line
- **THEN** `tillandsias-plan closure-evidence-check` for that packet reports
  the missing token

### Requirement: the one-time surface prototype is minted by sandboxed Lua

The prototype mint SHALL be a Lua script run under the sandboxed
`tillandsias-plan lua` runtime with no `proc.run` and no write verbs, taking
a request table (`file`, `function`, `intent`) and returning a surface table
with `nonce`, `expires_at`, an input schema narrowed to that file and
function, and `affordances` (allowed paths, allowed symbols, max bytes,
required tests). The same request minted twice SHALL yield different nonces
and identical affordances.

#### Scenario: two mints of one request differ only in nonce and expiry

- **WHEN** `mint.lua` runs twice on the same request fixture
- **THEN** the two surfaces are equal after removing `nonce` and
  `expires_at`, and the two nonces differ

#### Scenario: a request escaping the repository is refused

- **WHEN** the request's `file` is `../etc/passwd`
- **THEN** the mint returns `refused:coding-expert:path-escape` and no
  surface

### Requirement: the corpus is the mirror at a named commit plus eager cheatsheets

The research index for the `coding` domain SHALL be built from the project's
git mirror at its integration HEAD, recording that commit in the index
entry's freshness frame, and SHALL eagerly load the cheatsheets for the
technologies detected in the project through the license allowlist. The
packet SHALL record index size, build time, and a 20-question hit rate on
one fat-tier and one floor-tier host.

#### Scenario: the index names its commit

- **WHEN** the research index is built
- **THEN** its freshness frame carries the mirror commit and the list of
  eagerly loaded cheatsheet ids

### Requirement: the expert is one more domain on the existing endpoint

The research prototype SHALL expose the Coding Expert as a `run_grounded`
domain named `coding` on the existing `expert-serve` endpoint, reachable as
`tillandsias-experts/coding` locally and `tillandsias-fleet-experts/coding`
over the fleet, and SHALL NOT introduce a second serving process.

#### Scenario: local and fleet answer from the same call path

- **WHEN** the same minted surface is sent to the local and the fleet
  endpoint
- **THEN** both envelopes carry the same index digest and the same
  citation set

### Requirement: the threat table precedes implementation

The security packet SHALL deliver a table with one row per threat (replay,
widening, path escape, unsolicited signing, cross-project impersonation,
chunk injection), each naming the test an implementation must pass, and a
recorded decision between an HMAC-keyed nonce with the key in Vault and a
memory-resident random nonce. No implementation packet SHALL be filed
without `depends_on` naming this packet.

#### Scenario: a replayed surface is refused by the prototype verifier

- **WHEN** a surface's nonce is presented twice to the prototype verifier
- **THEN** the second presentation returns `refused:coding-expert:nonce-spent`
