## ADDED Requirements

### Requirement: the window offers four approval scopes per action

The approval window SHALL offer Approve this time, Approve for 10 minutes,
Approve for 2 hours and Approve this session, plus Not now. A grant SHALL cover
one action class and one target only. A request covered by a valid grant SHALL
proceed without a prompt.

#### Scenario: a 10-minute grant covers only its target

- **WHEN** the operator approves a workflow dispatch on `release.yml@main`
  for 10 minutes
- **THEN** a second dispatch of the same workflow within 10 minutes shows no
  prompt, and a dispatch of a different workflow does

#### Scenario: a once grant is consumed

- **WHEN** a grant scoped `once` has been used
- **THEN** the next identical request prompts again

### Requirement: every grant is bound to one forge instance

Each grant SHALL carry `forge_instance`: the agent, the project, the launch
timestamp and an instance id unique to that forge launch. A verifier SHALL
refuse a grant presented by any other forge instance, even one with the same
agent, project and target. A `session` grant SHALL expire when its forge
instance stops. Grants wider than one forge instance are not offered (operator
ruling 2026-10-26).

#### Scenario: a second forge does not inherit a grant

- **WHEN** the operator approves a workflow dispatch for 2 hours in one forge,
  and a second forge on the same project with the same agent requests the same
  dispatch
- **THEN** the second forge is prompted, and its approval is a separate grant

#### Scenario: a session grant ends with its forge

- **WHEN** a forge holding a `session` grant stops, and a new forge on the same
  project requests the same action
- **THEN** the request is prompted again

### Requirement: the window names the forge its approvals apply to

The approval window SHALL show `<Agent>/<Project>/Launched at <YYYY-MM-DD HH:MM>`
and the line "Approvals here apply only to this forge."

#### Scenario: the metadata line is shown

- **WHEN** the window opens for a request from a forge
- **THEN** it shows that forge's agent, project and launch time, and the scope line

### Requirement: grants are signed statements stored in Vault

Each grant SHALL be a statement signed by the device key, naming action,
target, scope, forge instance, issued time and expiry (standing grants have none), stored in a
Vault KV path. Only the approval broker SHALL be able to write it. Only the
git-mirror hook, the MCP gate and release tooling SHALL be able to read it,
with the Vault audit device enabled.

#### Scenario: a grant written into Vault without a valid signature is ignored

- **WHEN** a grant record with a bad or missing signature is placed in Vault
- **THEN** every verifier treats the action as ungranted and asks again

#### Scenario: an agent cannot write a grant

- **WHEN** a forge-held or agent-held Vault token tries to write the grant path
- **THEN** Vault denies the write and the audit log records the denial

### Requirement: a missing grant is asked for again

A missing, expired or invalid grant SHALL cause a new prompt and a new grant.
It SHALL NOT cause a failure that needs repair. Each grant record SHALL keep
`last_authorized` and `scope` for the tray's grant list.

#### Scenario: after a Vault wipe the system asks again

- **WHEN** the vault is wiped and rebuilt, and a previously granted action is
  requested
- **THEN** the dialog appears, and a new grant is stored after approval

### Requirement: the authoritative trail is a signed append-only journal

Every grant and every gated use SHALL be appended to a hash-chained journal of
signed statements under `refs/notes/tillandsias/approvals` in the mirror. The
mirror SHALL refuse non-fast-forward updates of that ref. The Vault audit log
SHALL remain on as the access trail.

#### Scenario: a deleted journal entry is detected

- **WHEN** an entry is removed from the journal
- **THEN** chain verification fails, naming the gap

### Requirement: SELinux confines the grant store on Linux

On a Linux host with SELinux enforcing, a policy module SHALL allow only the
approval broker's domain to mint grants and read the grant store's credential.
Container domains SHALL be denied.

#### Scenario: a forge process cannot read the grant credential

- **WHEN** a process in `container_t` opens the broker's Vault token file
- **THEN** SELinux denies it and an AVC is logged
