---
tags: [postgresql, database, indexing, btree, query-performance]
languages: [sql]
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://www.postgresql.org/docs/current/indexes.html
  - https://www.postgresql.org/docs/current/indexes-types.html
  - https://use-the-index-luke.com/
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# PostgreSQL — indexing basics

@trace spec:agent-cheatsheets

## Provenance

- PostgreSQL official docs (current version), "Indexes": <https://www.postgresql.org/docs/current/indexes.html>
  local: `cheatsheet-sources/www.postgresql.org/docs/current/indexes.html`
- PostgreSQL official docs, "Index Types": <https://www.postgresql.org/docs/current/indexes-types.html>
  local: `cheatsheet-sources/www.postgresql.org/docs/current/indexes-types.html`
- Markus Winand, "Use The Index, Luke!" — vendor-neutral but PG-aware: <https://use-the-index-luke.com/> (free online edition)
- **Last updated:** 2026-04-25

## Use when

You're choosing an index type for a Postgres table, debugging a slow query, or designing a schema. The default `CREATE INDEX` uses B-tree — that's right for most cases but wrong for some.

## Quick reference — index types

| Type | Use when | Example |
|---|---|---|
| **B-tree** (default) | Equality + range on scalar, ordered columns | `WHERE id = ?`, `WHERE created_at > ?`, `ORDER BY` |
| **Hash** | Equality only, very large tables | `WHERE token = ?` (rarely justified — B-tree usually fine) |
| **GIN** | Composite values: arrays, jsonb, full-text | `WHERE tags @> '{"foo"}'`, `WHERE document @@ to_tsquery(...)` |
| **GiST** | Geometry, range, custom ordering | `geometry && bbox`, `tsrange && '[2024,2026)'` |
| **BRIN** | Very large append-only tables, ordered by physical layout | time-series logs ordered by `created_at` |
| **SP-GiST** | Non-balanced trees: phone tries, IP routing | Niche |

## Common patterns

### Pattern 1 — composite index column order matters

```sql
CREATE INDEX idx_users_email_created
    ON users (email, created_at);
```

This index serves:
- `WHERE email = ?`  ✓ (leading column)
- `WHERE email = ? AND created_at > ?`  ✓ (both columns)
- `WHERE created_at > ?`  ✗ (skipping leading column — full scan)

**Rule:** put the column you ALWAYS filter on first. Multi-column indexes are NOT bidirectional.

### Pattern 2 — partial index for sparse predicate

```sql
CREATE INDEX idx_orders_pending
    ON orders (created_at)
    WHERE status = 'pending';
```

If 99% of orders are `'completed'` and you almost always query `'pending'`, the partial index is 100× smaller and 100× faster than indexing all rows.

### Pattern 3 — expression index for computed lookups

```sql
CREATE INDEX idx_users_lower_email ON users (LOWER(email));

-- now this query can use the index:
SELECT * FROM users WHERE LOWER(email) = LOWER('User@Example.com');
```

### Pattern 4 — covering index (INCLUDE clause, PG 11+)

```sql
CREATE INDEX idx_orders_customer_covering
    ON orders (customer_id) INCLUDE (total, currency);
```

`total` and `currency` aren't indexed for filtering but ARE in the leaf — index-only scan, no heap access.

### Pattern 5 — concurrent build (no table lock)

```sql
CREATE INDEX CONCURRENTLY idx_big_table_foo ON big_table (foo);
```

Slower (multiple table passes) but doesn't block writes. Use in production. CANNOT be inside a transaction.

## EXPLAIN: read your query plans

```sql
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT * FROM users WHERE email = 'foo@example.com';
```

What to look for:
- `Index Scan` / `Index Only Scan` ✓
- `Seq Scan` ✗ (unless table is small or you're touching most rows)
- `Buffers: shared hit=N read=M` — `read` should be tiny on a warm cache
- `actual time=...` vs `estimated rows=...` — large discrepancy = stale stats; `ANALYZE` the table

## Common pitfalls

- **Indexing every column "just in case"** — every index slows down INSERTs/UPDATEs/DELETEs and bloats storage. Index based on actual query patterns from `pg_stat_statements`.
- **Index leading column you never filter alone on** — wasted index. Reorder so the always-filtered column is first.
- **NULL semantics** — by default `NULL`s sort last, are not equal to anything (including themselves). `WHERE col = NULL` finds nothing; use `WHERE col IS NULL`.
- **Functional predicate with non-functional index** — `WHERE LOWER(email) = ?` does NOT use a plain `(email)` index. Either index the expression or rewrite the query.
- **`LIKE 'foo%'` works, `LIKE '%foo'` doesn't** — leading wildcard prevents B-tree usage. Use `pg_trgm` GIN index for arbitrary substring search.
- **Bloated indexes from heavy updates** — `REINDEX CONCURRENTLY` or VACUUM tuning. Monitor `pg_stat_user_indexes.idx_scan` to find unused indexes.
- **Forgetting `ANALYZE` after bulk load** — query planner uses stale stats and picks bad plans. Run `ANALYZE table_name` after `COPY` / large `INSERT`.
- **`REINDEX` taking exclusive lock** — use `REINDEX CONCURRENTLY` (PG 12+) instead.

## See also

- `languages/sql.md` (DRAFT) — SQL syntax baseline
- `data/mysql-best-practices.md` — sister cheatsheet for MySQL (different index semantics)
- `architecture/event-driven-basics.md` — CQRS read-side often lives in PG indexes
