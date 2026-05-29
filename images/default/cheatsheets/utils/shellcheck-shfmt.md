---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://www.shellcheck.net/wiki/
  - https://github.com/koalaman/shellcheck
  - https://github.com/mvdan/sh
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# shellcheck + shfmt

@trace spec:agent-cheatsheets

**Version baseline**: ShellCheck 0.10.x, shfmt 3.8.x (added to forge by `agent-source-of-truth` change).
**Use when**: linting / formatting bash scripts before committing them.

## Provenance

- ShellCheck wiki (official, koalaman/shellcheck): <https://www.shellcheck.net/wiki/> — per-code explanations including SC1091 (not following source)
- ShellCheck GitHub repository: <https://github.com/koalaman/shellcheck> — flag reference (`-S`, `-e`, `-i`, `-x`, `-f`, `-P`)
- shfmt GitHub repository (mvdan/sh): <https://github.com/mvdan/sh> — flag reference (`-i`, `-bn`, `-ci`, `-sr`, `-d`, `-l`, `-w`, `-s`); latest stable v3.13.1
- **Last updated:** 2026-04-25

Verified: SC1091 is "not following source" (confirmed in wiki); shfmt v3.13.1 is the latest stable as of 2026-04-06 (confirmed in repository); ShellCheck `-S` severity, `-e` exclude, `-x` follow sources all documented in the repository.

## Quick reference

### shellcheck

| Flag | Effect |
|------|--------|
| `-S <severity>` | minimum severity to report: `error`, `warning`, `info`, `style` (default `style`) |
| `-e <SCxxxx>` | exclude one or more check codes (comma- or space-separated) |
| `-i <SCxxxx>` | include only listed codes (inverse of `-e`) |
| `--shell bash` | force dialect when the shebang is missing or wrong (also `sh`, `dash`, `ksh`) |
| `-f <fmt>` | output format: `tty` (default), `gcc`, `checkstyle`, `diff`, `json`, `json1` |
| `-x` / `--external-sources` | follow `source` / `.` directives into other files |
| `-W <n>` | wrap output column width (default 80; `0` disables) |
| `-P <dir>` | search path for sourced files (repeatable) |
| `-a` / `--check-sourced` | also lint files brought in via `source` |

### shfmt

| Flag | Effect |
|------|--------|
| `-i <n>` | indent width (`0` = tabs, `2`/`4` = spaces) |
| `-bn` | binary ops (`&&`, `\|\|`) start the next line |
| `-ci` | indent `case` branch bodies |
| `-sr` | space after redirect operators (`> file`, not `>file`) |
| `-kp` | keep column alignment padding |
| `-fn` | function opening brace on next line |
| `-d` | print unified diff vs current file (no write) |
| `-l` | list files that would be reformatted |
| `-w` | write changes back in place (default is stdout) |
| `-s` | simplify the script (drops redundant constructs) |

## Common patterns

### Pattern 1 — lint a single script

```bash
shellcheck scripts/build-image.sh
```

Default severity is `style`, so everything surfaces. Pair with `-S warning` in CI to gate only on real bugs.

### Pattern 2 — lint with sourced helpers

```bash
shellcheck -x -P scripts -e SC1091 scripts/build-image.sh
```

`-x` follows `source` lines; `-P` adds a search root. `SC1091` ("can't follow non-constant source") is the noisy one to silence when paths are computed at runtime.

### Pattern 3 — preview a format diff

```bash
shfmt -i 4 -ci -sr -d scripts/
```

`-d` prints a unified diff for every file under `scripts/`. Review before adding `-w`.

### Pattern 4 — format in place

```bash
shfmt -i 4 -ci -sr -w scripts/build-image.sh
```

Standard Tillandsias style: 4-space indent, `case` bodies indented, spaces after redirects.

### Pattern 5 — pre-commit pair

```bash
shfmt -i 4 -ci -sr -d scripts/ && shellcheck -S warning scripts/*.sh
```

Format-check first (cheap, deterministic), then lint. Both exit non-zero on findings, so a single `&&` chain works as a gate.

## Common pitfalls

- **shellcheck doesn't follow sources by default** — `source lib/foo.sh` is reported as SC1091 unless you pass `-x`. Once enabled, missing files become real errors; silence only the unreachable ones with `-e SC1091` or `# shellcheck disable=SC1091` above the line.
- **shfmt's indent style is opinionated** — POSIX scripts often use 0 (tabs); the project uses `-i 4`. Pass it consistently or shfmt will flap files between tabs and spaces every run.
- **SC2086 is usually right, sometimes intentional** — `rm $files` triggers "double-quote to prevent globbing/word-splitting". When word-splitting is the goal (e.g. expanding a flag list), annotate locally: `# shellcheck disable=SC2086`. Don't disable globally.
- **`shfmt -w` overwrites without backup** — there is no `.bak`. Always run `-d` first, or commit before formatting so `git diff` is your safety net.
- **Some shellcheck warnings are pedantic** — SC2155 ("declare and assign separately") and SC2250 ("prefer `${var}`") are style-level. Use `-S warning` in CI so only `error`/`warning` block the build; let `style` and `info` stay advisory.
- **Dialect detection trips on `#!/usr/bin/env bash`** — both tools handle it, but a missing shebang silently falls back to `sh` (stricter). Add `--shell bash` (shellcheck) or `-ln bash` (shfmt) when scanning unshebanged fragments.
- **shfmt rewrites heredocs** — leading tabs inside `<<-EOF` are stripped per POSIX; if your heredoc contents rely on specific whitespace (e.g. embedded YAML), use `<<EOF` (no dash) so shfmt leaves it alone.

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
  - `https://www.shellcheck.net/wiki/`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/www.shellcheck.net/wiki/`
- **License:** see-license-allowlist
- **License URL:** https://www.shellcheck.net/wiki/

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/www.shellcheck.net/wiki/"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://www.shellcheck.net/wiki/" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/utils/shellcheck-shfmt.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `languages/bash.md`
