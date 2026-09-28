## MODIFIED Requirements

### Requirement: The guest never inherits the host's git identity
Guest git identity (user.name / user.email) SHALL be derived from the GitHub
App's authenticated user plus a host component and a Tillandsias-name
component, and SHALL be configured inside the container at entry. It SHALL
NOT be read from, mounted from, or copied from the host's global git config.

#### Scenario: Host gitconfig does not reach the guest
- **WHEN** a forge starts on a host whose global git config names someone
  other than the GitHub App's authenticated user
- **THEN** commits made inside the guest carry the App-derived identity, and
  no field of the host gitconfig's user.name or user.email

#### Scenario: No App login yields no borrowed identity
- **WHEN** no GitHub App login is stored for the project
- **THEN** the forge falls back to a project-scoped identity and says so in
  its lifecycle trace, and still does not read the host gitconfig

## ADDED Requirements

### Requirement: Guest identity is config, not exported environment
The forge SHALL write the identity as git configuration and SHALL NOT export
GIT_AUTHOR_* or GIT_COMMITTER_* into agent shells, so a scratch repository
that sets its own identity (`-c user.name`, a local config) commits as that
identity.

#### Scenario: A fixture's scratch identity wins inside a forge
- **WHEN** a fixture inside a forge runs `git -c user.name=fixture -c
  user.email=f@x commit` in a scratch repository
- **THEN** the commit's author is `fixture <f@x>`

### Requirement: Committer host stays derivable
Every commit made in a forge SHALL carry its host in a form the fleet's
host-derivation tooling reads, so attributing a commit to a host does not
depend on the author email's domain.

#### Scenario: Host attribution survives a noreply email
- **WHEN** a forge commit's author email is a users.noreply.github.com address
- **THEN** the fleet activity report attributes it to the forge's host, not
  to the unattributed bucket
