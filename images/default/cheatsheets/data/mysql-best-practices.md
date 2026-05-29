---
tags: [mysql, sql, database, indexing]
languages: [sql]
since: 2026-05-19
last_verified: 2026-05-19
sources:
  - https://dev.mysql.com/doc/
  - https://dev.mysql.com/doc/refman/8.4/en/optimization-indexes.html
authority: high
status: draft
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# MySQL best practices

@trace spec:agent-cheatsheets

**Use when**: comparing MySQL behavior with PostgreSQL or writing portable SQL where storage engine, index, and transaction semantics matter.

## Provenance

- MySQL documentation: <https://dev.mysql.com/doc/>
- MySQL indexing docs: <https://dev.mysql.com/doc/refman/8.4/en/optimization-indexes.html>
- **Last updated:** 2026-05-19

## Quick reference

| Topic | Practice |
|---|---|
| Engine | Prefer InnoDB for transactional workloads |
| Keys | Add primary keys to every durable table |
| Indexes | Build indexes from observed query predicates and joins |
| Charset | Use `utf8mb4` for user text |
| Migrations | Keep DDL explicit and reviewed; online DDL capabilities vary |
| Transactions | Keep transactions short to reduce lock contention |

## Common patterns

### Composite index order

```sql
CREATE INDEX idx_orders_customer_created
ON orders (customer_id, created_at);
```

Put equality predicates before range predicates when they are commonly used together.

### Inspect query plans

```sql
EXPLAIN SELECT * FROM orders WHERE customer_id = ? ORDER BY created_at DESC;
```

Use plans and production query stats before adding indexes.

## Common pitfalls

- **Assuming PostgreSQL semantics** - `SERIAL`, JSON operators, partial indexes, and isolation behavior differ.
- **Indexing every column** - write amplification and storage bloat can dominate.
- **Using `utf8` instead of `utf8mb4`** - historical MySQL `utf8` is not full Unicode.
- **Long-running transactions** - locks and purge lag can harm the whole system.

## See also

- `data/postgresql-indexing-basics.md` - PostgreSQL indexing contrast
- `languages/sql.md` - SQL syntax baseline

## Pull on Demand

### Source

This is a compact anchor cheatsheet. Pull MySQL's reference manual before relying on version-specific optimizer, DDL, or replication behavior.

- **Upstream URL(s):**
  - `https://dev.mysql.com/doc/refman/8.4/en/`
- **Archive type:** documentation site reference
- **Expected size:** `~5 MB selected pages`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/data/mysql-best-practices`
- **License:** upstream-documentation
- **License URL:** `https://www.oracle.com/legal/terms.html`

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/data/mysql-best-practices"
mkdir -p "$TARGET"
cp cheatsheets/data/mysql-best-practices.md "$TARGET/index.md"
```

### Generation guidelines (after pull)

1. Check the deployed MySQL/MariaDB version before citing optimizer or DDL behavior.
2. Validate index advice with `EXPLAIN` or production query stats.
