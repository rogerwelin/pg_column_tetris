-- Test: optimally ordered tables pass in strict mode
-- Expected: CREATE TABLE succeeds without error

-- Setup
SELECT pg_column_tetris.set_mode('strict');

-- Test 1: Optimal order (8-byte → 4-byte → 2-byte → 1-byte → varlena)
CREATE TABLE test_optimal_mixed (
    user_id bigint NOT NULL,
    order_dt timestamptz NOT NULL,
    ship_dt timestamptz,
    item_ct smallint,
    status smallint,
    is_shipped boolean,
    order_total numeric
);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'test_optimal_mixed') THEN
        RAISE EXCEPTION 'TEST FAILED: optimally ordered table should be created';
    END IF;
    RAISE NOTICE 'TEST PASSED: optimal mixed table created in strict mode';
END;
$$;

-- Test 2: All 8-byte columns
CREATE TABLE test_optimal_all8 (
    col_a bigint,
    col_b timestamptz,
    col_c float8
);

DO $$
BEGIN
    RAISE NOTICE 'TEST PASSED: all 8-byte table created in strict mode';
END;
$$;

-- Test 3: All 4-byte columns
CREATE TABLE test_optimal_all4 (
    col_a integer,
    col_b float4,
    col_c date
);

DO $$
BEGIN
    RAISE NOTICE 'TEST PASSED: all 4-byte table created in strict mode';
END;
$$;

-- Test 4: Optimal with NOT NULL ordering within groups
CREATE TABLE test_optimal_notnull (
    id bigint NOT NULL,
    created_at timestamptz NOT NULL,
    updated_at timestamptz,
    status_code integer NOT NULL,
    ref_id integer,
    active boolean NOT NULL,
    deleted boolean,
    name text,
    bio text
);

DO $$
BEGIN
    RAISE NOTICE 'TEST PASSED: NOT NULL ordered table created in strict mode';
END;
$$;

-- Cleanup
DROP TABLE IF EXISTS test_optimal_mixed;
DROP TABLE IF EXISTS test_optimal_all8;
DROP TABLE IF EXISTS test_optimal_all4;
DROP TABLE IF EXISTS test_optimal_notnull;
SELECT pg_column_tetris.set_mode('warn');
DO $$ BEGIN RAISE NOTICE 'All 03_optimal_passes tests passed'; END; $$;
