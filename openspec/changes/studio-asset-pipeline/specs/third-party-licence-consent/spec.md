## ADDED Requirements

### Requirement: Accepting a third-party licence is signed and recorded in the project

Before an artefact whose licence is outside the permissive list is fetched, the user SHALL see the licence id and its restriction clauses quoted verbatim, and accept through an OS-verified signed approval. The acceptance SHALL be committed to the agreeing project as an acknowledgement record carrying the statement, the signature, the grantor, the time, the scope and the expiry.

#### Scenario: A non-commercial row is fetchable only after acknowledgement
- **WHEN** a request in a project names an artefact listed in the restricted register under a non-commercial licence
- **THEN** it is refused if the project holds no verifiable acknowledgement for that artefact, and admitted and fetched on the user's machine if it holds one

### Requirement: An accepted licence becomes an obligations spec in the agreeing project

Accepting a licence SHALL write an OpenSpec spec into the agreeing project, in the same signed commit as the acknowledgement. The spec states that the project depends on the artefact and must adhere to each obligation its licence carries: attribution with its required text, notice, share-alike, non-commercial, use-restriction passdown, field-of-use, seat or revenue thresholds, and no redistribution. Tillandsias records the obligations and does not enforce them.

#### Scenario: An attribution licence yields an attribution requirement
- **WHEN** a user accepts a licence that requires the attribution "CorridorKey"
- **THEN** the project gains `openspec/specs/third-party-licence-<id>/spec.md` with a requirement to show "CorridorKey", committed with the signed acknowledgement

### Requirement: Restricted weights are never redistributed

Tillandsias SHALL NOT bundle weights under a restricted licence in any image, release or shared cache it ships. Such weights are fetched only on the user's machine, after acknowledgement.

#### Scenario: No restricted weight is in a built image
- **WHEN** any Tillandsias image is built
- **THEN** no file listed in the restricted register is copied into it
