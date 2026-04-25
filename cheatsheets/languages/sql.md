# SQL

@trace spec:agent-cheatsheets

**Version baseline**: SQL standard, with Postgres + SQLite divergences. Forge ships `sqlite3` and `psql` clients (no servers).
**Use when**: writing/debugging queries against SQLite or Postgres.

## Quick reference

| Task | Syntax |
|------|--------|
| SQLite REPL | `sqlite3 db.sqlite` (`.tables`, `.schema`, `.mode column`, `.headers on`, `.quit`) |
| Postgres REPL | `psql -h host -U user dbname` (`\dt`, `\d table`, `\l`, `\q`) |
| Run file (SQLite) | `sqlite3 db.sqlite < script.sql` |
| Run file (Postgres) | `psql -f script.sql` |
| SELECT | `SELECT col1, col2 FROM t WHERE pred ORDER BY col LIMIT n;` |
| Aggregate | `SELECT k, COUNT(*), SUM(v) FROM t GROUP BY k HAVING COUNT(*) > 1;` |
| INNER JOIN | `SELECT * FROM a JOIN b ON a.id = b.a_id;` |
| LEFT JOIN | `SELECT * FROM a LEFT JOIN b ON a.id = b.a_id;` (b cols NULL on miss) |
| CTE | `WITH x AS (SELECT ...) SELECT * FROM x;` |
| Recursive CTE | `WITH RECURSIVE r AS (base UNION ALL recur) SELECT * FROM r;` |
| Window | `SELECT col, ROW_NUMBER() OVER (PARTITION BY g ORDER BY t) FROM t;` |
| UPSERT | `INSERT ... ON CONFLICT (key) DO UPDATE SET col = EXCLUDED.col;` |
| Transaction | `BEGIN; ...; COMMIT;` (or `ROLLBACK;`) |
| EXPLAIN | `EXPLAIN QUERY PLAN ...` (SQLite) / `EXPLAIN ANALYZE ...` (Postgres) |
| Index | `CREATE INDEX idx_t_col ON t(col);` |

## Common patterns

### JOIN variants
```sql
-- INNER: rows in both
SELECT u.name, o.total FROM users u JOIN orders o ON o.user_id = u.id;

-- LEFT: all left rows, NULL on miss
SELECT u.name, o.total FROM users u LEFT JOIN orders o ON o.user_id = u.id;

-- Anti-join (rows in left without match)
SELECT u.* FROM users u LEFT JOIN orders o ON o.user_id = u.id WHERE o.id IS NULL;
```

### Window functions — rank, lag, running totals
```sql
SELECT
    name,
    score,
    ROW_NUMBER() OVER (ORDER BY score DESC)         AS rn,
    RANK()       OVER (ORDER BY score DESC)         AS rk,        -- ties share
    LAG(score)   OVER (ORDER BY ts)                 AS prev_score,
    SUM(score)   OVER (ORDER BY ts ROWS UNBOUNDED PRECEDING) AS running_total
FROM games;
```
`PARTITION BY` resets the window per group. `LAG`/`LEAD` peek across rows without self-join.

### Recursive CTE — walk a hierarchy
```sql
WITH RECURSIVE descendants AS (
    SELECT id, parent_id, name, 0 AS depth FROM nodes WHERE id = :root
    UNION ALL
    SELECT n.id, n.parent_id, n.name, d.depth + 1
    FROM nodes n JOIN descendants d ON n.parent_id = d.id
)
SELECT * FROM descendants ORDER BY depth, name;
```
Anchor query `UNION ALL` recursive query. Terminate with a finite join.

### UPSERT (insert-or-update)
```sql
-- Both Postgres and SQLite (3.24+)
INSERT INTO counters (key, n) VALUES ('hits', 1)
ON CONFLICT (key) DO UPDATE SET n = counters.n + EXCLUDED.n;
```
`EXCLUDED` is the row you tried to insert. Requires a UNIQUE constraint on the conflict target.

