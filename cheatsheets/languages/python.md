# Python

@trace spec:agent-cheatsheets

## Provenance

- Python 3 official documentation (docs.python.org): <https://docs.python.org/3/> — language reference, stdlib, what's new per version; covers f-string = syntax (3.8+), built-in generics list[int] (3.9+), X|Y union (3.10+), match/case (3.10+), dataclasses frozen/slots, asyncio, pathlib, subprocess
  local: `cheatsheet-sources/docs.python.org/3/index.html`
- Python language reference — dataclasses: <https://docs.python.org/3/library/dataclasses.html> — frozen, slots parameters
  local: `cheatsheet-sources/docs.python.org/3/library/dataclasses.html`
- Python language reference — asyncio: <https://docs.python.org/3/library/asyncio.html> — asyncio.run(), gather(), sleep()
  local: `cheatsheet-sources/docs.python.org/3/library/asyncio.html`
- **Last updated:** 2026-04-25

**Version baseline**: Python 3.13.x (Fedora 43 `python3` package)
**Use when**: writing Python in the forge — syntax, idioms, packaging.

## Quick reference

| Task | Command / syntax |
|------|------------------|
| Run script | `python3 script.py` |
| REPL | `python3` (or `python3 -i script.py` to drop in after) |
| One-liner | `python3 -c "import sys; print(sys.version)"` |
| Module as script | `python3 -m http.server 8000` |
| Per-project venv | `python3 -m venv .venv && source .venv/bin/activate` |
| Install in venv | `pip install <pkg>` (after activation) |
| f-string debug (3.8+) | `f"{value=}"` -> `value=42` |
| Type hint built-ins (3.9+) | `list[int]`, `dict[str, int]` (no `typing` import) |
| Union (3.10+) | `int \| str` (no `Union[...]`) |
| Match (3.10+) | `match x: case 0: ...` |
| Type params (3.12+) | `def f[T](x: T) -> T:` |
| Walrus | `if (n := len(items)) > 10:` |
| Pathlib | `from pathlib import Path; Path("x").read_text()` |
| Run tests | `pytest` (pre-installed via pipx) |
| Format / lint | `ruff format .` / `ruff check --fix .` |
| Type-check | `mypy .` |

## Common patterns

### Type hints + dataclass
```python
from dataclasses import dataclass, field

@dataclass(frozen=True, slots=True)
class Point:
    x: float
    y: float
    tags: list[str] = field(default_factory=list)
```
`frozen=True` -> hashable & immutable. `slots=True` (3.10+) cuts memory and blocks attribute typos.

### Structural pattern matching (3.10+)
```python
def describe(obj: object) -> str:
    match obj:
        case {"type": "user", "name": str(name)}:
            return f"user:{name}"
        case [x, y, *_]:
            return f"pair:{x},{y}"
        case _:
            return "unknown"
```
Patterns bind names. Use `case Class(field=val)` for class matching.

### Async basics
```python
import asyncio

async def fetch(n: int) -> int:
    await asyncio.sleep(0.1)
    return n * 2

async def main() -> None:
    results = await asyncio.gather(*(fetch(i) for i in range(5)))
    print(results)

asyncio.run(main())
```
`asyncio.run()` is the entry point. Never call it from inside a running loop.

### Pathlib + JSON over open()
```python
import json
from pathlib import Path

config = json.loads(Path("config.json").read_text())
Path("out.json").write_text(json.dumps(config, indent=2))
```
Pathlib avoids `with open(...)` boilerplate for one-shot reads/writes.

### subprocess (modern form)
```python
import subprocess

result = subprocess.run(
    ["git", "rev-parse", "HEAD"],
    capture_output=True, text=True, check=True,
)
sha = result.stdout.strip()
```
Always pass a list (not a string + `shell=True`). `check=True` raises on non-zero exit.

## Common pitfalls

- **Mutable default arguments** — `def f(x=[]):` shares the same list across calls. Use `def f(x: list | None = None): x = x or []` or `field(default_factory=list)` in dataclasses.
- **Late-binding closures in loops** — `[lambda: i for i in range(3)]` all return `2`. Bind explicitly: `lambda i=i: i`.
- **`is` vs `==`** — `is` checks identity, not equality. `x == 1000 is True` for ints; `x is 1000` is implementation-defined. Only use `is` for `None`, `True`, `False`.
- **`pip install --user` in the forge** — writes to `~/.local`, which is on the ephemeral overlay and lost on container stop. Always create a per-project `.venv` inside `/home/forge/src/<project>/`.
- **`pip install <pkg>` without a venv** — fails on Fedora's PEP 668 externally-managed environment. Activate a venv first, or use `pipx` for global tools.
- **`except:` (bare)** — catches `KeyboardInterrupt` and `SystemExit`. Use `except Exception:` at minimum; better, name the exception.
- **Modifying a list while iterating** — `for x in lst: lst.remove(x)` skips elements. Iterate over a copy (`lst[:]`) or build a new list with a comprehension.
- **`asyncio.run()` inside an async function** — raises `RuntimeError`. Use `await` directly; `asyncio.run()` is only for the top-level sync entry point.
- **Forgetting `text=True` in subprocess** — without it, `stdout`/`stderr` are `bytes`, not `str`. `.strip()` works on both but string concatenation breaks.
- **`from module import *`** — pollutes namespace, breaks linters, hides origin of names. Prefer `import module` or explicit `from module import name`.
- **`dict.keys()` / `dict.values()` are views, not lists** — they reflect later mutations. Wrap in `list(...)` if you need a snapshot.

## See also

- `build/pip.md` — pip install / requirements.txt
- `build/pipx.md` — global tool install (where ruff/black/mypy/pytest live in the forge)
- `build/uv.md` — drop-in pip replacement
- `build/poetry.md` — alternative project manager
- `test/pytest.md` — testing framework
- `runtime/forge-container.md` — why per-project virtualenvs (not pip --user) in the forge
