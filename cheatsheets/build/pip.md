---
tags: []  # TODO: add 3-8 kebab-case tags on next refresh
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://pip.pypa.io/en/stable/cli/pip_install/
  - https://peps.python.org/pep-0668/
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---
# pip

@trace spec:agent-cheatsheets

## Provenance

- pip install documentation (pip.pypa.io): <https://pip.pypa.io/en/stable/cli/pip_install/> — install, -r, -c (constraints), -e (editable), extras [dev,test], git+https:// VCS, -U upgrade, --dry-run, --no-deps, --user, --break-system-packages / PEP 668
- PEP 668 — Marking Python base environments as externally managed: <https://peps.python.org/pep-0668/> — externally-managed-environment error behavior
- **Last updated:** 2026-04-25

**Version baseline**: pip 24.x bundled with Python 3.13 (Fedora 43).
**Use when**: installing Python packages — but in the forge prefer per-project venvs (PEP 668 blocks bare `pip install`).

## Quick reference

| Task | Command |
|------|---------|
| Install latest | `pip install <pkg>` |
| Install pinned | `pip install '<pkg>==1.2.3'` |
| Install from req file | `pip install -r requirements.txt` |
| Install with constraints | `pip install -r requirements.txt -c constraints.txt` |
| Install editable (local) | `pip install -e .` |
| Install with extras | `pip install '<pkg>[dev,test]'` |
| Install from VCS | `pip install 'git+https://github.com/u/r@tag'` |
| Upgrade | `pip install -U <pkg>` |
| Upgrade everything eagerly | `pip install -U --upgrade-strategy eager -r requirements.txt` |
| Uninstall | `pip uninstall -y <pkg>` |
| List installed | `pip list` (or `pip list --outdated`) |
| Freeze pins | `pip freeze > requirements.txt` |
| Show metadata | `pip show <pkg>` (`-f` for files) |
| Dry run | `pip install --dry-run <pkg>` |
| No deps (advanced) | `pip install --no-deps <pkg>` |
| Cache info / purge | `pip cache info` / `pip cache purge` |

## Common patterns

### Pattern 1 — per-project venv + requirements.txt

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -U pip
pip install -r requirements.txt
```

The default flow inside the forge. The venv lives under the project tree (persisted in git checkout), not in `~/.local`.

### Pattern 2 — constraints.txt for transitive pinning

```bash
# requirements.txt: direct deps only (e.g. "django", "celery")
# constraints.txt:  full pin set (e.g. "urllib3==2.2.1", "redis==5.0.4")
pip install -r requirements.txt -c constraints.txt
```

`-c` pins transitives without forcing them to be installed. Lets you keep direct deps loose while making builds reproducible.

### Pattern 3 — editable install for local development

```bash
pip install -e '.[dev]'
```

Symlinks the source tree into site-packages — code edits are picked up without reinstall. `[dev]` pulls extras declared in `pyproject.toml`.

### Pattern 4 — pip-tools (pip-compile) workflow

```bash
pipx install pip-tools
pip-compile pyproject.toml -o requirements.txt    # resolve + pin
pip-sync requirements.txt                          # match env exactly
```

Deterministic builds without committing to poetry/uv. `pip-sync` adds *and removes* packages so the venv matches the lockfile.

### Pattern 5 — pipx run for one-shot tools

```bash
pipx run cookiecutter gh:user/template
pipx run --spec 'httpie==3.2.4' http GET https://api.example
```

No install, no venv — pipx caches and runs. Good for "I need this tool once" without polluting any environment.

## Common pitfalls

- **Bare `pip install` blocked by PEP 668** — the forge's system Python is marked externally-managed; `pip install <pkg>` fails with `error: externally-managed-environment`. Activate a venv first, use `pipx`, or (last resort, never in forge) pass `--break-system-packages`.
- **`pip install --user` is ephemeral in the forge** — writes to `~/.local/lib/...`, which lives on the container's overlay fs and vanishes on stop. Use a project-local `.venv` instead.
- **`--break-system-packages` on system Python** — silently mutates the host/container Python that other tools depend on. Never use this; it's an anti-pattern outside one-off recovery scenarios.
- **`--no-deps` without pinning all transitives** — produces an installation that imports but breaks at runtime when an unpinned dep is missing or the wrong version. Only safe when paired with a fully resolved constraints/lock file.
- **Mixing `requirements.txt` and `pyproject.toml` deps** — when both exist, `pip install -e .` reads `pyproject.toml` and ignores `requirements.txt`. Pick one source of truth (modern projects: `pyproject.toml` + `pip-compile`).
- **Default `--upgrade-strategy only-if-needed` re-uses stale transitives** — `pip install -U <pkg>` upgrades `<pkg>` but leaves its old deps. Pass `--upgrade-strategy eager` when you want everything bumped.
- **`pip freeze` includes editable installs and venv-internal pkgs** — output isn't directly reusable as `requirements.txt`. Filter with `pip freeze --exclude-editable` or use `pip-compile`.
- **`pip install --user` *with* a venv active** — writes to `~/.local` instead of the venv (and gets shadowed by venv site-packages). Behavior is confusing; `--user` is meaningless inside a venv.
- **Installing from `git+https://…` without a tag/sha** — pulls `HEAD` of the default branch; non-reproducible. Always pin: `git+https://…@v1.2.3` or `@<sha>`.
- **No proxy CA in custom Python builds** — if you replace system Python, `pip` won't trust the forge proxy CA. Set `PIP_CERT=/etc/pki/ca-trust/source/anchors/proxy-ca.crt` or use the system Python.

## Forge-specific

- The forge ships **pipx** with these tools pre-installed globally under `/opt/pipx` (on PATH): `ruff`, `black`, `mypy`, `pytest`, `httpie`, `uv`, `poetry`. Don't reinstall them per-project — just call them.
- For project deps, always create `.venv` inside the project tree. `~/.local` and `~/.cache/pip` are on the ephemeral overlay; the project tree (under git mirror clone) is the durable surface.
- Outbound traffic goes through the forge proxy. `pip` honours `https_proxy`/`HTTPS_PROXY` from the env automatically — no extra config needed when the env is set by the enclave.

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
  - `https://pip.pypa.io/en/stable/cli/pip_install/`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/pip.pypa.io/en/stable/cli/pip_install/`
- **License:** see-license-allowlist
- **License URL:** https://pip.pypa.io/en/stable/cli/pip_install/

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/pip.pypa.io/en/stable/cli/pip_install/"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://pip.pypa.io/en/stable/cli/pip_install/" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/build/pip.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `build/pipx.md` — global isolated tool installs (where ruff/black/mypy live)
- `build/uv.md` — drop-in pip replacement, much faster
- `build/poetry.md` — project-manager alternative with lockfile
- `languages/python.md` — language reference and idioms
- `runtime/forge-container.md` — why `~/.local` is ephemeral, why per-project venvs
