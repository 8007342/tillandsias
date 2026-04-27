# git Workflows

@trace spec:agent-source-of-truth

**Version baseline**: git 2.45 (Fedora 43)  
**Use when**: Cloning, committing, branching, rebasing, pushing (clones via enclave mirror, not GitHub directly)

## Provenance

- https://git-scm.com/docs — official Git documentation (canonical reference)
- https://github.blog/changelog/ — GitHub API and feature releases
- **Last updated:** 2026-04-27

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
