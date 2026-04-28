-- Test: padding_wasted() function
-- Expected: correct per-row and total waste calculations

-- Setup: need warn mode so test tables can be created with suboptimal order
SELECT column_tetris.set_mode('warn');

-- Test 1: Suboptimal table should have padding waste > 0
CREATE TABLE test_pw_suboptimal (
    flag boolean,
    big_id bigint
);

DO $$
DECLARE
    v_waste int;
BEGIN
    SELECT column_tetris.padding_wasted('test_pw_suboptimal') INTO v_waste;
    IF v_waste <= 0 THEN
        RAISE EXCEPTION 'TEST FAILED: padding_wasted should be > 0 for suboptimal table, got %', v_waste;
    END IF;
    RAISE NOTICE 'TEST PASSED: suboptimal table has % bytes waste per row', v_waste;
END;
$$;

-- Test 2: Optimal table should have 0 waste
CREATE TABLE test_pw_optimal (
    big_id bigint,
    count integer,
    flag boolean
);

DO $$
DECLARE
    v_waste int;
BEGIN
    SELECT column_tetris.padding_wasted('test_pw_optimal') INTO v_waste;
    IF v_waste <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: padding_wasted should be 0 for optimal table, got %', v_waste;
    END IF;
    RAISE NOTICE 'TEST PASSED: optimal table has 0 waste';
END;
$$;

-- Test 3: Non-optimal order but zero actual waste (int4, int4, float8, text)
CREATE TABLE test_pw_zero_waste (
    a integer,
    b integer,
    c float8,
    d text
);

DO $$
DECLARE
    v_waste int;
BEGIN
    SELECT column_tetris.padding_wasted('test_pw_zero_waste') INTO v_waste;
    IF v_waste <> 0 THEN
        RAISE EXCEPTION 'TEST FAILED: int4+int4+float8+text should have 0 waste, got %', v_waste;
    END IF;
    RAISE NOTICE 'TEST PASSED: zero waste despite non-optimal order';
END;
$$;

-- Test 4: Total mode = per_row * row_count
INSERT INTO test_pw_suboptimal (flag, big_id)
SELECT true, generate_series(1, 100);

DO $$
DECLARE
    v_per_row bigint;
    v_total bigint;
BEGIN
    SELECT column_tetris.padding_wasted('test_pw_suboptimal') INTO v_per_row;
    SELECT column_tetris.padding_wasted('test_pw_suboptimal', 'total') INTO v_total;
    IF v_total <> v_per_row * 100 THEN
        RAISE EXCEPTION 'TEST FAILED: total should be % * 100 = %, got %', v_per_row, v_per_row * 100, v_total;
    END IF;
    RAISE NOTICE 'TEST PASSED: total mode = % (% per row * 100 rows)', v_total, v_per_row;
END;
$$;

-- Test 5: Invalid mode raises exception
DO $$
DECLARE
    v_caught bool := false;
BEGIN
    BEGIN
        PERFORM column_tetris.padding_wasted('test_pw_suboptimal', 'bad_mode');
    EXCEPTION WHEN raise_exception THEN
        v_caught := true;
        IF SQLERRM NOT LIKE '%invalid report_mode%' THEN
            RAISE EXCEPTION 'TEST FAILED: unexpected error message: %', SQLERRM;
        END IF;
        RAISE NOTICE 'TEST PASSED: invalid mode rejected';
    END;
    IF NOT v_caught THEN
        RAISE EXCEPTION 'TEST FAILED: invalid mode should raise exception';
    END IF;
END;
$$;

-- Cleanup
DROP TABLE IF EXISTS test_pw_suboptimal;
DROP TABLE IF EXISTS test_pw_optimal;
DROP TABLE IF EXISTS test_pw_zero_waste;
DO $$ BEGIN RAISE NOTICE 'All 06_padding_wasted tests passed'; END; $$;
