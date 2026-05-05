# GitHub CLI (gh)

@trace spec:agent-source-of-truth

**Version baseline**: gh 2.48 (Fedora 43)  
**Use when**: Creating/reviewing pull requests, managing issues, checking CI status, or authenticating with GitHub

## Provenance

- https://cli.github.com/ — GitHub CLI official docs (canonical reference)
- https://cli.github.com/manual — Command reference
- **Last updated:** 2026-04-27

## Quick reference

| Task | Command |
|------|---------|
| Login | `gh auth login` (interactive) |
| Check auth | `gh auth status` |
| Create PR | `gh pr create --title "..." --body "..."` |
| View PR | `gh pr view <number>` or `--web` (browser) |
| List PRs | `gh pr list` or `--state closed` |
| Review PR | `gh pr review <number> -a` (approve) |
| Create issue | `gh issue create --title "..."` |
| List issues | `gh issue list` or `--assignee @me` |
| Check CI | `gh pr checks <number>` |
| View workflow runs | `gh run list` or `gh run view <id>` |
| Trigger workflow | `gh workflow run release.yml -f version="X.Y.Z"` |

## Common patterns

**Create PR with heredoc body:**
```bash
gh pr create --title "feat: describe work" --body "$(cat <<'EOF'
## Summary
- bullet one
- bullet two

## Test plan
- [ ] cargo test --workspace
EOF
)"
```

**Merge PR locally before viewing:**
```bash
gh pr checkout 789
git log --oneline origin/main..HEAD
gh pr merge 789 --squash
```

**List PRs awaiting review:**
```bash
gh pr list --reviewer @me
gh pr view <number> --web
```

**Trigger workflow and watch:**
```bash
gh workflow run release.yml -f version="0.1.169.225"
gh run watch
```

**Check PR status with JSON:**
```bash
gh pr view 456 --json number,title,state,mergeable
```

## Common pitfalls

- **No auth = API limits**: Without `gh auth login`, hit 60 API calls/hour. Login first.
- **Forge has NO token**: Inside forge, even read-only calls fail if proxy doesn't allowlist `api.github.com`. Write `RUNTIME_LIMITATIONS_NNN.md` if needed.
- **Token expiry**: OAuth tokens expire after 8 hours. Re-authenticate: `gh auth refresh --scopes repo,gist`.
- **JSON field names drift**: Pin exact fields: `--json a,b,c` rather than `--json '*'`.
- **`--json --jq` uses embedded jq**: Filters match jq 1.6; no external modules. Complex transforms: drop `--jq` and pipe to system `jq`.
- **Rate limits hit silently**: 60 unauthenticated/h, 5000 authenticated/h. Check: `gh api /rate_limit --jq '.resources.core'`.

## See also

- `utils/git-workflows.md` — Git basics (branching, committing, pushing)
- `runtime/networking.md` — API authentication via enclave git service