### Transaction with isolation
```sql
-- Postgres
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT balance FROM accounts WHERE id = 1 FOR UPDATE;
UPDATE accounts SET balance = balance - 100 WHERE id = 1;
COMMIT;
```
SQLite uses single-writer locking; only `DEFERRED`/`IMMEDIATE`/`EXCLUSIVE` (no isolation level keyword).

## Common pitfalls

- **NULL semantics** — `NULL = NULL` is unknown (not true). Use `IS NULL` / `IS NOT NULL`. `WHERE col != 'x'` excludes NULL rows; add `OR col IS NULL` if you want them.
- **GROUP BY non-aggregate columns** — Postgres rejects `SELECT a, b FROM t GROUP BY a` unless `b` is functionally dependent on `a`. SQLite silently picks an arbitrary `b`. Always list every non-aggregate in `GROUP BY`.
- **Implicit type coercion in SQLite** — column types are advisory ("type affinity"). `INSERT INTO t(int_col) VALUES ('abc')` succeeds. Use `CHECK (typeof(col) = 'integer')` or rely on Postgres if you need strict typing.
- **`COUNT(col)` skips NULL** — `COUNT(*)` counts rows; `COUNT(col)` counts non-NULL values. `COUNT(DISTINCT col)` also skips NULL.
- **JOIN without ON** — `SELECT * FROM a, b` (or `JOIN` with no `ON`) is a Cartesian product: `len(a) * len(b)` rows. Always specify a join condition unless you genuinely want the cross product (`CROSS JOIN`).
- **`LIKE` is case-sensitive (Postgres) / case-insensitive (SQLite)** — use `ILIKE` in Postgres, or `LOWER(col) LIKE LOWER(:pattern)` for portability.
- **Foreign keys off by default in SQLite** — must run `PRAGMA foreign_keys = ON;` per connection. Postgres enforces them always.
- **Aggregates with empty input** — `SUM` of zero rows returns `NULL`, not `0`. Use `COALESCE(SUM(x), 0)`. `COUNT` of zero rows correctly returns `0`.
- **String concatenation operator** — standard SQL is `||` (works in both). `+` is SQL Server only and silently does numeric addition in Postgres/SQLite.
- **Ordering without `ORDER BY` is undefined** — even on a clustered index. Never rely on insertion order.

## Postgres vs SQLite divergences

| Feature | Postgres | SQLite |
|---------|----------|--------|
| Type system | Strict (`INTEGER`, `TEXT`, `JSONB`, `UUID`, `TIMESTAMPTZ`, arrays) | Type affinity (advisory only); 5 storage classes |
| Auto-increment | `id SERIAL` or `id BIGSERIAL` (or `GENERATED ALWAYS AS IDENTITY`) | `id INTEGER PRIMARY KEY` (alias for `ROWID`) or add `AUTOINCREMENT` to forbid reuse |
| `RETURNING` clause | Yes | Yes (3.35+) |
| Foreign keys | Enforced always | Off by default; `PRAGMA foreign_keys = ON` |
| Boolean type | Native `BOOLEAN` | Stored as `INTEGER` (0/1); no `TRUE`/`FALSE` keywords pre-3.23 |
| JSON | `JSONB` (indexed, operators `->`, `->>`, `@>`) | `JSON1` extension (text-based; `json_extract(col, '$.key')`) |
| Concurrent writers | MVCC, many writers | Single writer at a time (WAL mode helps) |
| `ALTER TABLE` | Add/drop/rename column freely | Limited; `DROP COLUMN` only since 3.35; complex changes need table rebuild |
| Date/time | `TIMESTAMPTZ`, `INTERVAL`, full timezone math | Stored as TEXT/REAL/INTEGER; functions: `date()`, `datetime()`, `strftime()` |
| Case-insensitive LIKE | `ILIKE` | Default `LIKE` is ASCII-case-insensitive |

## See also

- `utils/jq.md` — JSON query language with similar mental model
- `utils/sqlite3.md` — SQLite CLI ergonomics (dot commands, modes, `.dump`)
- `utils/psql.md` — Postgres CLI ergonomics (backslash commands, `\copy`)
