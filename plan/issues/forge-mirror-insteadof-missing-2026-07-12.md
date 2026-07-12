# Forge missing `url.insteadOf` — push transparent through git mirror requires manual config

**Filed**: 2026-07-12T22:34Z
**Host**: forge container, osx-next
**Classification**: enhancement/optimization
**Related packets**: forge-credential-guard-push-channel-gap-2026-07-08

## Summary

The forge container's `origin` remote points directly to GitHub
(`https://github.com/8007342/tillandsias.git`). The enclave git mirror
(`git://tillandsias-git/tillandsias`) is resolvable on the podman network
(`10.0.42.18`) and works for push, but there is no `url.insteadOf` rewrite
configured to route pushes through it transparently.

Without the rewrite, `git push origin <branch>` fails with
`fatal: could not read Username for 'https://github.com'` because no
credential helper, GH_TOKEN, or .gh-credentials is available.

## Workaround Applied

Added a repo-local `insteadOf` rule:

```
git config url."git://tillandsias-git/tillandsias".insteadOf \
  "https://github.com/8007342/tillandsias.git"
```

This lives in `.git/config` and is lost on container rebuild.

## Smallest Next Action

Bake the `insteadOf` rewrite into the forge container image (Containerfile or
entrypoint script) so every forge cycle starts with a transparent credential
channel. Owner: operator.

## Verifiable Closure

```bash
# After fix, this should succeed without manual config:
git push --dry-run origin osx-next 2>&1 | grep -v "fatal"
```

## HOST-SIDE ADDENDUM (macos cycle, 2026-07-12 ~23:00Z) — the workaround poisons the host

On macOS the forge works on the HOST checkout (shared into the guest), so
"repo-local `.git/config`" is the host's config: the insteadOf rewrite broke
every host-side `git fetch`/`push` (`fatal: unable to look up tillandsias-git
(port 9418)`) until quarantined. The exact line removed on the host:

```
url.git://tillandsias-git/tillandsias.insteadof=https://github.com/8007342/tillandsias.git
```

Constraint for the fix: the baked-in rewrite must be scoped to the forge
environment ONLY — e.g. `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_COUNT` env injected
by the entrypoint, or a container-home `~/.gitconfig` — NEVER written into a
`.git/config` that is shared with the host. "Lost on container rebuild" above
undersells it: it is also *inherited by the host* for as long as it exists.
Agents must not write push-routing config into the shared repo (worth a
guard/litmus).

Also see `git-mirror-push-false-success-not-relayed-2026-07-12.md` (P1): the
push this workaround unblocked was acked by the mirror but never reached
GitHub; the stranded commits were re-delivered from the host this cycle.
