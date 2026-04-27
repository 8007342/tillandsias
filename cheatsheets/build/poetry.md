---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://python-poetry.org/docs/cli/
  - https://python-poetry.org/docs/configuration/
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# Poetry

@trace spec:agent-cheatsheets

## Provenance

- Poetry CLI documentation (python-poetry.org): <https://python-poetry.org/docs/cli/> — all commands: init/new/install (--sync/--no-root)/add (--group dev)/remove/update/lock/run/shell/build/publish/version/env info/env list
- Poetry configuration documentation: <https://python-poetry.org/docs/configuration/> — virtualenvs.in-project setting (puts .venv inside project dir)
- **Last updated:** 2026-04-25

**Version baseline**: Poetry 1.8+ (installed via pipx in the forge).
**Use when**: project-style Python with strict dep management — alternative to `pip + venv` or `uv`.

## Quick reference

| Command | Effect |
|---|---|
| `poetry init` | Interactive `pyproject.toml` scaffold (no install) |
| `poetry new <name>` | Create project skeleton + package directory |
| `poetry install` | Install all deps from lockfile into the project venv |
| `poetry install --sync` | Install + remove anything not in the lockfile (mirror lock state) |
| `poetry install --no-root` | Install deps but skip the current project (CI / Dockerfile) |
| `poetry add <pkg>` | Add runtime dep, update lockfile + venv |
| `poetry add --group dev <pkg>` | Add to the `dev` group (test/lint tooling) |
| `poetry remove <pkg>` | Drop dep + refresh lockfile |
| `poetry update [<pkg>]` | Re-resolve to latest within `pyproject.toml` constraints |
| `poetry lock --no-update` | Refresh lockfile metadata without changing versions |
| `poetry run <cmd>` | Run a one-off command inside the venv |
| `poetry shell` | Spawn an interactive subshell in the venv |
| `poetry build` | Produce sdist + wheel in `dist/` |
| `poetry publish -r <repo>` | Upload to a configured index (PyPI by default) |
| `poetry version [patch\|minor\|major]` | Read or bump the project version |
| `poetry env info` / `poetry env list` | Show / list managed venvs |

`pyproject.toml` shape:

```toml
[tool.poetry]
name = "myproj"
version = "0.1.0"

[tool.poetry.dependencies]
python = "^3.11"
httpx  = "^0.27"

[tool.poetry.group.dev.dependencies]
pytest = "^8"
```

## Common patterns

### Pattern 1 — Bootstrap a project

```bash
poetry init --no-interaction --name myproj --python "^3.11"
poetry add httpx
poetry add --group dev pytest ruff
```

### Pattern 2 — Reproducible installs (CI / forge)

```bash
poetry install --sync --no-interaction --no-ansi
# --sync prunes stale deps; matches lockfile exactly
```

### Pattern 3 — Run vs shell

```bash
poetry run pytest -q              # one-shot, no shell state
poetry shell                      # interactive subshell; exit to leave
```

Prefer `poetry run` in scripts and CI; reserve `poetry shell` for interactive work.

### Pattern 4 — Cut a release

```bash
poetry version minor              # 0.1.0 -> 0.2.0
poetry build                      # dist/myproj-0.2.0-py3-none-any.whl
poetry publish                    # uploads sdist + wheel
```

### Pattern 5 — Dev vs runtime groups

```bash
poetry add --group dev pytest mypy ruff
poetry install --without dev      # production install (skip dev group)
poetry install --only dev         # CI lint job (dev tools only)
```

## Common pitfalls

- **Default venv lives in the cache** (`~/.cache/pypoetry/virtualenvs/`) — invisible from the project tree, opaque to editors. Configure once: `poetry config virtualenvs.in-project true` so each project gets a local `.venv/` that survives editor discovery and `rm -rf`.
- **`poetry update` ignores `pyproject.toml` constraints by name only** — without `--no-update` flags on adjacent commands, transitive deps drift on every `add`/`remove`. Use `poetry lock --no-update` to refresh metadata while pinning versions.
- **Lockfile incompat across major Poetry versions** — a Poetry 2.x `poetry.lock` will warn or refuse to install on 1.x and vice versa. Pin Poetry itself in CI (`pipx install poetry==1.8.3`) and document the version in your README.
- **Plugin system requires `poetry self add`** — plugins do NOT install via `pip install` into the venv; they must be added to Poetry's own environment. Inside the forge that means `pipx inject poetry <plugin>`.
- **Slow on large lock graphs** — resolution time grows nonlinearly with dep count and version ranges. For monorepos or projects with hundreds of deps, `uv` is dramatically faster. Profile with `poetry install -vvv` if installs feel pathological.
- **`poetry shell` may break under `set -e` scripts** — it spawns a subshell and inherits flags; prefer `poetry run` in any non-interactive context.
- **`--no-root` is mandatory in Dockerfiles** — without it, Poetry tries to install your unbuilt project as a package, which fails before the source is COPYed in. Standard pattern: copy `pyproject.toml` + `poetry.lock`, run `poetry install --no-root --sync`, then COPY source.

## When to choose Poetry vs uv vs pip

| Tool | Pick when |
|---|---|
| **Poetry** | Mature ecosystem, established team workflow, you need build/publish + dep management in one tool, plugins matter |
| **uv** | Speed matters (10-100x faster resolves), greenfield projects, monorepo or large lock graphs, you want a single static binary |
| **pip + pip-tools** | Minimal toolchain, scripts not packages, you want maximum compatibility with legacy tooling |

Project teams typically choose based on existing investment — switching costs (lockfile format, CI scripts, contributor muscle memory) usually outweigh raw speed gains until a project hits real resolution pain.

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
  - `https://python-poetry.org/docs/cli/`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/python-poetry.org/docs/cli/`
- **License:** see-license-allowlist
- **License URL:** https://python-poetry.org/docs/cli/

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/python-poetry.org/docs/cli/"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://python-poetry.org/docs/cli/" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/build/poetry.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `build/pip.md`, `build/uv.md`
- `languages/python.md`
