-- Test: excluded tables bypass validation
-- Expected: excluded table is created even with suboptimal order in strict mode

-- Setup
SELECT column_tetris.set_mode('strict');

-- Test 1: Add exclusion then create suboptimal table
SELECT column_tetris.exclude('test_excluded');

CREATE TABLE test_excluded (
    is_active boolean,
    user_id bigint,
    name text,
    item_ct smallint
);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'test_excluded') THEN
        RAISE EXCEPTION 'TEST FAILED: excluded table should be created';
    END IF;
    RAISE NOTICE 'TEST PASSED: excluded table created in strict mode';
END;
$$;

-- Test 2: Remove exclusion, verify table would now be blocked
DROP TABLE test_excluded;
DELETE FROM column_tetris.exclusions WHERE relname = 'test_excluded';

DO $$
DECLARE
    v_blocked bool := false;
BEGIN
    BEGIN
        EXECUTE '
            CREATE TABLE test_excluded (
                is_active boolean,
                user_id bigint,
                name text,
                item_ct smallint
            )';
    EXCEPTION WHEN raise_exception THEN
        v_blocked := true;
        RAISE NOTICE 'TEST PASSED: table blocked after exclusion removed';
    END;

    IF NOT v_blocked THEN
        DROP TABLE IF EXISTS test_excluded;
        RAISE EXCEPTION 'TEST FAILED: table should be blocked after exclusion removed';
    END IF;
END;
$$;

-- Test 3: Schema-qualified exclusion
SELECT column_tetris.exclude('public.test_schema_excluded');

CREATE TABLE test_schema_excluded (
    flag boolean,
    big_id bigint
);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'test_schema_excluded') THEN
        RAISE EXCEPTION 'TEST FAILED: schema-excluded table should be created';
    END IF;
    RAISE NOTICE 'TEST PASSED: schema-qualified exclusion works';
END;
$$;

-- Cleanup
DROP TABLE IF EXISTS test_excluded;
DROP TABLE IF EXISTS test_schema_excluded;
DELETE FROM column_tetris.exclusions;
SELECT column_tetris.set_mode('warn');
DO $$ BEGIN RAISE NOTICE 'All 04_exclusions tests passed'; END; $$;
