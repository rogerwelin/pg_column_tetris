# pg_column_tetris

A PostgreSQL extension that enforces optimal column alignment to minimize row padding waste.

<img src="logo.jpg" alt="pg_column_tetris logo" width="230">


## Why Column Order Matters

PostgreSQL stores each row as a sequence of bytes on disk. Column types have different sizes — a `bigint` takes 8 bytes, an `integer` takes 4, a `boolean` takes just 1. So far so simple.

The problem is that PostgreSQL can't just pack them back to back. The CPU reads memory most efficiently when values are naturally aligned — an 8-byte value should start at a position divisible by 8, a 4-byte value at a position divisible by 4, and so on. To guarantee this, PostgreSQL inserts invisible **padding bytes** between columns whenever needed.

Here's an example. Say you create a table like this:

```sql
CREATE TABLE bad_order (
    active    boolean,   -- 1 byte
    user_id   bigint,    -- 8 bytes
    age       integer    -- 4 bytes
);
```

In memory, each row looks like this:

```
[active: 1 byte] [7 bytes padding] [user_id: 8 bytes] [age: 4 bytes] = 20 bytes per row
```

`user_id` needs to start at an 8-byte boundary, so PostgreSQL pads 7 bytes after `active` to get there. That's 7 wasted bytes **per row**.

Now reorder the columns largest-first:

```sql
CREATE TABLE good_order (
    user_id   bigint,    -- 8 bytes
    age       integer,   -- 4 bytes
    active    boolean    -- 1 byte
);
```

```
[user_id: 8 bytes] [age: 4 bytes] [active: 1 byte] = 13 bytes per row
```

Zero padding. Same data, 35% smaller rows. Multiply that across millions of rows and dozens of columns — it adds up fast. Optimal column order is free performance: zero runtime cost, just a smarter `CREATE TABLE`.

## Installation

Pure SQL/PL/pgSQL — no compilation needed.

### Self-hosted PostgreSQL

```bash
make install
```

```sql
CREATE EXTENSION pg_column_tetris;
```

### Managed services (RDS, Cloud SQL, Supabase, Neon, etc.)

Since the extension is pure SQL/PL/pgSQL (no C, no compilation), it runs anywhere PostgreSQL does — just load the SQL directly:

```bash
psql -d your_database -c "CREATE SCHEMA IF NOT EXISTS column_tetris"
sed '/^\\echo.*\\quit/d' pg_column_tetris--0.1.0.sql | psql -d your_database
```

Requires a role with event trigger privileges (e.g. `rds_superuser` on RDS, `cloudsqlsuperuser` on Cloud SQL).

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
