---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://cli.github.com/manual/
  - https://github.com/cli/cli
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# gh — GitHub CLI

@trace spec:agent-cheatsheets

**Version baseline**: gh 2.x (Fedora 43 package; 2.65+).
**Use when**: GitHub-side operations from the forge — issues, PRs, workflows, API calls. (Forge has no token by default — see Forge-specific.)

## Provenance

- GitHub CLI manual (official): <https://cli.github.com/manual/> — complete subcommand and flag reference
- `gh auth setup-git` reference: <https://cli.github.com/manual/gh_auth_setup-git> — credential-helper integration with Git
- Git Credential Manager configuration: <https://github.com/git-ecosystem/git-credential-manager/blob/main/docs/configuration.md> — `credential.interactive` / `GCM_INTERACTIVE`, store backends, namespaces
- Git credentials reference: <https://git-scm.com/docs/gitcredentials> — helper chain rules, per-URL `credential.<url>.*` overrides
- Windows `cmdkey` reference: <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/cmdkey> — inspect Windows Credential Manager from the shell
- GitHub CLI repository: <https://github.com/cli/cli> — source, release notes, and changelog
- **Last updated:** 2026-04-28

Verified from the official manual: `gh pr create`, `gh api`, `gh workflow run`, `gh run watch` subcommands confirmed; `--json`, `--jq`, `--paginate` flags documented; `{owner}/{repo}` auto-substitution in API paths confirmed.

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

## Windows host: stop the GCM "select account" prompt on `git push`

This applies on the **Windows host**, not the forge. Symptom: every `git push` to github.com over HTTPS pops a Git Credential Manager UI dialog asking which Microsoft / GitHub account to use, even after `gh auth login`. Cause: `gh auth login` writes a token to the OS keyring (where `gh` reads it), but Git for Windows ships with `credential.helper=manager` at system scope (`/etc/gitconfig` of the Git for Windows installation), and Git's credential helper chain never asks `gh` — it asks GCM, which prompts.

**Fix:** make `gh` Git's helper for github.com only.

```sh
gh auth setup-git                      # configures all hosts gh is logged into
gh auth setup-git --hostname github.com   # restrict to github.com
```

`gh auth setup-git` writes a per-host helper to `~/.gitconfig`:

```ini
[credential "https://github.com"]
    helper = !"C:/Program Files/GitHub CLI/gh.exe" auth git-credential
```

Per-URL helpers take precedence over the system-scope `credential.helper` per <https://git-scm.com/docs/gitcredentials>:

> "Helpers are first listed under the topmost matching `credential.helper` configuration. … Per-URL configuration `credential.<url>.helper` takes precedence over the unscoped value."

Verify:

```sh
git config --get-all credential.helper                              # system-level GCM (unchanged)
git config --get-all credential.https://github.com.helper           # the gh helper (added)
gh auth status                                                       # token present in keyring
```

After this, the next `git push` to github.com runs `gh auth git-credential get`, which reads the keyring token and writes `username=…\npassword=…` to stdout — Git accepts that and never invokes GCM. Other hosts still go through GCM as before.

### When `gh auth setup-git` isn't an option

Direct GCM tuning, per <https://github.com/git-ecosystem/git-credential-manager/blob/main/docs/configuration.md>:

| Symptom | Config | Effect |
|---|---|---|
| Headless / CI: refuse all UI | `git config --global credential.interactive false` or env `GCM_INTERACTIVE=Never` | GCM errors instead of prompting |
| Multiple GitHub accounts shown | `git config --global credential.https://github.com.username <login>` | GCM prefers that account on retrieve |
| Don't store on this host | `git config --global credential.https://github.com.credentialStore none` | GCM forwards but doesn't persist |

### Inspect Windows Credential Manager from the shell

`cmdkey /list` enumerates Generic Credentials stored by GCM (per <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/cmdkey>). GCM stores under target names like `git:https://github.com`. Note `cmdkey` won't display passwords — only target names — so it's a discovery tool, not an audit tool. For the GUI: Control Panel → User Accounts → Credential Manager → Windows Credentials.

### What `gh auth login` actually stores

`gh` puts the OAuth token in the Windows Credential Manager via `wincred` under target `gh:github.com`. `gh auth status` reads it; `gh auth token` prints it; `cmdkey /list:gh:github.com` shows the target exists. Removing the entry there is equivalent to `gh auth logout`.

## Forge-specific

- The forge has NO GitHub token. Any `gh` command requiring auth fails with `gh auth login` prompts (which themselves fail — no browser, no keyring).
- Read-only `gh` commands using the public API may work via the proxy, but only if `api.github.com` is in the proxy allowlist. By default it is not.
- Token-bearing operations (`pr create`, `workflow run`, `api` mutations, `release upload`) belong on the host, not in the forge.
- The git push path is the enclave mirror, not GitHub directly — see `runtime/networking.md`. `gh repo clone` would bypass that and try a direct fetch, which the proxy will refuse.
- For "I just need to know if my PR merged": run `gh pr view <n> --json state` on the host and paste the result back into the forge session.

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: upstream license redistribution status not granted (or off-allowlist).
> See `cheatsheets/license-allowlist.toml` for the per-domain authority.
>
> When you need depth beyond the summary above, materialize the source into
> the per-project pull cache by following the recipe below. The proxy
> (HTTP_PROXY=http://proxy:3128) handles fetch transparently — no credentials
> required.

<!-- TODO: hand-curate the recipe before next forge build -->

### Source

- **Upstream URL(s):**
  - `https://cli.github.com/manual/`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/cli.github.com/manual/`
- **License:** see-license-allowlist
- **License URL:** https://cli.github.com/manual/

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/cli.github.com/manual/"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://cli.github.com/manual/" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/utils/gh.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `utils/git.md` — local VCS, the layer below `gh`
- `runtime/networking.md` — proxy egress rules, why direct GitHub access is blocked
- `utils/jq.md` — for transforms beyond what embedded `--jq` handles
- `agents/openspec.md` — `gh pr create` is part of the archive workflow
