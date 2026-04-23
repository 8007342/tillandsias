## MODIFIED Requirements

### Requirement: Git service credential delivery

The git-service container SHALL receive GitHub credentials as an ephemeral tmpfs file bind-mounted read-only at `/run/secrets/github_token`. The file is materialized on the host immediately before container launch and unlinked on container stop. No D-Bus socket, no keyring API, no other credential artifact is mounted.

#### Scenario: Token file mount on launch
- **WHEN** `handlers::ensure_git_service_running(project_name, mirror_path, state, build_tx)` is called and the OS keyring contains a token
- **THEN** `secrets::prepare_token_file(container_name)` SHALL be called before `build_podman_args`
- **AND** the returned `Option<PathBuf>` SHALL populate `LaunchContext.token_file_path`
- **AND** `build_podman_args` SHALL add `-v <path>:/run/secrets/github_token:ro` and `-e GIT_ASKPASS=/usr/local/bin/git-askpass-tillandsias.sh`

#### Scenario: No token → no mount, clear failure on push
- **WHEN** the keyring has no token (user hasn't run `--github-login`)
- **THEN** `LaunchContext.token_file_path` SHALL be `None`
- **AND** the mount SHALL be skipped
- **AND** a WARN accountability log SHALL fire: "Container requested GitHubToken but no token is available in host keyring — authenticated git operations will fail"
- **AND** subsequent `git push` attempts SHALL fail with a clear HTTP 401 error from GitHub

#### Scenario: Token file unlink on stop
- **WHEN** `stop_git_service(project_name)` runs
- **THEN** `secrets::cleanup_token_file(container_name)` SHALL be called after the container stop attempt
- **AND** the file + its parent dir SHALL be removed from disk

### Requirement: Post-receive hook uses GIT_ASKPASS

The git-service's post-receive hook (`/usr/local/share/git-service/post-receive-hook.sh`) SHALL push to the origin remote via HTTPS using `GIT_ASKPASS=/usr/local/bin/git-askpass-tillandsias.sh`. The askpass script reads `/run/secrets/github_token` and feeds it to git.

#### Scenario: Forge pushes → mirror → github.com
- **GIVEN** a forge container has pushed a commit to the mirror via `git://git-service/<project>`
- **WHEN** the mirror's post-receive hook runs `git push --mirror origin`
- **AND** `origin` is an HTTPS URL
- **THEN** git SHALL invoke the askpass script
- **AND** for the username prompt the script SHALL print `x-access-token`
- **AND** for the password prompt the script SHALL print the contents of `/run/secrets/github_token`
- **AND** the push SHALL authenticate against github.com successfully

#### Scenario: Post-receive never blocks forge
- **WHEN** the mirror-to-origin push fails for any reason (network, auth, etc.)
- **THEN** the hook SHALL log `[git-mirror] WARNING: Push to origin ($REMOTE_URL) FAILED — changes may not be synced` to `/var/log/tillandsias/git-push.log`
- **AND** the hook SHALL exit 0 so the forge's originating push is never blocked by a downstream failure

## REMOVED Requirements

### Requirement: D-Bus session bus mount into git-service container

**Reason**: Moved to host-process-only keyring access via the `keyring` crate. See the `secrets-management` and `native-secrets-store` deltas.

**Migration**: The git-service container no longer receives `DBUS_SESSION_BUS_ADDRESS` or a bind-mounted D-Bus socket. Credentials arrive as the `/run/secrets/github_token:ro` mount described above.
