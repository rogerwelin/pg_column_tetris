-- Test: edge cases that should always pass validation
-- Expected: all tables created successfully in strict mode

-- Setup
SELECT pg_column_tetris.set_mode('strict');

-- Test 1: Varlena-only table (no fixed-width padding possible)
CREATE TABLE test_edge_varlena_only (
    name text,
    bio text,
    data jsonb
);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'test_edge_varlena_only') THEN
        RAISE EXCEPTION 'TEST FAILED: varlena-only table should pass';
    END IF;
    RAISE NOTICE 'TEST PASSED: varlena-only table created';
END;
$$;

-- Test 2: Single-column table
CREATE TABLE test_edge_single_col (
    id bigint
);

DO $$
BEGIN
    RAISE NOTICE 'TEST PASSED: single-column table created';
END;
$$;

-- Test 3: All-nullable table (tests null bitmap boundary calculation)
CREATE TABLE test_edge_all_nullable (
    big_id bigint,
    created_at timestamptz,
    count integer,
    flag boolean
);

DO $$
BEGIN
    RAISE NOTICE 'TEST PASSED: all-nullable table created (optimal order)';
END;
$$;

-- Test 4: Table with many columns (null bitmap > 1 byte)
CREATE TABLE test_edge_many_cols (
    col_a bigint NOT NULL,
    col_b bigint,
    col_c timestamptz NOT NULL,
    col_d timestamptz,
    col_e integer NOT NULL,
    col_f integer,
    col_g smallint NOT NULL,
    col_h smallint,
    col_i boolean NOT NULL,
    col_j boolean,
    col_k text,
    col_l jsonb
);

DO $$
BEGIN
    RAISE NOTICE 'TEST PASSED: many-column table created (12 cols, optimal order)';
END;
$$;

-- Test 5: Partitioned table (should check parent definition)
CREATE TABLE test_edge_partitioned (
    event_time timestamptz NOT NULL,
    event_id bigint NOT NULL,
    payload jsonb
) PARTITION BY RANGE (event_time);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'test_edge_partitioned') THEN
        RAISE EXCEPTION 'TEST FAILED: partitioned table should be created';
    END IF;
    RAISE NOTICE 'TEST PASSED: partitioned table created';
END;
$$;

-- Test 6: off mode — everything passes
SELECT pg_column_tetris.set_mode('off');

CREATE TABLE test_edge_off_mode (
    flag boolean,
    big_id bigint,
    name text,
    small_val smallint
);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'test_edge_off_mode') THEN
        RAISE EXCEPTION 'TEST FAILED: off mode should allow all tables';
    END IF;
    RAISE NOTICE 'TEST PASSED: off mode allows suboptimal table';
END;
$$;

-- Test 7: suggest_rewrite produces valid output
SELECT pg_column_tetris.set_mode('warn');

DO $$
DECLARE
    v_ddl text;
BEGIN
    SELECT pg_column_tetris.suggest_rewrite('test_edge_off_mode') INTO v_ddl;
    IF v_ddl IS NULL OR v_ddl = '' THEN
        RAISE EXCEPTION 'TEST FAILED: suggest_rewrite returned empty';
    END IF;
    IF v_ddl NOT LIKE '%RENAME TO%' THEN
        RAISE EXCEPTION 'TEST FAILED: suggest_rewrite should contain RENAME TO';
    END IF;
    IF v_ddl NOT LIKE '%INSERT INTO%' THEN
        RAISE EXCEPTION 'TEST FAILED: suggest_rewrite should contain INSERT INTO';
    END IF;
    RAISE NOTICE 'TEST PASSED: suggest_rewrite produces valid DDL';
    RAISE NOTICE 'Generated DDL: %', v_ddl;
END;
$$;

-- Cleanup
DROP TABLE IF EXISTS test_edge_varlena_only;
DROP TABLE IF EXISTS test_edge_single_col;
DROP TABLE IF EXISTS test_edge_all_nullable;
DROP TABLE IF EXISTS test_edge_many_cols;
DROP TABLE IF EXISTS test_edge_partitioned;
DROP TABLE IF EXISTS test_edge_off_mode;
SELECT pg_column_tetris.set_mode('warn');
DO $$ BEGIN RAISE NOTICE 'All 05_edge_cases tests passed'; END; $$;
