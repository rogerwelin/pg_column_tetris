# pg_column_tetris

A PostgreSQL extension that enforces optimal column alignment to minimize row padding waste.

## Why It Matters

PostgreSQL aligns columns to their type's natural boundary (1, 2, 4, or 8 bytes). When columns are ordered poorly, padding bytes fill the gaps. These wasted bytes don't just cost disk space — they cost **memory**. Padding is loaded as-is into `shared_buffers` and OS page cache, meaning more bytes per row → fewer rows per 8 KB page → more cache pressure → more disk I/O.

For a table with millions of rows, reordering columns can reclaim gigabytes of memory.

## Installation

```bash
# From source
make install

# Then in PostgreSQL
CREATE EXTENSION pg_column_tetris;
```

No compilation needed — pure SQL/PL/pgSQL. Works on any PostgreSQL instance that supports event triggers (RDS, Cloud SQL, Supabase, Neon, etc.).

## Quick Start

The extension installs in **warn** mode by default. Create a table with suboptimal column order:

```sql
CREATE TABLE orders (
    is_shipped boolean,
    order_total numeric,
    user_id bigint,
    item_ct smallint,
    order_dt timestamptz,
    status smallint,
    ship_dt timestamptz
);
```

You'll see a NOTICE suggesting the optimal order:

```
NOTICE: pg_column_tetris: suboptimal column alignment — 19 bytes of fixed-width padding wasted per row
```

Switch to **strict** mode to block suboptimal tables entirely:

```sql
SELECT pg_column_tetris.set_mode('strict');
```

Now the same CREATE TABLE will fail with an error and a hint showing the optimal column order:

```
ERROR:  suboptimal column alignment — 19 bytes of fixed-width padding wasted per row
HINT:  Suggested order:
    CREATE TABLE orders (
        user_id bigint,          -- 8-byte aligned
        order_dt timestamptz,    -- 8-byte aligned
        ship_dt timestamptz,     -- 8-byte aligned
        item_ct smallint,        -- 2-byte aligned
        status smallint,         -- 2-byte aligned
        is_shipped boolean,      -- 1-byte aligned
        order_total numeric      -- varlena (last)
    );
```

## Optimal Column Order

The extension enforces this ordering rule for fixed-width columns:

1. **8-byte aligned** (`d`): `bigint`, `timestamptz`, `float8`, `interval`
2. **4-byte aligned** (`i`): `integer`, `float4`, `date`, `oid`
3. **2-byte aligned** (`s`): `smallint`
4. **1-byte aligned** (`c`): `boolean`, `char(1)`
5. **Variable-length** (varlena): `text`, `varchar`, `numeric`, `jsonb`, `bytea` — always last

Within each group, `NOT NULL` columns are preferred first (minor CPU optimization for tuple deforming).

## Auditing Existing Tables

```sql
-- Detailed layout report for a single table
SELECT * FROM pg_column_tetris.check('orders');

-- Generate migration DDL to fix a table
SELECT pg_column_tetris.suggest_rewrite('orders');
```

The `suggest_rewrite` function generates a complete migration script:

```sql
BEGIN;
ALTER TABLE public.orders RENAME TO orders_old;
CREATE TABLE public.orders ( ...optimal order... );
INSERT INTO public.orders SELECT ... FROM public.orders_old;
DROP TABLE public.orders_old;
COMMIT;
```

## Configuration

```sql
-- Set mode: 'strict' (block), 'warn' (notice only), 'off' (disable)
SELECT pg_column_tetris.set_mode('strict');

-- Check current mode
SELECT pg_column_tetris.mode();

-- Exclude a table from validation (e.g., matching an external schema)
SELECT pg_column_tetris.exclude('legacy_imports');
```

## What Gets Checked

- **CREATE TABLE** statements are validated by the event trigger
- **ALTER TABLE** is deliberately skipped — you can't reorder existing columns, so warning would be noise
- **Temp tables** and **system schemas** (`pg_catalog`, `information_schema`) are skipped
- Tables in the `exclusions` list are skipped

## Requirements

- PostgreSQL 9.5+ (requires `pg_event_trigger_ddl_commands()`)
- Superuser privileges to create the event trigger

## License

MIT
