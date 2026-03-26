## ADDED Requirements

### Requirement: Container-created files are user-writable on the host

Files created by container processes in bind-mounted project directories SHALL be writable
by the host user without requiring `chmod` or elevated privileges.

#### Scenario: New file created by OpenCode or openspec init

- **WHEN** a container process (OpenCode, openspec, npm, bash) creates a file under
  `/home/forge/src/<project>/`
- **THEN** the file appears on the host with at minimum `u+rw` (user read-write) permissions
- **AND** the host user can modify or delete the file using a standard file browser or `rm`

#### Scenario: npm install creates package files

- **WHEN** `npm install` runs inside the container and writes to the project bind mount
- **THEN** the resulting `node_modules/` tree and `package-lock.json` are writable by the
  host user
- **AND** `rm -rf node_modules/` succeeds on the host without `sudo`

#### Scenario: Shell config files deployed from /etc/skel

- **WHEN** `entrypoint.sh` deploys `.bashrc`, `.zshrc`, or `config.fish` from `/etc/skel/`
- **THEN** the deployed files are user-writable in the container home directory
- **AND** tools that update these files (e.g., `zoxide init`) do not fail with EPERM

### Requirement: Consistent umask across all shells

All interactive sessions inside the forge container SHALL inherit `umask 0022`, ensuring
files are created with mode 0644 (files) or 0755 (directories) by default.

#### Scenario: bash session umask

- **WHEN** a user opens an interactive bash session inside the container
- **THEN** `umask` returns `0022`

#### Scenario: zsh session umask

- **WHEN** a user opens an interactive zsh session inside the container
- **THEN** `umask` returns `0022`

#### Scenario: fish session umask

- **WHEN** a user opens an interactive fish session inside the container (Ground Terminal)
- **THEN** `umask` returns `022`

#### Scenario: entrypoint-spawned processes inherit umask

- **WHEN** `entrypoint.sh` launches OpenCode via `exec "$OC_BIN"`
- **THEN** OpenCode and all its child processes inherit `umask 0022`
- **AND** files created by OpenCode's language servers or tool integrations are writable
