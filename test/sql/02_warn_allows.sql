-- Test: warn mode allows CREATE TABLE but emits NOTICE
-- Expected: table IS created despite suboptimal order

-- Setup
SELECT pg_column_tetris.set_mode('warn');

-- Test 1: Suboptimal order should produce NOTICE but succeed
CREATE TABLE test_warn_allow (
    is_shipped boolean,
    order_total numeric,
    user_id bigint,
    item_ct smallint,
    order_dt timestamptz,
    status smallint,
    ship_dt timestamptz
);

-- Verify table exists
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'test_warn_allow') THEN
        RAISE EXCEPTION 'TEST FAILED: table should exist in warn mode';
    END IF;
    RAISE NOTICE 'TEST PASSED: table exists after warn mode CREATE';
END;
$$;

-- Test 2: check() should report padding waste
DO $$
DECLARE
    v_has_padding bool := false;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM pg_column_tetris.check('test_warn_allow')
        WHERE padding_bytes <> '0' AND padding_bytes <> 'variable'
    ) INTO v_has_padding;

    IF NOT v_has_padding THEN
        RAISE EXCEPTION 'TEST FAILED: check() should report non-zero padding';
    END IF;
    RAISE NOTICE 'TEST PASSED: check() reports padding waste';
END;
$$;

-- Cleanup
DROP TABLE IF EXISTS test_warn_allow;
DO $$ BEGIN RAISE NOTICE 'All 02_warn_allows tests passed'; END; $$;
