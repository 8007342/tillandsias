# Vault / Git-Mirror Credential Forwarding Enhancement

## Problem

The forge enclave's git-mirror container (`tillandsias-git`) forwards pushes to
`https://github.com/8007342/tillandsias.git`, but cannot authenticate because it
lacks GitHub credentials. The git-mirror uses an anonymous HTTPS push URL and
gets `fatal: could not read Username for 'https://github.com': No such device
or address`. This means forge agents inside the enclave can commit and push to
the local mirror, but their work never reaches GitHub (and is lost when the
enclave tears down).

The host-side `credential channel: ok:gh-keyring` works because it uses the
host's `gh` CLI keyring. The enclave has no equivalent path.

## Proposed Solution

Wire the git-mirror container to fetch GitHub credentials from Vault on startup
(or on demand), so that `git push --mirror` to `origin` succeeds.

### Option A: Vault AppRole + periodic token refresh

- Give the git-mirror a Vault AppRole role `git-mirror` with a policy that
  grants read on `secret/github-token` (or a deploy token).
- On boot, the git-mirror logs into Vault, fetches the credential, and writes a
  `.netrc` or `git-credential-store` file for the outgoing HTTPS push URL.
- Periodically refresh the credential before Vault TTL expiry.
- Problem: the credential already exists in Vault (`github-login` policy), but
  it may be a PAT scoped to the operator's user, not a deploy token.

### Option B: SSH deploy key from Vault

- Generate an SSH deploy keypair, store the private half in Vault
  (`secret/git-mirror-ssh-key`), and configure the git-mirror's remote to use
  `git@github.com:8007342/tillandsias.git`.
- The git-mirror fetches the SSH key from Vault via AppRole on boot, writes it
  to `~/.ssh/id_ed25519`, and adds the known host.
- Advantage: SSH deploy keys are repo-scoped and don't expire like PATs.
- Disadvantage: requires operator to register the public half as a deploy key
  on the GitHub repo.

### Option C: Shared secret volume (simplest, least secure)

- Mount the host's `~/.config/gh` or `~/.netrc` into the git-mirror container
  so the existing host credential is available.
- Advantage: zero Vault changes, works immediately.
- Disadvantage: couples enclave to host filesystem; credential is visible to
  all forge containers.

### Option D: PAT stored in Vault, injected as env var

- Store a fine-grained PAT with `contents:write` and `pull_requests:write`
  scopes in Vault under `secret/github-mirror-pat`.
- The git-mirror retrieves it via AppRole and sets it as `GITHUB_TOKEN` or
  configures `git config --global credential.helper "!f() { echo username=token; echo password=$PAT; }; f"`.
- Advantage: simple to implement, Vault-native, deployable without SSH key
  registration.
- Disadvantage: PAT expiry requires rotation.

## Dependencies

- Vault must be reachable from the git-mirror container (already true — they
  share the `tillandsias-enclave` network; Vault is at `http://vault:8200` or
  `https://127.0.0.1:8201` depending on routing).
- An AppRole role + policy must be provisioned in Vault for the git-mirror
  (currently only `GitMirror`, `Forge`, `Tray`, `Inference`, `GithubLogin`
  exist; `GitMirror` may already be suitable).
- The Vault bootstrap (`images/vault/entrypoint.sh`) or an init script must
  create the secret path with a valid credential.

## Work Packets

### Work Packet: vault/git-mirror-credential-provision

- id: `vault/git-mirror-credential-provision`
- owner_host: linux
- capability_tags: [vault, git-mirror, containers, shell, security]
- status: ready
- discovered_by: curl-install e2e smoke for v0.3.260625.1 (forge meta-orch cannot push to GitHub)
- evidence:
  - `target/smoke-e2e/04-opencode.log` — git-mirror push to origin FAILED (credential missing)
  - forge meta-orch commit `75acb322` lost from GitHub after enclave teardown
- repro:
  - Inside the forge enclave: `git push origin linux-next` from the mirror fails with
    `fatal: could not read Username for 'https://github.com': No such device or address`
  - On host: `git push origin linux-next` succeeds (host has `gh` keyring)
- next_action: >
    Decide on Option A-D, then implement the credential flow: store a
    deploy credential in Vault, create/update the git-mirror role/policy,
    wire the git-mirror entrypoint to fetch and apply the credential on boot.
- events:
  - type: discovered
    ts: 2026-06-25T21:46Z
    agent_id: big-pickle
    host: linux_immutable

### Work Packet: vault/health-report-via-podman-layer

- id: `vault/health-report-via-podman-layer`
- owner_host: linux
- capability_tags: [vault, podman, containers, shell]
- status: ready
- discovered_by: curl-install e2e smoke for v0.3.260625.1
- evidence:
  - `images/vault/Containerfile` builds Vault on Alpine with `HEALTHCHECK` that
    Podman OCI ignores (`HEALTHCHECK is not supported for OCI image format and
    will be ignored. Must use docker format`).
  - `tillandsias --debug --init` output: repeated `HEALTHCHECK ... ignored` warnings.
- repro:
  - Run `podman build -f images/vault/Containerfile .` — Podman emits
    `HEALTHCHECK is not supported for OCI image format` warning.
  - `podman inspect tillandsias-vault` shows no health status field.
- next_action: >
    Replace Docker HEALTHCHECK with a Podman-compatible health probe.
    Options:
    (a) `podman healthcheck run tillandsias-vault` with a `--health-cmd` in
        the `podman run` args (set in the Rust orchestrator, not the Containerfile).
    (b) Add a sidecar shell loop inside the container that periodically runs
        `curl --cacert /run/secrets/tillandsias-vault-tls-ca -fsS
        https://127.0.0.1:8200/v1/sys/health?standbyok=true || exit 1`
        and writes status to a shared file or podman health check.
    (c) Implement health reporting in the Rust init orchestrator using
        `podman healthcheck` commands after container start.
    The goal: `tillandsias --status-check` (or `podman ps --format
    '{{.Status}}'`) reports `healthy` for Vault, not `(unhealthy)` or
    `(unknown)`.
- events:
  - type: discovered
    ts: 2026-06-25T14:36Z
    agent_id: big-pickle
    host: linux_immutable

### Work Packet: forge/push-credential-persistence

- id: `forge/push-credential-persistence`
- owner_host: linux
- capability_tags: [forge, git-mirror, vault, release]
- status: ready
- discovered_by: curl-install e2e smoke for v0.3.260625.1
- evidence:
  - Forge meta-orch commit `75acb322` was pushed to enclave-local git-mirror but
    never reached GitHub; lost when enclave teardown pruned mirror state.
- repro:
  - Run forge inside enclave: `tillandsias . --opencode --prompt "..."`
  - Forge agent commits and pushes to `git://tillandsias-git/tillandsias`
  - Git-mirror attempts `git push https://github.com/8007342/tillandsias.git` → FAILS
- next_action: >
    Depends on `vault/git-mirror-credential-provision`. Once the credential path
    is wired, verify that forge agents can push to GitHub without losing work.
    Also consider a watchdog: if git-mirror is degraded, the forge meta-orch
    agent should NOT claim work that produces plan commits (or should record
    local evidence that survives teardown).
- events:
  - type: discovered
    ts: 2026-06-25T21:46Z
    agent_id: big-pickle
    host: linux_immutable
