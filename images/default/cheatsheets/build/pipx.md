---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://pipx.pypa.io/stable/
  - https://pipx.pypa.io/stable/reference/
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# pipx

@trace spec:agent-cheatsheets

## Provenance

- pipx documentation (pipx.pypa.io): <https://pipx.pypa.io/stable/> — overview of pipx install/run/inject/upgrade workflow and PIPX_HOME/PIPX_BIN_DIR env vars
- pipx CLI reference: <https://pipx.pypa.io/stable/reference/> — full command flags: install (--global, --suffix, --python), inject, run (--spec), upgrade/upgrade-all, reinstall-all, uninstall, list (--include-injected), ensurepath
- **Last updated:** 2026-04-25

**Version baseline**: pipx 1.7+ (Fedora 43). Forge ships `PIPX_HOME=/opt/pipx` with `PIPX_BIN_DIR=/usr/local/bin`.
**Use when**: installing Python CLI tools globally without polluting project envs.

## Quick reference

| Command | Effect |
|---|---|
| `pipx install <tool>` | Install `<tool>` into a dedicated venv; binary symlinked to `PIPX_BIN_DIR` |
| `pipx install --global <tool>` | System-wide install (needs root); binaries land in `/usr/local/bin` |
| `pipx install --suffix=@2 <tool>==2.0` | Install side-by-side under a suffixed name (`<tool>@2`) |
| `pipx install --python /usr/bin/python3.12 <tool>` | Pin the interpreter for the venv |
| `pipx inject <tool> <plugin>...` | Add extra packages into an existing tool's venv |
| `pipx run <tool> [args]` | One-shot: download to a cache, run, discard |
| `pipx run --spec <pkg> <entrypoint>` | Run a script whose entrypoint name differs from the package |
| `pipx upgrade <tool>` / `pipx upgrade-all` | Upgrade one / every managed tool |
| `pipx reinstall-all --python <ver>` | Rebuild every venv against a new interpreter |
| `pipx uninstall <tool>` / `pipx uninstall-all` | Remove one / all managed tools |
| `pipx list [--include-injected]` | List installed tools (and injected packages) |
| `pipx ensurepath` | Add `PIPX_BIN_DIR` to shell rc files |

## Common patterns

### Pattern 1 — Install a CLI tool

```bash
pipx install ruff
ruff --version                 # resolved via PIPX_BIN_DIR on PATH
```

### Pattern 2 — One-shot run (no install)

```bash
pipx run cookiecutter gh:audreyfeldroy/cookiecutter-pypackage
# venv cached under ~/.local/pipx/.cache; reused on subsequent runs of same spec
```

### Pattern 3 — Inject plugins into a tool's venv

```bash
pipx install mkdocs
pipx inject mkdocs mkdocs-material mkdocstrings[python]
mkdocs build                   # plugins resolved inside mkdocs's venv
```

### Pattern 4 — Side-by-side versions via `--suffix`

```bash
pipx install --suffix=@1 poetry==1.8.3
pipx install --suffix=@2 poetry==2.0.0
poetry@1 --version
poetry@2 --version
```

### Pattern 5 — Upgrade everything

```bash
pipx upgrade-all               # respects each venv's pinned python
pipx reinstall-all --python python3.13   # migrate all tools to a new interpreter
```

## Common pitfalls

- **`pipx install` is per-user by default** — venvs land under `$PIPX_HOME` (default `~/.local/pipx`); `--global` is required for `/opt/pipx` and needs root. Mixing the two leads to "command not found" when you `sudo` later.
- **`pipx run` is not free** — first invocation of a given spec downloads the package and builds a venv. The cache is keyed on the exact spec string; `pipx run black` and `pipx run black==24.0` are two different caches that both consume disk.
- **`--python` only sees interpreters already on the system** — pipx does not download Python. If `python3.12` is missing, the install fails with a confusing "no such file" rather than a version error. Pair with `uv python install` or system packages.
- **`pipx inject` does not work for every tool** — the target tool must import the injected package at runtime; many CLIs hard-code their dependency list and ignore extras. Check the tool's plugin docs before relying on `inject`.
- **Name collisions across packages silently overwrite** — two packages exposing a `serve` entrypoint will fight for the same symlink. Use `--suffix` or `--force` deliberately; `pipx list` shows which package owns each binary.
- **`pipx ensurepath` edits `~/.bashrc` and `~/.zshrc`** — harmless on a workstation, but inside the forge those rc files are regenerated on container stop. Bake `PIPX_BIN_DIR` into the image instead.
- **Upgrades respect pinned versions in the venv's `pip` metadata, not your shell** — `pipx upgrade ruff` will refuse to cross a major version if the original install pinned `ruff<1`. Re-`install --force` to break the pin.
- **`pipx run --spec` is mandatory when entrypoint != package name** — `pipx run flake8-bugbear` fails because the package has no `flake8-bugbear` entrypoint; use `pipx run --spec flake8-bugbear flake8`.

## Pre-installed in the forge

The forge image baked these via `pipx install --global`:

- **ruff** — linting + formatting Python
- **black** — formatting Python (partial overlap with ruff)
- **mypy** — static type checking Python
- **pytest** — test runner
- **httpie** — curl alternative for HTTP work
- **uv** — fast pip replacement
- **poetry** — Python project manager

So you don't need to install any of them — they're on `PATH` already.

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
  - `https://pipx.pypa.io/stable/`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/pipx.pypa.io/stable/`
- **License:** see-license-allowlist
- **License URL:** https://pipx.pypa.io/stable/

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/pipx.pypa.io/stable/"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://pipx.pypa.io/stable/" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/build/pipx.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `build/pip.md`, `build/uv.md`, `build/poetry.md`
- `languages/python.md`
