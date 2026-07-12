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
