# Forge Push Credential Channel — 2026-06-20

**Filed:** 2026-06-20T20:30Z
**Origin:** Operator observation after opencode meta-orch run blocked on push
**Trace:** `spec:secrets-management`, `spec:forge-offline`, `spec:git-mirror-service`

## Problem

When `tillandsias . --opencode --prompt "..."` runs a meta-orchestration cycle inside
the forge, the agent commits work but **cannot push to `origin`** because:

1. The forge container has no HTTPS credential channel to github.com (the Squid proxy
   has an allowlist but no credential injection)
2. SSH is not available inside the forge enclave
3. No `GH_TOKEN`/`GITHUB_TOKEN` env var is injected at launch
4. The git mirror's post-receive hook CAN push (it reads from Vault), but the
   `git push origin` inside the forge shell points at github.com, not the git mirror

This means every unattended forge agent cycle (opencode, claude, codex) that commits
work leaves those commits as local-only — an operator must manually push them.

## Desired Behaviour

An agent running inside the forge should be able to:
```
git push origin <branch>
```
…and have that push relay through the git mirror container to GitHub, **without any
additional operator setup** after the initial `tillandsias --github-login`.

## Architecture Options

### Option A — Wire forge git remote to the git mirror (preferred)
- At forge container launch, set `origin` remote URL to `http://tillandsias-git/...`
  (or the git mirror's enclave hostname/port)
- The forge's git operations go to the mirror; the mirror's post-receive hook relays
  to GitHub via Vault-held token
- Already exists for git-mirror → GitHub; only missing is forge → git-mirror leg

### Option B — Inject GITHUB_TOKEN from Vault at launch
- Launcher mints an AppRole token, reads `secret/github/token`, injects as
  `GITHUB_TOKEN` env var (and configures `gh auth login --with-token`)
- Simpler but exposes the raw GitHub token inside the enclave (weaker isolation)

### Option C — Credential helper pointing at Vault
- Write a credential helper that reads `secret/github/token` from Vault via the
  already-mounted AppRole token
- Clean isolation; no token in env; slightly more complex

**Recommendation:** Option A is the cleanest — it stays consistent with the existing
git-mirror architecture and adds no new secret-surface inside the enclave.

## Action Items

- `forge-push/wire-git-remote`: at forge launch, rewrite the `origin` remote in the
  project's `.git/config` to point at `http://tillandsias-git/<repo-path>.git`
- `forge-push/git-mirror-clone-support`: ensure the git mirror serves HTTP clone/push
  for all locally cloned projects (not just the Tillandsias repo itself)
- `forge-push/post-receive-verify`: smoke-test the relay end-to-end: forge agent
  commits + pushes → git mirror → GitHub; verify the commit appears on the remote branch
- `forge-push/opencode-prompt-e2e`: wire the `tillandsias . --opencode --prompt "..."` 
  e2e smoke to verify pushed findings (see order 67)
