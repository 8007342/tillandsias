# Git Mirror: No Upstream Remote Configured — Pushes Trapped Locally

**Filed**: 2026-07-02T19:54Z
**Origin**: forge diagnostics cycle from WSL2 forge container
**Host**: forge (linux, windows-next branch)
**Classification**: blocker

## Observation

The git-service mirror (`tillandsias-git:9418`, `git-service:9418`) is operational and accepts pushes from forge containers, but the mirror itself has no upstream remote configured to forward pushed refs to GitHub.

During the diagnostics push test:
```
remote: [git-mirror] No remote configured, skipping push
```

The pushed `windows-next` branch was received by the mirror (confirmed via `git ls-remote`), but the mirror cannot forward it to GitHub. All pushes from forge containers are trapped locally on the mirror.

## What Works

- TCP connectivity to mirror port 9418 ✓
- `git push` via `url.insteadOf` redirect in global git config ✓
- Mirror receives and stores pushed refs ✓
- Mirror's `git post-receive` hook runs `git maintenance --auto` ✓

## What's Broken

- Mirror has no remote configured → `git push` from the hook logs `skipping push`
- `TILLANDSIAS_HOST_KIND=forge` credential channel guard (`ok:gh-credentials-store`) considers this OK because the mirror is reachable — but the mirror can't complete the push to GitHub

## Root Cause

The mirror's bare repository at `/srv/git/tillandsias` has no `origin` or other remote configured. The post-receive hook (or equivalent mechanism) needs `remote.origin.url=https://github.com/8007342/tillandsias.git` with the GitHub token from `.gh-credentials` or Vault to forward pushes.

## Next Action

1. Configure upstream remote on the git-service mirror for the `tillandsias` repository
2. Either: (a) inject the `.gh-credentials` token into the clone URL, or (b) have the post-receive hook fetch credentials from Vault
3. Verify end-to-end: push from forge → mirror → GitHub
