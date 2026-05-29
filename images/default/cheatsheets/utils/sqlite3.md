---
tags: [sqlite, sql, cli, database]
languages: [sql]
since: 2026-05-19
last_verified: 2026-05-19
sources:
  - https://sqlite.org/cli.html
  - https://sqlite.org/lang.html
authority: high
status: draft
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# sqlite3 CLI

@trace spec:agent-cheatsheets

**Use when**: inspecting or scripting SQLite databases with the `sqlite3` command-line shell.

## Provenance

- SQLite CLI docs: <https://sqlite.org/cli.html>
- SQLite SQL language docs: <https://sqlite.org/lang.html>
- **Last updated:** 2026-05-19

## Quick reference

| Command | Purpose |
|---|---|
| `sqlite3 db.sqlite` | Open a database |
| `.tables` | List tables |
| `.schema table` | Show table DDL |
| `.mode box` | Human-readable table output |
| `.headers on` | Print column names |
| `.dump` | Emit SQL dump |
| `.read file.sql` | Execute a script |

## Common patterns

### Inspect a table

```bash
sqlite3 app.db
.headers on
.mode box
SELECT * FROM users LIMIT 20;
```

### Run one query from shell

```bash
sqlite3 app.db "SELECT count(*) FROM events;"
```

### Enable WAL for local apps

```sql
PRAGMA journal_mode=WAL;
```

## Common pitfalls

- **Single writer model** - SQLite can handle many readers, but only one writer at a time.
- **Shell dot commands are not SQL** - `.schema` and `.mode` only work in the CLI.
- **Type affinity surprises** - SQLite is permissive compared with server databases.
- **Relative database paths** - scripts may create a new empty database in the wrong directory.

## See also

- `languages/sql.md` - SQL syntax baseline
- `data/postgresql-indexing-basics.md` - contrast with PostgreSQL server behavior

## Pull on Demand

### Source

This is a compact anchor cheatsheet. Pull SQLite docs when implementation work depends on pragmas, virtual tables, JSON1, or exact SQL grammar.

- **Upstream URL(s):**
  - `https://sqlite.org/cli.html`
  - `https://sqlite.org/lang.html`
- **Archive type:** single-page references
- **Expected size:** `<1 MB`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/utils/sqlite3`
- **License:** public-domain documentation
- **License URL:** `https://sqlite.org/copyright.html`

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/utils/sqlite3"
mkdir -p "$TARGET"
cp cheatsheets/utils/sqlite3.md "$TARGET/index.md"
```

### Generation guidelines (after pull)

1. Check whether the target SQLite build includes optional extensions such as JSON1.
2. Keep CLI dot commands separate from SQL examples.
