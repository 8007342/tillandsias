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

## Cycle Update 2026-07-03T22:47Z (forge, linux-next)

Observed during meta-orchestration cycle:

### Additional Issues Found

- **Mirror has empty repo**: `git ls-remote git://tillandsias-git/tillandsias` exits 0 with no output — no refs at all on mirror.
- **HTTP 403 on port 8080**: `lighttpd` returns 403 Forbidden for git HTTP backend at `/tillandsias/info/refs?service=git-upload-pack`.
- **`git fetch` via mirror deletes all remote tracking branches**: Since mirror repo is empty, `git fetch --prune` treats all remote refs as deleted.
- **Workaround**: Removed `url.git://tillandsias-git/tillandsias.insteadOf` global config to work directly with GitHub. Direct fetch/push to `https://github.com/8007342/tillandsias.git` works fine via `.gh-credentials` store.

### What Made Us Slower

- Had to diagnose mirror outage at cycle start before any worker drain
- Existing mirror issue filed 2026-07-02 described a *different* symptom (mirror has upstream remote configured)
- Three `git fetch` cycles before root-causing (initial fetch → tracking branches deleted → re-fetch directly)

### Cycle Update 2026-07-03T22:53Z (forge, linux-next)

Confirmed: direct GitHub fetch/push works after removing `url.git://tillandsias-git/tillandsias.insteadOf` from global git config. Credential guard passes via `.gh-credentials` store. Used direct GitHub access for this cycle.

### Next Action

1. Fix mirror upstream remote configuration in headless orchestrator (`ensure_enclave_for_project()` in `crates/tillandsias-headless/src/main.rs`)
2. Fix HTTP 403 on lighttpd git-http-backend (`images/git/`)
3. Re-enable `url.insteadOf` config after mirror is verified working
4. Verify end-to-end: push from forge → mirror → GitHub
