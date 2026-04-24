-- Test: strict mode blocks CREATE TABLE with suboptimal column order
-- Expected: CREATE TABLE is rolled back, table does not exist

-- Setup
SELECT column_tetris.set_mode('strict');

-- Test 1: Suboptimal order should be blocked
DO $$
DECLARE
    v_blocked bool := false;
BEGIN
    BEGIN
        EXECUTE '
            CREATE TABLE test_strict_block (
                is_shipped boolean,
                order_total numeric,
                user_id bigint,
                item_ct smallint,
                order_dt timestamptz,
                status smallint,
                ship_dt timestamptz
            )';
    EXCEPTION WHEN raise_exception THEN
        v_blocked := true;
        -- Verify error message
        IF SQLERRM NOT LIKE '%suboptimal column alignment%' THEN
            RAISE EXCEPTION 'unexpected error message: %', SQLERRM;
        END IF;
        RAISE NOTICE 'TEST PASSED: strict mode blocked suboptimal table (error: %)', SQLERRM;
    END;

    IF NOT v_blocked THEN
        RAISE EXCEPTION 'TEST FAILED: strict mode did not block suboptimal table';
    END IF;
END;
$$;

-- Verify table does not exist
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'test_strict_block') THEN
        RAISE EXCEPTION 'TEST FAILED: table should not exist after strict mode block';
    END IF;
    RAISE NOTICE 'TEST PASSED: table does not exist after block';
END;
$$;

-- Test 2: Verify error contains byte count
DO $$
DECLARE
    v_msg text;
BEGIN
    BEGIN
        EXECUTE '
            CREATE TABLE test_strict_bytes (
                flag boolean,
                big_id bigint
            )';
    EXCEPTION WHEN raise_exception THEN
        v_msg := SQLERRM;
        IF v_msg NOT LIKE '%bytes of fixed-width padding%' THEN
            RAISE EXCEPTION 'TEST FAILED: error should mention bytes, got: %', v_msg;
        END IF;
        RAISE NOTICE 'TEST PASSED: error message includes byte count';
        RETURN;
    END;
    RAISE EXCEPTION 'TEST FAILED: should have been blocked';
END;
$$;

-- Cleanup
SELECT column_tetris.set_mode('warn');
DO $$ BEGIN RAISE NOTICE 'All 01_strict_blocks tests passed'; END; $$;
