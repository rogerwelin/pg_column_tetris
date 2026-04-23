Name: pg_column_tetris — a pure SQL/PL/pgSQL extension that enforces optimal column alignment via event triggers.

Why it matters: Wasted alignment padding doesn't just cost disk space — more importantly, it costs memory. Padding bytes are loaded as-is into shared_buffers and OS page cache. More bytes per row means fewer rows per 8KB page, which means more pages resident in memory for the same dataset. This increases cache pressure, causes more evictions, and leads to more disk I/O. For high-row-count tables the memory impact far outweighs the storage cost.

Core components:

1. Alignment calculator function
pg_column_tetris.compute_layout(oid) → TABLE(attname, typname, typalign, typlen, current_position, optimal_position, padding_bytes)
This is the brain. For a given relation OID it:

Fetches all non-dropped columns from pg_attribute joined with pg_type
Walks the column list in attnum order, simulating the heap tuple layout byte by byte (23-byte header → null bitmap if any nullable columns → MAXALIGN padding → then each column with its alignment requirement)
Computes actual padding per column
Computes the optimal order for fixed-width columns: 8-byte aligned first (bigint, timestamptz, float8), then 4-byte (int, float4, date, oid), then 2-byte (smallint), then 1-byte (boolean, char(1)), then all varlena last (text, varchar, numeric, jsonb, bytea) — varlena are 4-byte aligned (typalign='i') but go last because their variable in-row size creates unpredictable padding for any column that follows them. Within each alignment group, NOT NULL columns are preferred earlier (minor CPU optimization — cheaper to deform, though not a storage benefit).
Padding is only computed between fixed-width columns (deterministic). Varlena columns are reported as "variable — placed last" rather than claiming exact byte savings.
Returns both layouts with total fixed-width waste

2. Validation function
pg_column_tetris.validate(oid) → void
Calls compute_layout, compares current vs optimal total row size. If delta > 0, raises EXCEPTION with the suggested CREATE TABLE column order in the HINT. If equal, no-op.

3. Event trigger function
pg_column_tetris.ddl_check() → event_trigger
Fires on ddl_command_end. Loops over pg_event_trigger_ddl_commands(), filters for CREATE TABLE only. ALTER TABLE is deliberately skipped — users cannot affect column order on existing tables (new columns always get the highest attnum), so blocking or warning on ALTER TABLE would be noise with no actionable fix. For each affected relation OID, calls validate(). If validation raises, the whole DDL statement rolls back.
Also skips: temp tables, tables in pg_catalog/information_schema.

4. Mode control
A pg_column_tetris.config table with a single mode column: strict (block), warn (NOTICE only), off (skip). The event trigger reads this before doing anything. Defaults to warn on install so it doesn't break anything out of the box.

5. Escape hatch
A companion table pg_column_tetris.exclusions(relname text) — if you have a legitimate reason to skip a table (e.g., you're matching an external schema), you add it here and the trigger skips validation for that table.
Packaging:
Standard extension structure — pg_column_tetris.control, pg_column_tetris--0.1.0.sql. Pure SQL install, no compilation, works on any managed Postgres (RDS, Cloud SQL, Supabase, Neon) since event triggers are supported everywhere that allows them.
File structure:
pg_column_tetris/
├── pg_column_tetris.control
├── pg_column_tetris--0.1.0.sql   (schema, functions, event trigger, config)
├── test/
│   └── sql/
│       ├── 01_strict_blocks.sql
│       ├── 02_warn_allows.sql
│       ├── 03_optimal_passes.sql
│       ├── 04_exclusions.sql
│       └── 05_edge_cases.sql    (all-nullable, single column, varlena-only)
├── README.md
└── LICENSE
Edge cases to handle:

Tables with only varlena columns (no fixed-width padding possible, always pass)
Single-column tables (always optimal)
All-nullable tables (null bitmap changes MAXALIGN boundary after header)
Partitioned tables (check parent definition only)
Temp tables (skip — ephemeral, not worth blocking)
Tables in pg_catalog/information_schema (skip — system schemas)

Rollout order:

compute_layout function + manual SELECT usage — useful standalone
validate + event trigger in warn mode
Test suite
README + examples


CREATE EXTENSION pg_column_tetris;
-- installs in warn mode by default


Daily workflow — the event trigger does the work invisibly:
Developer writes a migration:


CREATE TABLE orders (
    is_shipped boolean,
    order_total numeric,
    user_id bigint,
    item_ct smallint,
    order_dt timestamptz,
    status smallint,
    ship_dt timestamptz
);


In strict mode, it rolls back and they see:


ERROR:  suboptimal column alignment — 19 bytes of fixed-width padding wasted per row
DETAIL: Current fixed-width layout wastes 19 bytes per row in alignment padding; optimal order wastes 0.
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

In warn mode, same message but as NOTICE — DDL goes through.

Auditing existing tables:

-- single table report
SELECT * FROM pg_column_tetris.check('orders');

-- returns:
--  attname    | alignment | current_pos | optimal_pos | padding
-- ------------+-----------+-------------+-------------+--------
--  is_shipped | c (1)     | 1           | 7           | 7
--  order_total| i (varlena)| 2          | 5           | (variable)
--  user_id    | d (8)     | 3           | 1           | 0
--  ...
--  fixed_waste_bytes_per_row: 19
-- Note: padding between fixed-width columns only; varlena waste is variable


-- generate the fix DDL for a specific table (rewrite script)
SELECT pg_column_tetris.suggest_rewrite('orders');

-- returns the full migration:
--  ALTER TABLE orders RENAME TO orders_old;
--  CREATE TABLE orders ( ... optimal order ... );
--  INSERT INTO orders SELECT user_id, order_dt, ... FROM orders_old;
--  DROP TABLE orders_old;


Configuration:

SELECT pg_column_tetris.set_mode('strict');   -- block
SELECT pg_column_tetris.set_mode('warn');     -- notice only
SELECT pg_column_tetris.set_mode('off');      -- disable

-- exclude a table
SELECT pg_column_tetris.exclude('legacy_imports');

-- check current mode
SELECT pg_column_tetris.mode();

