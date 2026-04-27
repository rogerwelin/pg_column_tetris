# pg_column_tetris

A PostgreSQL extension that enforces optimal column alignment to minimize row padding waste.

<img src="logo.jpg" alt="pg_column_tetris logo" width="230">


## Why Column Order Matters

PostgreSQL stores each row as a sequence of bytes on disk. Column types have different sizes: a `bigint` takes 8 bytes, an `integer` takes 4, a `boolean` takes just 1. So far so simple.

The problem is that PostgreSQL can't just pack them back to back. The CPU reads memory most efficiently when values are naturally aligned; an 8-byte value should start at a position divisible by 8, a 4-byte value at a position divisible by 4, and so on. To guarantee this, PostgreSQL inserts invisible **padding bytes** between columns whenever needed.

Here's an example. Say you create a table like this:

```sql
CREATE TABLE bad_order (
    active    boolean,   -- 1 byte
    user_id   bigint,    -- 8 bytes
    age       integer    -- 4 bytes
);
```

In memory, each row looks like:

```
[active: 1B] [7B padding] [user_id: 8B] [age: 4B]  →  20 bytes of column data
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
[user_id: 8B] [age: 4B] [active: 1B]  →  13 bytes of column data
```

Zero padding. Same data, 35% smaller rows. Multiply that across millions of rows and dozens of columns and it will adds up fast. Optimal column order is free performance: zero runtime cost, just a smarter `CREATE TABLE`.

### Alignment Groups

The extension sorts columns into these groups, largest alignment first:

1. **8-byte aligned** (`d`): `bigint`, `timestamptz`, `float8`, `interval`
2. **4-byte aligned** (`i`): `integer`, `float4`, `date`, `oid`
3. **2-byte aligned** (`s`): `smallint`
4. **1-byte aligned** (`c`): `boolean`, `char(1)`
5. **Variable-length** (varlena): `text`, `varchar`, `numeric`, `jsonb`, `bytea` - always last

Within each group, `NOT NULL` columns come first (minor CPU optimization for tuple deforming).

## Requirements

- PostgreSQL 14+
- Superuser or event trigger privileges (`rds_superuser` on RDS, `cloudsqlsuperuser` on Cloud SQL)

## Installation

Pure SQL/PL/pgSQL - no C, no compilation.

### Self-hosted PostgreSQL

```bash
make install
```

```sql
CREATE EXTENSION pg_column_tetris;
```

### Managed services (RDS, Cloud SQL, Supabase, Neon, etc.)

Since there's no C code, the extension runs anywhere PostgreSQL does:

```bash
psql -d your_database -f pg_column_tetris--0.1.0.sql
```

## Usage

The extension has three modes (`warn`, `strict`, `off`) that cover different workflows.

### Warn mode (default) - catch bad ordering during development

The extension installs in `warn` mode. Any `CREATE TABLE` with suboptimal column order emits a NOTICE but still succeeds:

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

```
NOTICE: pg_column_tetris: suboptimal column alignment — 19 bytes of fixed-width padding wasted per row
```

Good for development — you see the problem without breaking anything.

### Strict mode — enforce alignment in CI/migrations

In strict mode, `CREATE TABLE` with suboptimal column order is **blocked** and rolled back. The error message includes the optimal column order so you can fix it immediately:

```sql
SELECT column_tetris.set_mode('strict');

CREATE TABLE orders ( ... );
-- ERROR:  suboptimal column alignment — 19 bytes of fixed-width padding wasted per row
-- HINT:  Suggested order:
--     CREATE TABLE orders (
--         user_id bigint,          -- 8-byte aligned
--         order_dt timestamptz,    -- 8-byte aligned
--         ship_dt timestamptz,     -- 8-byte aligned
--         item_ct smallint,        -- 2-byte aligned
--         status smallint,         -- 2-byte aligned
--         is_shipped boolean,      -- 1-byte aligned
--         order_total numeric      -- varlena (last)
--     );
```

Use this in staging/production databases or CI pipelines to guarantee every new table has optimal alignment.

### As an analysis tool - audit existing tables

Use `check()` to inspect any table's current layout and see where padding is wasted:

```sql
SELECT * FROM column_tetris.check('orders');
```

Use `suggest_rewrite()` to generate a complete migration script that reorders the columns optimally:

```sql
SELECT column_tetris.suggest_rewrite('orders');
```

```sql
-- Generated output:
BEGIN;
ALTER TABLE public.orders RENAME TO orders_old;
CREATE TABLE public.orders ( ...optimal order... );
INSERT INTO public.orders SELECT ... FROM public.orders_old;
DROP TABLE public.orders_old;
COMMIT;
```

You can use `off` mode if you want to disable the event trigger entirely and just use the analysis functions.

### Other configuration

```sql
-- Check current mode
SELECT column_tetris.mode();

-- Exclude a table from validation (e.g., matching an external schema)
SELECT column_tetris.exclude('legacy_imports');
```

### What gets checked

- **CREATE TABLE** statements are validated by the event trigger
- **ALTER TABLE** is deliberately skipped - you can't reorder existing columns, so warning would be noise
- **Temp tables** and **system schemas** (`pg_catalog`, `information_schema`) are skipped
- Tables in the `exclusions` list are skipped

## License

MIT
