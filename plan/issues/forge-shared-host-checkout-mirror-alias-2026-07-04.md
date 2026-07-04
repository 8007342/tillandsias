# Forge Shared Host Checkout: Mirror Alias Can Point At Missing Forge DNS

**Filed**: 2026-07-04T01:59Z
**Origin**: forge meta-orchestration validation cycle
**Host**: forge container, linux-next
**Classification**: blocker/observation

## Observation

This forge container was launched against `/home/forge/src/tillandsias`, which is
the same checkout path Tlatoani had originally checked out on the host. The
container inherited the repo-local checkout and a global git rewrite:

```
url.git://tillandsias-git/tillandsias.insteadof=https://github.com/8007342/tillandsias.git
```

The credential channel guard still reported:

```
ok:forge-git-mirror
```

But `git fetch origin --prune` through the transparent mirror failed:

```
fatal: remote error: access denied or repository not exported: /tillandsias
```

and a direct `git ls-remote` with the normal global config tried the mirror
hostname and failed DNS resolution:

```
fatal: unable to look up tillandsias-git (port 9418) (Temporary failure in name resolution)
```

This is distinct from `plan/issues/git-mirror-no-upstream-remote-2026-07-02.md`:
that issue covers a reachable mirror that accepts but does not forward pushes.
This cycle observed a forge whose checkout/mapping combination points Git at a
mirror service name that is not reachable from the current container context.

## Non-Destructive Workaround Verified

Without changing host credentials, repo remotes, or global git mappings, direct
GitHub access worked by disabling the global git config for a single command:

```
GIT_CONFIG_GLOBAL=/dev/null git ls-remote https://github.com/8007342/tillandsias.git HEAD
```

With normal host networking, this returned:

```
e8e92a9fd1dace61c226f3ca1b0d156a03c30699 HEAD
```

The same per-command override also allowed a non-destructive fetch:

```
GIT_CONFIG_GLOBAL=/dev/null git fetch origin --prune
```

which advanced local refs to `origin/linux-next` `ca4deb46` and `origin/main`
`e8e92a9f`.

## Forge Validation Evidence

- `scripts/check-credential-channel.sh`: `ok:forge-git-mirror`
- `scripts/e2e-preflight.sh eligibility`: `skip:no-podman-binary`
- `cargo check --workspace`: PASS when run with normal host networking
- `cargo build -p tillandsias-headless --bin tillandsias`: PASS
- Built binary version:

```
Tillandsias v0.3.260704.1
```

## Operator Refinement

The intended fix is not to preserve or reuse host credentials inside the forge.
The source-mount path must be checked for host-local GitHub credential/config
surfaces and the forge should deliberately quarantine them:

- do not mount host GitHub credentials, credential helpers, auth stores, SSH
  agent sockets, or host-global git config into the forge;
- when a source mount would expose those paths, mount dummy override directories
  or files instead, scoped to the forge container;
- surface an explicit in-forge instruction such as "host credentials are not
  used inside the forge; use the forge credential channel or mirror";
- do not copy, log, inspect, or transform host credential/config material while
  making the decision;
- preserve the existing one-way credential boundary: credentials should not leak
  into the forge, just as forge credentials should not leak out.

## Residual Risk

The forge can build and type-check the current tree, but the normal transparent
mirror path is not sufficient in this shared-host-checkout case. Agents can still
fetch by using global git with `GIT_CONFIG_GLOBAL=/dev/null` per command, but
push still needs a credential channel that is not present in this container.

Publish attempts from this cycle:

- mirror push: `fatal: remote error: access denied or repository not exported:
  /tillandsias`
- direct HTTPS push with `GIT_CONFIG_GLOBAL=/dev/null`: `fatal: could not read
  Username for 'https://github.com': No such device or address`
- `gh auth status`: not logged in
- repo-local `.git/.gh-credentials`: absent
- `GH_TOKEN`/`GITHUB_TOKEN`: absent
- SSH fallback: no usable SSH credential channel; SSH GitHub route did not
  resolve from this container

The local plan commit contains this packet, but remote publication is blocked
until the forge has either a working mirror path or a non-host credential channel
for direct GitHub push. See
`plan/issues/forge-push-failure-full-report-2026-07-04.md` for the complete
push/fetch timeline and host-agent resolution checklist.

## Smallest Next Action

Implement `forge-source-mount-credential-quarantine` (plan order 170):

1. detect source mounts that contain host checkout state and host credential or
   config paths;
2. mask those paths with dummy forge-owned override dirs/files before agent
   startup;
3. prove with a litmus that host `~/.gitconfig`, GitHub credential stores,
   `.gh-credentials`, and SSH agent sockets are absent/unreadable in the forge;
4. prove that git operations still use the forge credential channel or a
   documented direct fallback, never host credential material.
