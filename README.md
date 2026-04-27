# pg_column_tetris

A PostgreSQL extension that enforces optimal column alignment to minimize row padding waste.

<img src="logo.jpg" alt="pg_column_tetris logo" width="230">


## Why Column Order Matters

Every heap tuple in PostgreSQL starts with a 23-byte header, followed by a null bitmap, then the actual column data. Each column must start at an address that is a multiple of its type's alignment requirement — `bigint` needs an 8-byte boundary, `integer` needs 4, `smallint` needs 2, and `boolean` just 1. When a column's natural offset doesn't land on its required boundary, PostgreSQL inserts invisible **padding bytes** to close the gap.

Consider this table:

```
 boolean (1 byte)  |  7 bytes padding  |  bigint (8 bytes)  |  integer (4 bytes)  |  4 bytes padding
```

That's 11 bytes of wasted padding in a single row. Reorder the columns largest-first and the padding drops to zero:

```
 bigint (8 bytes)  |  integer (4 bytes)  |  boolean (1 byte)  |  no padding
```

This padding isn't just on disk — it's loaded as-is into `shared_buffers` and the OS page cache. More bytes per row means fewer rows per 8 KB page, more cache pressure, and more disk I/O. For a table with millions of rows, fixing column order can reclaim gigabytes of memory.

## Installation

Pure SQL/PL/pgSQL — no compilation needed.

### Self-hosted PostgreSQL

```bash
make install
```

```sql
CREATE EXTENSION pg_column_tetris;
```

### Managed services

Most managed PostgreSQL providers (RDS, Cloud SQL, etc.) don't allow installing custom extensions or creating event triggers. This extension requires a self-hosted instance or a provider that supports custom extensions (e.g. [Supabase](https://supabase.com), [Neon](https://neon.tech) custom builds).

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
SELECT column_tetris.set_mode('strict');
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
SELECT * FROM column_tetris.check('orders');

-- Generate migration DDL to fix a table
SELECT column_tetris.suggest_rewrite('orders');
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
SELECT column_tetris.set_mode('strict');

-- Check current mode
SELECT column_tetris.mode();

-- Exclude a table from validation (e.g., matching an external schema)
SELECT column_tetris.exclude('legacy_imports');
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
