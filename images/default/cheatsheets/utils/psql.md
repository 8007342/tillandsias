---
tags: [postgresql, sql, cli, database]
languages: [sql]
since: 2026-05-19
last_verified: 2026-05-19
sources:
  - https://www.postgresql.org/docs/current/app-psql.html
authority: high
status: draft
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# psql CLI

@trace spec:agent-cheatsheets

**Use when**: inspecting PostgreSQL databases, running migrations manually, or debugging SQL from the terminal.

## Provenance

- PostgreSQL `psql` docs: <https://www.postgresql.org/docs/current/app-psql.html>
- **Last updated:** 2026-05-19

## Quick reference

| Command | Purpose |
|---|---|
| `psql "$DATABASE_URL"` | Connect using a URL |
| `\conninfo` | Show current connection |
| `\dt` | List tables |
| `\d table` | Describe relation |
| `\x auto` | Auto-expanded output |
| `\timing on` | Show query timings |
| `\copy ...` | Client-side import/export |

## Common patterns

### Fail fast in scripts

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f migration.sql
```

### Inspect indexes

```sql
\d+ table_name
SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'table_name';
```

### Copy query output to CSV

```sql
\copy (SELECT * FROM events) TO 'events.csv' WITH CSV HEADER
```

## Common pitfalls

- **Backslash commands are psql-only** - they are not SQL and will fail through app drivers.
- **Forgetting `ON_ERROR_STOP`** - shell scripts can continue after SQL errors without it.
- **Server-side `COPY` path confusion** - `COPY` reads on the server; `\copy` reads on the client.
- **Interactive transaction left open** - use `ROLLBACK` before leaving a failed transaction prompt.

## See also

- `languages/sql.md` - SQL syntax baseline
- `data/postgresql-indexing-basics.md` - index diagnostics and planner basics

## Pull on Demand

### Source

This is a compact anchor cheatsheet. Pull PostgreSQL docs when implementation work needs exact `psql` flags, formatting modes, or meta-command behavior.

- **Upstream URL(s):**
  - `https://www.postgresql.org/docs/current/app-psql.html`
- **Archive type:** single-page reference
- **Expected size:** `<1 MB`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/utils/psql`
- **License:** PostgreSQL documentation license
- **License URL:** `https://www.postgresql.org/about/licence/`

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/utils/psql"
mkdir -p "$TARGET"
cp cheatsheets/utils/psql.md "$TARGET/index.md"
```

### Generation guidelines (after pull)

1. Distinguish psql meta-commands from SQL that application drivers can run.
2. Use `ON_ERROR_STOP=1` in shell automation examples.
