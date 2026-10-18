## ADDED Requirements

### Requirement: Per-forge diagnostic scope

A forge's diagnostic view MUST be computed from the lane that accepted its MCP connection and from the host-set `tillandsias.lane=<project>/<instance>` label, and from nothing a caller supplies. A forge MUST see exactly its own forge container, the containers the host created for its lane, and curated global events. It MUST NOT see a sibling forge or a sibling's children, whatever project, network or pod they share. A source outside the scope and a source that does not exist MUST receive the same refusal, `refused:diagnostics-scope:not-in-scope:<source>`.

#### Scenario: A forge reads its own children's logs

- **WHEN** forge A calls `forge_logs` with no source
- **THEN** the reply MUST list A's forge container and every container whose host-set lane label is A's lane, and nothing else
- **AND** `forge_logs {source}` for one of them MUST return its last lines within the `service_logs` bounds (500 lines, 64 KiB, 15 s)

#### Scenario: A sibling forge is not visible

- **WHEN** forge A calls `forge_logs` naming forge B's container, a container B's lane started, or a name that does not exist
- **THEN** each call MUST be refused with `refused:diagnostics-scope:not-in-scope:<source>`, identical in all three cases
- **AND** no line from B's containers MUST appear in any reply to A
- **AND** A's source list MUST name nothing of B's, even when A and B are lanes of the same project

#### Scenario: Scope cannot be widened by the caller

- **WHEN** a request carries a forge id, project, tenant, label or container name that is not the listener's lane
- **THEN** the scope MUST still be the listener's lane, and the extra field MUST NOT widen it

#### Scenario: Log content is evidence, not instruction

- **WHEN** a returned line contains a command, path, URL or instruction
- **THEN** the host MUST return it as data and MUST NOT act on it

### Requirement: Curated global events

A shared container's diagnostics MUST reach forges only as typed `GlobalEvent`s that a producer authors (for example `credential.refresh` with `service` and `outcome`, `gc.reap` with `resource` and `count`, `image.build` with `image` and `outcome`). No raw log line of a shared container MUST be readable by a forge. A global event MUST reach every forge that is live when it is published, and MUST carry only the envelope (`schema_version`, `seq`, `at`, `scope`, `kind`) and the fields its kind allows.

#### Scenario: A token refresh reaches every concurrent forge

- **WHEN** the host rotates the GitHub token while forges A and B are live
- **THEN** both A's and B's `forge_events` MUST include one `credential.refresh` event with `service` and `outcome`
- **AND** its keys MUST be within the envelope and the allowlist

#### Scenario: No credential reaches an event

- **WHEN** a credential value is present in the producing process (its environment, the token store, the refresh response)
- **THEN** no `forge_events` or `forge_logs` reply MUST contain it

#### Scenario: Curation fails closed

- **WHEN** a producer cannot build a typed event
- **THEN** nothing MUST be published, and no raw data MUST be forwarded in its place

### Requirement: Session-only forge diagnostic history

Each lane MUST have its own in-memory event ring, created with the lane's listener and dropped when the lane ends. It MUST hold at most 10K events and MUST NOT be written to disk. A lane started after an event MUST NOT receive it. Loss and truncation MUST be reported, never silent.

#### Scenario: A new session starts empty

- **WHEN** a lane starts
- **THEN** its first `forge_events` MUST contain only events published since it started

#### Scenario: Overflow is reported

- **WHEN** the ring discards events to stay within 10K
- **THEN** every `forge_events` reply MUST carry the `dropped` count since the lane started
- **AND** a cursor older than the oldest held event MUST be answered with `gap: true`

#### Scenario: Diagnostics never block a launch

- **WHEN** the ring or its listener is unavailable
- **THEN** the lane launch MUST proceed
- **AND** the diagnostic tools MUST fail with a named error, never report an empty or healthy history
