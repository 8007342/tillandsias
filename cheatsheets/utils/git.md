# git

@trace spec:agent-cheatsheets

**Version baseline**: git 2.x (Fedora 43 package; current 2.45+). git-lfs and gh also baked in.
**Use when**: any version control operation in the forge (clones go through enclave mirror, NOT github directly).

## Quick reference

| Op | Command | Notes |
|----|---------|-------|
| Stage | `git add <path>` / `git add -p` | `-p` for hunk-by-hunk |
| Commit | `git commit -m "msg"` / `git commit --amend` | Amend rewrites HEAD only |
| Status | `git status -sb` | Short + branch info |
| Branch | `git switch -c <name>` / `git branch -d <name>` | `-D` force-delete |
| Log | `git log --oneline --graph --decorate -20` | Compact view |
| Diff | `git diff` / `git diff --staged` / `git diff <a>..<b>` | Working / staged / range |
| Rebase | `git rebase <base>` / `git rebase -i <base>` | `-i` for cleanup |
| Stash | `git stash push -m "msg"` / `git stash pop` | `-u` includes untracked |
| Reset | `git reset --soft <ref>` / `--mixed` / `--hard` | `--hard` discards work |
| Reflog | `git reflog` | Last-resort recovery log |
| Push | `git push` / `git push -u origin <br>` | `-u` sets upstream |
| Pull | `git pull --rebase` | Avoid merge bubbles |
| Bisect | `git bisect start` / `good <ref>` / `bad <ref>` | Binary-search regressions |
| Tag | `git tag -a v1.2.3 -m "msg"` | Annotated tag |

## Common patterns

**Feature branch with rebase before merge:**
```bash
git switch -c feat/foo
# ...work, commit...
git fetch origin
git rebase origin/main          # replay commits on top of main
git push -u origin feat/foo
```

**Interactive rebase to clean history:**
```bash
git rebase -i origin/main       # mark commits: pick/squash/fixup/reword/drop
# squash fixups into their parents, reword vague messages
git push --force-with-lease     # safer than --force
```

**Recover from a bad commit (reflog + reset):**
```bash
git reflog                      # find the SHA before the mistake
git reset --hard HEAD@{3}       # rewind to that point
# or restore a single file:
git restore --source=HEAD@{3} -- path/to/file
```

**Stash workflow (interrupt current work):**
```bash
git stash push -u -m "wip: feature foo"
git switch main && git pull --rebase
# ...handle the urgent thing...
git switch feat/foo
git stash pop                   # or `git stash apply` to keep the stash
```

**Bisect to find a regression:**
```bash
git bisect start
git bisect bad                  # current HEAD is broken
git bisect good v0.1.150        # known-good ref
# git checks out midpoint; test and mark:
git bisect good   # or  git bisect bad
# repeat until git names the offending commit
git bisect reset
```

## Common pitfalls

- **Detached HEAD**: `git checkout <sha>` leaves you off any branch. Commits made there are GC'd unless you `git switch -c <name>` to anchor them.
- **Force-push to shared branches**: `git push --force` on `main`/`linux-next`/`osx-next`/`windows-next` overwrites teammates' commits. Always use `--force-with-lease`, and never force-push to `main`.
- **Rebase vs merge confusion**: rebasing a branch already pushed-and-pulled by others rewrites shared history. Rebase only your own unmerged feature branches; merge for shared ones.
- **`.gitignore` is not retroactive**: adding a path to `.gitignore` does not untrack already-committed files. Use `git rm --cached <path>` to stop tracking.
- **CRLF / LF line endings**: cross-platform repos can corrupt diffs. Set `* text=auto` in `.gitattributes` and `core.autocrlf=input` on Windows checkouts.
- **Large files belong in LFS**: anything > a few MB binary (images, models, archives) should go through `git lfs track '<glob>'`. Once committed as a regular blob, history rewrite is the only fix.
- **Credential helper traps in the forge**: the forge has NO host credentials and NO ssh keys. `git config credential.helper` set to `osxkeychain`/`libsecret`/`manager` will fail silently or prompt forever. Leave the helper unset — the enclave mirror handles auth.
- **`--amend` after push**: amending a commit you've already pushed forces a non-fast-forward push. Either avoid (preferred) or use `--force-with-lease` and warn collaborators.
- **`reset --hard` with untracked files**: hard reset does NOT remove untracked files. If you also want a pristine tree, follow with `git clean -fd` (review with `-n` first).

## Forge-specific

- The forge clones from `git://git-service/<project>` — NOT directly from github. Pushes go to the same mirror; the git-service container relays to GitHub with the human's token.
- No SSH keys in the forge. `git push` over ssh fails. Use the http(s) remote configured at clone time.
- `git fetch` from the mirror is fast and offline-safe; `git fetch upstream` against github.com from inside the forge will time out (egress is allowlisted to package mirrors only, not git.git).
- Tag pushes propagate the same way: `git push --tags` -> mirror -> git-service relays to github.

## See also

- `utils/gh.md` — GitHub CLI for issues/PRs/workflows
- `runtime/networking.md` — why the mirror, not direct github
