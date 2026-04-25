# pytest

@trace spec:agent-cheatsheets

**Version baseline**: pytest 8.x (installed via pipx in forge, on PATH).
**Use when**: testing Python — discovery, fixtures, parametrize.

## Quick reference

| Command / Flag | Effect |
|---|---|
| `pytest` | Discover and run all tests under cwd |
| `pytest path/to/test_x.py::TestClass::test_y` | Run a single test by node id |
| `pytest -v` / `-q` | Verbose / quiet output |
| `pytest -x` | Stop on first failure |
| `pytest --maxfail=N` | Stop after N failures |
| `pytest -k "expr"` | Run tests whose name matches Python expr (`foo and not bar`) |
| `pytest -m "marker"` | Run tests bearing a `@pytest.mark.<marker>` tag |
| `pytest --lf` / `--ff` | Re-run only last-failed / failed-first |
| `pytest -s` | Disable output capture (see `print` and logs live) |
| `pytest --tb=short` / `--tb=line` / `--tb=no` | Traceback verbosity |
| `pytest -p no:<plugin>` | Disable a plugin for this run |
| `pytest --collect-only` | Show what would run without executing |

**Discovery rules** (silent skip if violated):
- Files: `test_*.py` or `*_test.py`
- Classes: `Test*` (no `__init__`)
- Functions / methods: `test_*`

## Common patterns

### Pattern 1 — Parametrize with readable ids

```python
import pytest

@pytest.mark.parametrize(
    "value,expected",
    [(1, 2), (10, 20), (-3, -6)],
    ids=["one", "ten", "neg-three"],
)
def test_double(value, expected):
    assert value * 2 == expected
```

### Pattern 2 — Fixture with scope

```python
@pytest.fixture(scope="session")
def db():
    conn = open_db()
    yield conn
    conn.close()
```

`scope=` is `function` (default), `class`, `module`, `package`, or `session`.

### Pattern 3 — Shared fixtures via `conftest.py`

```python
# tests/conftest.py — auto-discovered, no import needed
import pytest

@pytest.fixture
def sample_payload():
    return {"id": 1, "name": "tillandsia"}
```

Any test below `tests/` can request `sample_payload` as an argument.

### Pattern 4 — `monkeypatch` + `tmp_path`

```python
def test_writes_config(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    write_config()
    assert (tmp_path / ".myapp.toml").exists()
```

`tmp_path` is a fresh `pathlib.Path` per test; `monkeypatch` reverts on teardown.

### Pattern 5 — Marks: `skip`, `xfail`, `skipif`

```python
import sys, pytest

@pytest.mark.skip(reason="unimplemented")
def test_future(): ...

@pytest.mark.skipif(sys.platform == "win32", reason="POSIX only")
def test_unix_only(): ...

@pytest.mark.xfail(strict=True, reason="known regression")
def test_broken(): assert 1 == 2
```

`strict=True` flips an unexpected pass into a failure — catches accidental fixes.

## Common pitfalls

- **Discovery requires `test_*.py` / `*_test.py` naming** — a file named `tests.py` or `check_thing.py` is silently ignored. Same for functions: `check_foo` is collected as a regular function and never run. Symptom: "0 tests collected" with no error.
- **Test classes with `__init__` are silently skipped** — pytest refuses to instantiate them. Use bare classes (`class TestThing:`) and put setup in fixtures or `setup_method`.
- **Fixture name shadows an import** — `def test_x(json):` makes `json` the fixture argument, not the stdlib module. Rename the fixture or import as `import json as _json`.
- **`autouse=True` fixtures run for every test in scope** — including unrelated tests in the same module / package. Convenient for setup, but a slow autouse fixture taxes the whole suite. Scope it tightly (`scope="function"` + nested conftest).
- **`tmp_path` is per-test, `tmp_path_factory` is per-session** — using `tmp_path` in a `scope="session"` fixture raises `ScopeMismatch`. Switch to `tmp_path_factory.mktemp("name")` for shared temp dirs.
- **`@pytest.mark.skip` vs `@pytest.mark.skipif`** — `skip` always skips (often left in by accident); `skipif(condition, reason=...)` is conditional. Forgetting the `if` variant means the test never runs, even when fixed. CI doesn't fail — it reports "skipped".
- **`capsys` / `capfd` swallow output unless you use them or `-s`** — `print` debugging in a test produces nothing on stdout. Either request `capsys` and assert against `capsys.readouterr().out`, or run with `pytest -s`.
- **Plugin order matters** — `pytest-asyncio`, `pytest-django`, `pytest-trio` each install their own collection / fixture hooks. Conflicts surface as "fixture not found" or "event loop is closed". Pin plugin versions and check `pytest --trace-config` when something weird happens.
- **`pytest-asyncio` mode default changed in 0.21** — without `asyncio_mode = "auto"` in `pyproject.toml`, async tests need an explicit `@pytest.mark.asyncio` or they're collected as sync (and fail with a coroutine-never-awaited warning).
- **`-k` matches substrings, not whole names** — `-k slow` matches `test_slow`, `test_slowpath`, *and* `test_not_slow`. Use `-k "slow and not not_slow"` or rename tests to disambiguate.

## Forge-specific

pytest is pre-installed via pipx (`PIPX_HOME=/opt/pipx`, binary on `PATH`). For project tests requiring extra deps (plugins, libraries under test), install them in a per-project venv and run `python -m pytest` so the venv's site-packages — not the pipx venv — supplies imports.

```bash
python -m venv .venv && source .venv/bin/activate
pip install -e . pytest pytest-asyncio
python -m pytest
```

## See also

- `languages/python.md` — language reference
- `build/pipx.md`, `build/pip.md` — installing pytest and plugins
