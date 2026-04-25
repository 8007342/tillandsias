# gh — GitHub CLI

@trace spec:agent-cheatsheets

> ⚠️ **DRAFT — provenance pending.** This cheatsheet was generated before the provenance-mandatory methodology landed. Treat its content as untrusted until the `## Provenance` section below is populated and verified against authoritative sources. See `cheatsheets/runtime/runtime-limitations.md` to report errors. (Tracked under change `cheatsheet-methodology-evolution`.)

**Version baseline**: gh 2.x (Fedora 43 package; 2.65+).
**Use when**: GitHub-side operations from the forge — issues, PRs, workflows, API calls. (Forge has no token by default — see Forge-specific.)

## Quick reference

| Subcommand | Common verbs | Effect |
|---|---|---|
| `gh pr` | `create`, `view`, `list`, `checkout`, `merge`, `diff`, `comment`, `review`, `ready` | Pull request lifecycle |
| `gh issue` | `create`, `view`, `list`, `close`, `reopen`, `comment`, `edit` | Issue lifecycle |
| `gh repo` | `view`, `clone`, `create`, `fork`, `list`, `set-default` | Repo metadata + cloning |
| `gh workflow` | `list`, `view`, `run`, `enable`, `disable` | GitHub Actions workflows |
| `gh run` | `list`, `view`, `watch`, `rerun`, `cancel`, `download`, `view --log` | Workflow run inspection |
| `gh api` | `<path>`, `--method`, `--jq`, `-F`/`-f`, `--paginate` | Raw REST/GraphQL access |
| `gh auth` | `status`, `login`, `token`, `refresh` | Token state (read-only here) |
| `gh release` | `create`, `view`, `list`, `download`, `upload` | Release artifacts |
| `gh search` | `repos`, `issues`, `prs`, `code`, `commits` | GitHub-wide search |

| Output flag | Effect |
|---|---|
| `--json field1,field2` | Structured output (stable across versions when fields are pinned) |
| `--jq '.field'` | Apply jq filter inline (no need to pipe) |
| `-t '{{.field}}'` | Go template output (alternative to `--jq`) |
| `--paginate` | Auto-follow `Link: rel=next`; combine with `--jq` to flatten |

## Common patterns

### Pattern 1 — create a PR with a heredoc body

```bash
gh pr create --title "Short imperative title" --body "$(cat <<'EOF'
## Summary
- bullet one
- bullet two

## Test plan
- [ ] cargo test --workspace
EOF
)"
```

Quote the heredoc delimiter (`'EOF'`) so `$`, backticks, and `!` in the body stay literal. Do NOT shell-escape inside.

### Pattern 2 — read PR state as structured JSON

```bash
gh pr view 123 --json number,title,state,mergeable,statusCheckRollup \
  --jq '{n:.number, ok:(.statusCheckRollup | all(.conclusion == "SUCCESS"))}'
```

`--json` + `--jq` is the contract — never grep human output, it changes between gh versions.

### Pattern 3 — list issues filtered by label and assignee

```bash
gh issue list --label bug --assignee @me --state open \
  --json number,title,url --jq '.[] | "\(.number)\t\(.title)\t\(.url)"'
```

`@me` resolves to the authenticated user. `--state` accepts `open|closed|all`.

### Pattern 4 — trigger a workflow_dispatch with inputs

```bash
gh workflow run release.yml -f version="0.1.169.225" -f channel=stable
gh run watch                                      # follow latest run
gh run view --log-failed                          # show only failed step logs
```

`-f key=value` for string inputs, `-F key=@file.json` for JSON-typed inputs. Watch the run before assuming success.

### Pattern 5 — paginate the API and aggregate

```bash
gh api -X GET /repos/{owner}/{repo}/issues \
  -f state=closed -f per_page=100 --paginate \
  --jq '.[] | select(.pull_request | not) | .number' | wc -l
```

`{owner}/{repo}` is auto-substituted from the current repo. `--paginate` follows `Link: next` until exhausted; combine with `--jq` so the per-page arrays flatten correctly.

## Common pitfalls

- **`gh auth status` says "not logged in" inside the forge** — expected. The forge holds NO GitHub token (see `runtime/networking.md`). Auth-bearing commands fail; run them on the host instead.
- **Read-only `gh` calls also fail** — even unauthenticated REST works against the public API, but only if the proxy allowlist includes `api.github.com`. Without it, `gh api` hangs. Write a `RUNTIME_LIMITATIONS_NNN.md` if you need it allowlisted.
- **JSON field names drift between gh versions** — pin the exact fields with `--json a,b,c` rather than `--json '*'`. Field renames between 2.40 and 2.65 have broken scripts that scraped human output.
- **`--json --jq` does NOT pipe to system `jq`** — gh has an embedded jq. Filter syntax matches jq 1.6, but `--slurpfile` and external modules are not available. For complex transforms, drop the `--jq` and pipe to real `jq` (`gh ... --json a,b | jq ...`).
- **Title/body escaping mistakes** — `--title "fix: don't crash"` works, but `--title 'fix: $foo'` keeps `$foo` literal while `--title "fix: $foo"` expands. Bodies are safest via `--body "$(cat <<'EOF' ... EOF)"`. Avoid `--body-file -` from a shell that might inject CR.
- **Rate limits hit silently** — unauthenticated REST is 60 req/h by IP; authenticated is 5000/h. `gh api /rate_limit --jq '.resources.core'` to inspect. Errors look like 403 with `X-RateLimit-Remaining: 0`.
- **`gh repo set-default` is per-repo state** — without it, `gh pr list` in a fresh clone with multiple remotes prompts interactively. CI/agent runs need it preconfigured (or use `--repo owner/name` on every call).
- **`gh run watch` exits non-zero when the run fails** — useful in scripts (`gh workflow run ... && gh run watch || exit 1`), but be aware that `set -e` will catch it.

## Forge-specific

- The forge has NO GitHub token. Any `gh` command requiring auth fails with `gh auth login` prompts (which themselves fail — no browser, no keyring).
- Read-only `gh` commands using the public API may work via the proxy, but only if `api.github.com` is in the proxy allowlist. By default it is not.
- Token-bearing operations (`pr create`, `workflow run`, `api` mutations, `release upload`) belong on the host, not in the forge.
- The git push path is the enclave mirror, not GitHub directly — see `runtime/networking.md`. `gh repo clone` would bypass that and try a direct fetch, which the proxy will refuse.
- For "I just need to know if my PR merged": run `gh pr view <n> --json state` on the host and paste the result back into the forge session.

## See also

- `utils/git.md` — local VCS, the layer below `gh`
- `runtime/networking.md` — proxy egress rules, why direct GitHub access is blocked
- `utils/jq.md` — for transforms beyond what embedded `--jq` handles
- `agents/openspec.md` — `gh pr create` is part of the archive workflow
