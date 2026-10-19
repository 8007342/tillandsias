## ADDED Requirements

### Requirement: Reaps are announced as curated global events

Every sweep that stops at least one container MUST publish one `gc.reap`
`GlobalEvent` per class it reaped, carrying only the envelope and the
allowlisted fields `resource` (the class), `count` and `reason`, to every
lane live at that moment. The owning lane's ring MUST additionally receive a
scoped `container.reaped` event with `name`, `class`, `idle_secs`,
`budget_secs` and `relaunch`. No sibling MUST learn a reaped container's
name through the global event. Until the typed `GlobalEvent` exists
(1779-sq9g), the reaper MUST emit its verdict as a `runtime-logging`
container stop event with `reason=idle`, and nothing else.

> Delta: the GC paths used `eprintln!`; `forge-diagnostics-scope` names
> `gc.reap` but nothing produced it.

#### Scenario: Two forges, one reap
- **WHEN** forge A's preview is reaped while forges A and B are live
- **THEN** both `forge_events` contain one `gc.reap` with `resource: "preview"` and `count: 1`
- **AND** only A's `forge_events` contains `container.reaped` naming the preview

#### Scenario: Curation fails closed for a reap
- **WHEN** the reaper cannot build a typed event
- **THEN** the container is still stopped and only the verdict line is logged
