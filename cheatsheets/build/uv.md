# uv

@trace spec:agent-cheatsheets

## Provenance

- uv documentation (docs.astral.sh): <https://docs.astral.sh/uv/> — project commands (uv init/add/remove/lock/sync/run), pip interface (uv pip install/uninstall/list/freeze/compile/sync), venv management, python management (uv python install/list), --frozen flag, uv.lock format
- uv pip interface reference: <https://docs.astral.sh/uv/pip/> — drop-in pip replacement semantics, --generate-hashes, uv pip compile (pip-tools replacement)
- **Last updated:** 2026-04-25

**Version baseline**: uv 0.4+ (installed via pipx in the forge, on `PATH` as `uv`).
**Use when**: you want a faster `pip` replacement or a reproducible Python project workflow (lockfile, pinned interpreter, managed venv).

## Quick reference

### `uv pip` — drop-in pip replacement

| Command | Effect |
|---|---|
| `uv pip install <pkg>` | Install into active venv (or system if none) — 10–100× faster than `pip` |
| `uv pip install -r requirements.txt` | Install from requirements file |
| `uv pip uninstall <pkg>` | Remove a package |
| `uv pip list` / `uv pip freeze` | Inspect installed packages |
| `uv pip compile requirements.in -o requirements.txt` | `pip-tools` replacement; resolves and pins |
| `uv pip sync requirements.txt` | Make env match the file exactly (removes extras) |

### `uv` project mode — lockfile-driven

| Command | Effect |
|---|---|
| `uv init` | Scaffold `pyproject.toml`, `.python-version`, `README.md` |
| `uv add <pkg>` | Add dep to `pyproject.toml` and update `uv.lock` |
| `uv add --dev <pkg>` | Add to dev-dependencies group |
| `uv remove <pkg>` | Drop dep, refresh lockfile |
| `uv lock` | Re-resolve and rewrite `uv.lock` without installing |
| `uv sync` | Materialise `.venv/` to match `uv.lock` exactly |
| `uv run <cmd>` | Run command inside the project venv (auto-syncs first) |

### `uv venv` and interpreter management

| Command | Effect |
|---|---|
| `uv venv` | Create `.venv/` in cwd (uses pinned interpreter if `.python-version` exists) |
| `uv venv --python 3.12` | Create venv with a specific CPython version (downloads if missing) |
| `uv python install 3.13` | Pre-fetch a managed CPython build |
| `uv python list` | Show available + installed interpreters |

## Common patterns

### Pattern 1 — Drop-in pip replacement

```bash
uv pip install requests httpx          # straight swap for `pip install`
uv pip install -r requirements.txt
```

Use inside an existing venv when you don't want to adopt `uv`'s project model.

### Pattern 2 — New project with lockfile

```bash
uv init my-app && cd my-app
uv add httpx 'pydantic>=2'
uv add --dev pytest ruff
uv run pytest                          # runs in auto-managed .venv
```

Produces `pyproject.toml` + `uv.lock`. Commit both.

### Pattern 3 — Reproducible install on another machine / in CI

```bash
uv sync --frozen                       # fail if uv.lock is stale, never re-resolve
uv run python -m my_app
```

`--frozen` is the CI-safe flag — guarantees the lockfile is the source of truth.

### Pattern 4 — `uv run` instead of activating

```bash
uv run python script.py                # no `source .venv/bin/activate` needed
uv run --with rich python -c 'import rich; rich.print("[bold]hi[/]")'
```

`--with` injects an ephemeral dep without touching `pyproject.toml`.

### Pattern 5 — `pip-compile` replacement

```bash
uv pip compile requirements.in -o requirements.txt --generate-hashes
uv pip sync requirements.txt
```

Faster than `pip-tools`, same input/output format.

## Common pitfalls

- **`uv pip` and `uv` project mode are different mental models** — `uv pip install` mutates the active venv ad-hoc; `uv add` updates `pyproject.toml` + `uv.lock` and re-syncs `.venv/`. Mixing them in one project leads to drift between the lockfile and what's actually installed. Pick one model per project.
- **`uv.lock` is uv-specific, not `requirements.txt`** — other tools (`pip`, Poetry, PDM) cannot read it. Export with `uv export --format requirements-txt -o requirements.txt` if you need interop with non-uv consumers.
- **Aggressive wheel cache can hide stale builds** — `uv` keeps a global cache at `~/.cache/uv/`; if you rebuild a local editable install and don't see changes, run `uv cache clean <pkg>` (or `uv pip install --refresh <pkg>`). Especially relevant for editable installs of native-extension packages.
- **`--python` only resolves to *available* CPython builds** — `uv` downloads managed CPython from `python-build-standalone`. PyPy, GraalPy, and distro Pythons are honoured if already on `PATH` but not auto-installed. `uv python install pypy@3.11` is the correct form for PyPy.
- **`.venv/` is project-local by default** — created in cwd, not in `~/.cache`. In the forge this means the venv lives under `/home/forge/src/<project>/.venv/` and is **ephemeral on container stop** unless the project dir is mounted. Re-`uv sync` is fast (cache hits), so this is usually fine; just don't be surprised when `python` is "missing" after a fresh attach.
- **`uv sync` removes packages not in the lockfile** — running it after a manual `uv pip install <pkg>` will silently uninstall that package. Add it via `uv add` instead, or accept the wipe.
- **Network egress goes through the enclave proxy** — `uv` honours `HTTPS_PROXY` / `SSL_CERT_FILE`; both are set in the forge. A "self-signed certificate in chain" error means the proxy CA isn't trusted — see `cheatsheets/utils/` proxy notes, not a `uv` bug.

## See also

- `build/pip.md` — the tool `uv pip` is replacing
- `build/poetry.md` — alternative project/lockfile workflow
- `languages/python.md` — language reference
