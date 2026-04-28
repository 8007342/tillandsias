# git Workflows

@trace spec:agent-source-of-truth

**Version baseline**: git 2.45 (Fedora 43)  
**Use when**: Cloning, committing, branching, rebasing, pushing (clones via enclave mirror, not GitHub directly)

## Provenance

- <https://git-scm.com/docs> — official Git documentation (canonical reference)
- <https://git-scm.com/docs/gitcredentials> — credential helper chain semantics, per-URL overrides
- <https://github.com/git-ecosystem/git-credential-manager/blob/main/docs/configuration.md> — Git Credential Manager (GCM) on Windows: `credential.interactive`, store backends
- <https://cli.github.com/manual/gh_auth_setup-git> — using `gh` as Git's credential helper to bypass GCM prompts
- <https://github.blog/changelog/> — GitHub API and feature releases
- **Last updated:** 2026-04-28

## Quick reference

| Task | Command |
|------|---------|
| Clone repo | `git clone <url>` |
| Check status | `git status` or `git status -s` (short) |
| Stage files | `git add <file>` or `git add -A` (all) |
| Commit | `git commit -m "msg"` |
| View history | `git log --oneline` |
| Create branch | `git switch -c <name>` |
| Switch branch | `git switch <name>` |
| Merge | `git merge <branch>` |
| Rebase | `git rebase <branch>` or `git rebase -i HEAD~N` (interactive) |
| Push | `git push -u origin <branch>` |
| Pull | `git pull --rebase` |
| Stash | `git stash` or `git stash pop` |
| Undo commit | `git reset --soft HEAD~1` (keep changes staged) |

## Common patterns

**Feature branch with rebase:**
```bash
git switch -c feature/auth-tokens
# ... make changes ...
git add src/auth.rs
git commit -m "feat(auth): implement token refresh"
git rebase origin/main
git push -u origin feature/auth-tokens
```

**Interactive rebase to squash:**
```bash
git rebase -i HEAD~3
# Mark commits as 'squash' or 's'
git push --force-with-lease origin <branch>
```

**Search commit history:**
```bash
git log --grep="pattern"    # Search messages
git log -S "code"           # Search code changes
git blame src/file.rs       # Show who changed each line
```

**Recover from mistake:**
```bash
git reflog                  # Find the SHA before error
git reset --hard HEAD@{3}   # Rewind to that point
```

## Windows host: HTTPS auth without GCM prompts

Git for Windows installs with `credential.helper=manager` (Git Credential Manager) at **system scope** (`C:\Program Files\Git\etc\gitconfig`). On every HTTPS operation against a host without a cached credential, GCM pops a UI dialog asking which account to use — even when `gh auth login` already stored a valid token in the OS keyring, because Git's helper chain asks GCM, not `gh`.

**Recommended:** delegate github.com to `gh` (per-URL, leaves other hosts on GCM):

```sh
gh auth setup-git                            # all gh-authenticated hosts
gh auth setup-git --hostname github.com      # restrict to github.com only
```

This writes to `~/.gitconfig`:

```ini
[credential "https://github.com"]
    helper = !"C:/Program Files/GitHub CLI/gh.exe" auth git-credential
```

Per <https://git-scm.com/docs/gitcredentials>: per-URL `credential.<url>.helper` is consulted before the unscoped `credential.helper`, so the system-level GCM is bypassed for github.com only. Reference for the helper subcommand: <https://cli.github.com/manual/gh_auth_setup-git>.

**Helper chain rule** (from the same doc):

> "If there are multiple instances of the `credential.helper` configuration variable, each helper will be tried in turn, and may provide a username, password, or nothing. Once Git has acquired both a username and a non-expired password, no more helpers will be consulted."

So the per-URL `gh` helper "wins" by being asked first; if it answers, GCM is never invoked.

**Headless / CI on Windows** (avoid the UI without removing GCM):

```sh
# One-shot, this command only:
GCM_INTERACTIVE=Never git push
# Or persistent:
git config --global credential.interactive false
```

Both keys documented at <https://github.com/git-ecosystem/git-credential-manager/blob/main/docs/configuration.md>. With `Never`, GCM errors out instead of hanging on a missing prompt — preferred in scripts that should fail loudly.

**Inspect what's stored:**

```sh
cmdkey /list                                  # all generic creds (target names only)
git config --get-all credential.helper        # system: 'manager'
git config --get-all credential.https://github.com.helper   # global: gh helper if set
gh auth status                                 # token state per host
```

`cmdkey` reference: <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/cmdkey>. To remove a stored GitHub credential: Control Panel → User Accounts → Credential Manager → Windows Credentials → find `git:https://github.com`.

## Common pitfalls

- **Missing origin tracking**: Use `git push -u origin <branch>` on first push to auto-track.
- **Shallow clones cause rebase issues**: `git clone --depth=1` saves bandwidth but breaks rebases. Use only for snapshots.
- **Force push danger**: `git push -f` rewrites remote history. NEVER on main; use `--force-with-lease` on feature branches.
- **Detached HEAD**: `git checkout <hash>` leaves you off-branch. Create one: `git checkout -b recovery <hash>`.
- **Large files in history**: Never commit `.env`, binaries, or credentials. Use `.gitignore` and `git-filter-repo` to strip accidental adds.
- **Credential helper in forge**: Forge has NO host credentials. Leave `credential.helper` unset — enclave mirror handles auth.

## See also

- `utils/gh.md` — GitHub CLI (authentication, PRs, issues)
- `utils/ssh.md` — SSH key management for Git push over SSH
