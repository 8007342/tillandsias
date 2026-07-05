# Forge Push Failure Full Report — Shared Host Checkout / Missing Credential Channel

**Filed**: 2026-07-04T02:16Z
**Origin**: forge meta-orchestration validation cycle
**Host**: forge container, `linux-next`
**Classification**: blocker/report
**Related packets**:

- `forge-source-mount-credential-quarantine` (order 170)
- `git-mirror-upstream-forwarding` (order 167)
- `codex-forge-yolo-config-defaults` (order 171)

## Executive Summary

The forge could validate and commit plan findings locally, but could not publish
them to `origin/linux-next` from inside this container.

The container is using the same `/home/forge/src/tillandsias` checkout path as
Tlatoani's host checkout. It also has a global git rewrite that maps the GitHub
origin URL to the in-forge mirror service:

```
url.git://tillandsias-git/tillandsias.insteadof=https://github.com/8007342/tillandsias.git
```

In this topology, the transparent mirror path is broken and direct GitHub push
does not have a non-interactive credential channel. The correct host-side
resolution is to fix the forge source-mount credential quarantine and mirror
credential path, not to copy host credentials into the forge.

## Local State For Host Agent

At report time:

- branch: `linux-next`
- status: clean tracked worktree, one local commit ahead of `origin/linux-next`
- local commit subject: `chore(plan): file forge source-mount credential quarantine`
- files changed by the local commit:
  - `plan/index.yaml`
  - `plan/loop_status.md`
  - `plan/issues/forge-shared-host-checkout-mirror-alias-2026-07-04.md`
  - `plan/issues/forge-push-failure-full-report-2026-07-04.md`
  - `plan/issues/codex-forge-yolo-defaults-2026-07-04.md`

A host-side agent with working repository credentials should be able to inspect
`git log -1 --stat`, resolve any upstream fast-forward/rebase if needed, then
push `linux-next`.

## Push / Fetch Timeline

### 1. Required meta-orchestration fetch through normal configured origin failed

Command:

```
git fetch origin --prune
```

Result:

```
fatal: remote error: access denied or repository not exported: /tillandsias
```

This used the normal global rewrite into `git://tillandsias-git/tillandsias`.

### 2. Credential guard produced a false-positive for this topology

Command:

```
scripts/check-credential-channel.sh
```

Result:

```
ok:forge-git-mirror
```

This verdict was insufficient: the guard detected a nominal forge mirror channel,
but the mirror repository was not exported/reachable for the current checkout
path.

### 3. Normal git URL rewrite also failed DNS in this container

Command:

```
git ls-remote https://github.com/8007342/tillandsias.git HEAD
```

Result:

```
fatal: unable to look up tillandsias-git (port 9418) (Temporary failure in name resolution)
```

This confirms the global `insteadOf` rewrite steered even explicit GitHub URLs to
the forge mirror hostname.

### 4. Direct GitHub read worked with global config disabled

Command:

```
GIT_CONFIG_GLOBAL=/dev/null git ls-remote https://github.com/8007342/tillandsias.git HEAD
```

Result:

```
e8e92a9fd1dace61c226f3ca1b0d156a03c30699 HEAD
```

This proved the network path to GitHub can work from the host execution context
when the global mirror rewrite is bypassed.

### 5. Direct fetch worked with global config disabled

Command:

```
GIT_CONFIG_GLOBAL=/dev/null git fetch origin --prune
```

Result:

```
From https://github.com/8007342/tillandsias
   a67a97ad..ca4deb46  linux-next -> origin/linux-next
   5606087b..e8e92a9f  main       -> origin/main
```

The branch was then fast-forwarded locally to `origin/linux-next`.

### 6. Forge validation succeeded after sync

Commands and results:

```
scripts/e2e-preflight.sh eligibility
skip:no-podman-binary
```

```
cargo check --workspace
PASS
```

```
cargo build -p tillandsias-headless --bin tillandsias
PASS
```

```
target/debug/tillandsias --version
Tillandsias v0.3.260704.1
```

The local-build destructive Podman gate was not eligible because this forge has
no `podman` binary.

### 7. Direct HTTPS push failed due to missing credential channel

Command:

```
GIT_CONFIG_GLOBAL=/dev/null git push origin linux-next
```

Result:

```
fatal: could not read Username for 'https://github.com': No such device or address
```

Credential checks:

```
gh auth status
You are not logged into any GitHub hosts. To log in, run: gh auth login
```

```
repo-local .git/.gh-credentials: absent
GH_TOKEN/GITHUB_TOKEN: absent
SSH_AUTH_SOCK: absent
```

No credential material was printed, copied, transformed, or mounted to work
around this.

### 8. Normal mirror push also failed

Command:

```
git push origin linux-next
```

Result:

```
fatal: remote error: access denied or repository not exported: /tillandsias
```

### 9. SSH fallback was not usable

Command:

```
GIT_CONFIG_GLOBAL=/dev/null git ls-remote git@github.com:8007342/tillandsias.git HEAD
```

Result:

```
ssh: Could not resolve hostname github.com: Name or service not known
fatal: Could not read from remote repository.
```

SSH is not a reliable fallback here, and using host SSH agent sockets inside the
forge would violate the desired credential boundary anyway.

## Root-Cause Analysis

There are two separate failures:

1. **Mirror export/routing failure**: the forge global git rewrite points GitHub
   remotes to `git://tillandsias-git/tillandsias`, but that repository path is
   not exported/reachable from this container. The credential guard does not
   distinguish "mirror configured" from "mirror can actually fetch/push this
   repository".
2. **No direct GitHub credential channel**: bypassing the mirror reaches GitHub
   for reads, but push cannot authenticate because there is no `gh` login,
   repo-local `.gh-credentials`, token env var, or SSH credential channel inside
   the forge.

These failures are related to the shared host checkout topology: the forge
source mount overlaps Tlatoani's own host checkout, and host-local git config or
credential assumptions can bleed into the container's behavior without providing
a valid in-forge credential channel.

## Security Boundary Required

The fix must not mount or reuse host credentials. The desired invariant is:

- host GitHub credentials, host `.gitconfig`, credential-helper stores, SSH agent
  sockets, and auth stores do not enter the forge;
- forge startup masks potential credential/config paths with forge-owned dummy
  override dirs/files when a source mount would otherwise expose them;
- agents are told explicitly that host credentials are not used inside the
  forge;
- git operations use the forge credential channel/mirror, or a documented direct
  fallback backed by forge-owned credentials.

## Host-Agent Resolution Checklist

1. From the host checkout, inspect `git log -1 --stat` and confirm the local plan
   commit is present.
2. Fetch current `origin/linux-next`.
3. Rebase or fast-forward the local commit if remote advanced.
4. Push `linux-next` from the host, where the legitimate host credential channel
   exists.
5. Pick up plan order 170 to quarantine host credential/config surfaces for
   future source-mounted forge sessions.
6. Pick up plan order 171/172 so Codex runs in forge YOLO/full-auto mode by
   default and no longer prompts for ordinary command/build/git permissions
   inside the already-contained forge.

## Non-Actions

- Did not edit `/home/forge/.gitconfig`.
- Did not remove or change the global `url.insteadOf` mapping.
- Did not copy host credentials into the forge.
- Did not run `gh auth login`.
- Did not mount or inspect host credential files.
- Did not perform destructive Podman resets; e2e preflight returned
  `skip:no-podman-binary`.
