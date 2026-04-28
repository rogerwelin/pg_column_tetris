-- pg_column_tetris: Enforce optimal column alignment to minimize row padding
-- Copyright (c) 2026, MIT License

-- ---------------------------------------------------------------------------
-- Schema + Config
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS column_tetris;

CREATE TABLE column_tetris.config (
    mode text NOT NULL DEFAULT 'warn'
        CHECK (mode IN ('strict', 'warn', 'off'))
);

INSERT INTO column_tetris.config (mode) VALUES ('warn');

CREATE TABLE column_tetris.exclusions (
    relname text PRIMARY KEY
);

-- ---------------------------------------------------------------------------
-- Helper functions: mode control + exclusions
-- ---------------------------------------------------------------------------

CREATE FUNCTION column_tetris.set_mode(new_mode text)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF new_mode NOT IN ('strict', 'warn', 'off') THEN
        RAISE EXCEPTION 'invalid mode: %. Must be strict, warn, or off', new_mode;
    END IF;
    UPDATE column_tetris.config SET mode = new_mode;
END;
$$;

CREATE FUNCTION column_tetris.mode()
RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT mode FROM column_tetris.config LIMIT 1;
$$;

CREATE FUNCTION column_tetris.exclude(table_name text)
RETURNS void
LANGUAGE sql AS $$
    INSERT INTO column_tetris.exclusions (relname)
    VALUES (table_name)
    ON CONFLICT (relname) DO NOTHING;
$$;

-- ---------------------------------------------------------------------------
-- compute_layout(oid) — Core alignment analysis
-- ---------------------------------------------------------------------------

CREATE FUNCTION column_tetris.compute_layout(rel_oid oid)
RETURNS TABLE (
    attname       name,
    typname       name,
    typalign      char,
    typlen        int,
    current_position  int,
    optimal_position  int,
    padding_bytes     text
)
LANGUAGE plpgsql VOLATILE
SET search_path TO pg_catalog, pg_temp AS $$
DECLARE
    v_offset       int;
    v_align        int;
    v_padding      int;
    v_num_cols     int;
    v_any_nullable bool;
    v_pos          int;
    rec            record;
BEGIN
    -- Count columns and check for nullable
    SELECT count(*)::int,
           bool_or(NOT a.attnotnull)
      INTO v_num_cols, v_any_nullable
      FROM pg_attribute a
     WHERE a.attrelid = rel_oid
       AND a.attnum > 0
       AND NOT a.attisdropped;

    IF v_num_cols = 0 THEN
        RETURN;
    END IF;

    -- Use a temp table to hold intermediate results
    CREATE TEMP TABLE IF NOT EXISTS _pct_layout (
        col_attname    name,
        col_typname    name,
        col_typalign   char,
        col_typlen     int,
        col_attnotnull bool,
        col_attnum     smallint,
        cur_position   int,
        cur_padding    text,
        opt_position   int,
        opt_padding    text,
        sort_group     int,    -- 1=d(8), 2=i(4), 3=s(2), 4=c(1), 5=varlena
        sort_notnull   int     -- 0=NOT NULL first, 1=nullable
    ) ON COMMIT DROP;

    TRUNCATE _pct_layout;

    -- Load columns
    INSERT INTO _pct_layout (
        col_attname, col_typname, col_typalign, col_typlen,
        col_attnotnull, col_attnum,
        cur_position, cur_padding, opt_position, opt_padding,
        sort_group, sort_notnull
    )
    SELECT a.attname, t.typname, t.typalign, t.typlen,
           a.attnotnull, a.attnum,
           0, '0', 0, '0',
           CASE
               WHEN t.typlen = -1 THEN 5                    -- varlena
               WHEN t.typalign = 'd' THEN 1                 -- 8-byte
               WHEN t.typalign = 'i' THEN 2                 -- 4-byte
               WHEN t.typalign = 's' THEN 3                 -- 2-byte
               WHEN t.typalign = 'c' THEN 4                 -- 1-byte
               ELSE 5
           END,
           CASE WHEN a.attnotnull THEN 0 ELSE 1 END
      FROM pg_attribute a
      JOIN pg_type t ON t.oid = a.atttypid
     WHERE a.attrelid = rel_oid
       AND a.attnum > 0
       AND NOT a.attisdropped
     ORDER BY a.attnum;

    -- -----------------------------------------------------------------------
    -- Pass 1: Current layout (attnum order)
    -- -----------------------------------------------------------------------

    -- HeapTupleHeaderData = 23 bytes
    v_offset := 23;

    -- Null bitmap: 1 bit per column, rounded up to bytes
    IF v_any_nullable THEN
        v_offset := v_offset + ((v_num_cols + 7) / 8);
    END IF;

    -- MAXALIGN to 8-byte boundary (t_hoff)
    v_offset := ((v_offset + 7) / 8) * 8;

    v_pos := 1;
    FOR rec IN
        SELECT col_attname, col_typalign, col_typlen
          FROM _pct_layout
         ORDER BY col_attnum
    LOOP
        IF rec.col_typlen = -1 THEN
            -- Varlena: align to 4 bytes but size is variable
            v_align := 4;
            v_padding := ((v_offset + v_align - 1) / v_align) * v_align - v_offset;
            v_offset := ((v_offset + v_align - 1) / v_align) * v_align;

            UPDATE _pct_layout
               SET cur_position = v_pos,
                   cur_padding = 'variable'
             WHERE col_attname = rec.col_attname;

            -- After varlena, offset is indeterminate for padding calc
            -- but we continue tracking for position numbering
            v_offset := v_offset + 4;  -- minimum varlena header
        ELSE
            v_align := CASE rec.col_typalign
                WHEN 'd' THEN 8
                WHEN 'i' THEN 4
                WHEN 's' THEN 2
                WHEN 'c' THEN 1
                ELSE 4
            END;
            v_padding := ((v_offset + v_align - 1) / v_align) * v_align - v_offset;
            v_offset := ((v_offset + v_align - 1) / v_align) * v_align + rec.col_typlen;

            UPDATE _pct_layout
               SET cur_position = v_pos,
                   cur_padding = v_padding::text
             WHERE col_attname = rec.col_attname;
        END IF;

        v_pos := v_pos + 1;
    END LOOP;

    -- -----------------------------------------------------------------------
    -- Pass 2: Optimal layout
    -- -----------------------------------------------------------------------

    v_offset := 23;
    IF v_any_nullable THEN
        v_offset := v_offset + ((v_num_cols + 7) / 8);
    END IF;
    v_offset := ((v_offset + 7) / 8) * 8;

    v_pos := 1;
    FOR rec IN
        SELECT col_attname, col_typalign, col_typlen
          FROM _pct_layout
         ORDER BY sort_group, sort_notnull, col_attnum
    LOOP
        IF rec.col_typlen = -1 THEN
            v_align := 4;
            v_padding := ((v_offset + v_align - 1) / v_align) * v_align - v_offset;
            v_offset := ((v_offset + v_align - 1) / v_align) * v_align;

            UPDATE _pct_layout
               SET opt_position = v_pos,
                   opt_padding = 'variable'
             WHERE col_attname = rec.col_attname;

            v_offset := v_offset + 4;
        ELSE
            v_align := CASE rec.col_typalign
                WHEN 'd' THEN 8
                WHEN 'i' THEN 4
                WHEN 's' THEN 2
                WHEN 'c' THEN 1
                ELSE 4
            END;
            v_padding := ((v_offset + v_align - 1) / v_align) * v_align - v_offset;
            v_offset := ((v_offset + v_align - 1) / v_align) * v_align + rec.col_typlen;

            UPDATE _pct_layout
               SET opt_position = v_pos,
                   opt_padding = v_padding::text
             WHERE col_attname = rec.col_attname;
        END IF;

        v_pos := v_pos + 1;
    END LOOP;

    -- Return results in current column order
    RETURN QUERY
        SELECT l.col_attname, l.col_typname, l.col_typalign, l.col_typlen,
               l.cur_position, l.opt_position, l.cur_padding
          FROM _pct_layout l
         ORDER BY l.cur_position;

    DROP TABLE IF EXISTS _pct_layout;
    RETURN;
END;
$$;

-- ---------------------------------------------------------------------------
-- check(text) — User-friendly wrapper
-- ---------------------------------------------------------------------------

CREATE FUNCTION column_tetris.check(relation_name text)
RETURNS TABLE (
    attname       name,
    typname       name,
    typalign      char,
    typlen        int,
    current_position  int,
    optimal_position  int,
    padding_bytes     text
)
LANGUAGE sql VOLATILE AS $$
    SELECT * FROM column_tetris.compute_layout(relation_name::regclass::oid);
$$;

-- ---------------------------------------------------------------------------
-- padding_wasted(text) — Returns bytes of avoidable padding per row
-- ---------------------------------------------------------------------------

CREATE FUNCTION column_tetris.padding_wasted(relation_name text, report_mode text DEFAULT 'row')
RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_rel_oid      oid;
    v_current_waste  int := 0;
    v_optimal_waste  int := 0;
    v_offset       int;
    v_align        int;
    v_padding      int;
    v_num_cols     int;
    v_any_nullable bool;
    v_row_count    bigint;
    col            record;
BEGIN
    IF report_mode NOT IN ('row', 'total') THEN
        RAISE EXCEPTION 'invalid report_mode: %. Must be row or total', report_mode;
    END IF;

    v_rel_oid := relation_name::regclass::oid;

    SELECT count(*)::int, bool_or(NOT a.attnotnull)
      INTO v_num_cols, v_any_nullable
      FROM pg_attribute a
     WHERE a.attrelid = v_rel_oid
       AND a.attnum > 0
       AND NOT a.attisdropped;

    IF v_num_cols = 0 THEN
        RETURN 0;
    END IF;

    -- Current layout waste
    v_offset := 23;
    IF v_any_nullable THEN
        v_offset := v_offset + ((v_num_cols + 7) / 8);
    END IF;
    v_offset := ((v_offset + 7) / 8) * 8;

    FOR col IN
        SELECT t.typalign, t.typlen
          FROM pg_attribute a
          JOIN pg_type t ON t.oid = a.atttypid
         WHERE a.attrelid = v_rel_oid
           AND a.attnum > 0
           AND NOT a.attisdropped
         ORDER BY a.attnum
    LOOP
        IF col.typlen = -1 THEN
            v_align := 4;
            v_offset := ((v_offset + v_align - 1) / v_align) * v_align + 4;
        ELSE
            v_align := CASE col.typalign
                WHEN 'd' THEN 8 WHEN 'i' THEN 4
                WHEN 's' THEN 2 WHEN 'c' THEN 1 ELSE 4
            END;
            v_padding := ((v_offset + v_align - 1) / v_align) * v_align - v_offset;
            v_current_waste := v_current_waste + v_padding;
            v_offset := ((v_offset + v_align - 1) / v_align) * v_align + col.typlen;
        END IF;
    END LOOP;

    -- Optimal layout waste
    v_offset := 23;
    IF v_any_nullable THEN
        v_offset := v_offset + ((v_num_cols + 7) / 8);
    END IF;
    v_offset := ((v_offset + 7) / 8) * 8;

    FOR col IN
        SELECT t.typalign, t.typlen
          FROM pg_attribute a
          JOIN pg_type t ON t.oid = a.atttypid
         WHERE a.attrelid = v_rel_oid
           AND a.attnum > 0
           AND NOT a.attisdropped
         ORDER BY
           CASE
               WHEN t.typlen = -1 THEN 5
               WHEN t.typalign = 'd' THEN 1
               WHEN t.typalign = 'i' THEN 2
               WHEN t.typalign = 's' THEN 3
               WHEN t.typalign = 'c' THEN 4
               ELSE 5
           END,
           CASE WHEN a.attnotnull THEN 0 ELSE 1 END,
           a.attnum
    LOOP
        IF col.typlen = -1 THEN
            v_align := 4;
            v_offset := ((v_offset + v_align - 1) / v_align) * v_align + 4;
        ELSE
            v_align := CASE col.typalign
                WHEN 'd' THEN 8 WHEN 'i' THEN 4
                WHEN 's' THEN 2 WHEN 'c' THEN 1 ELSE 4
            END;
            v_padding := ((v_offset + v_align - 1) / v_align) * v_align - v_offset;
            v_optimal_waste := v_optimal_waste + v_padding;
            v_offset := ((v_offset + v_align - 1) / v_align) * v_align + col.typlen;
        END IF;
    END LOOP;

    IF report_mode = 'total' THEN
        EXECUTE format('SELECT count(*) FROM %s', v_rel_oid::regclass) INTO v_row_count;
        RETURN (v_current_waste - v_optimal_waste)::bigint * v_row_count;
    END IF;

    RETURN (v_current_waste - v_optimal_waste)::bigint;
END;
$$;

-- ---------------------------------------------------------------------------
-- validate(oid) — Raises exception if layout is suboptimal
-- ---------------------------------------------------------------------------

CREATE FUNCTION column_tetris.validate(rel_oid oid)
RETURNS void
LANGUAGE plpgsql
SET search_path TO pg_catalog, pg_temp AS $$
DECLARE
    v_current_waste  int := 0;
    v_optimal_waste  int := 0;
    v_hint           text := '';
    v_relname        text;
    v_align_comment  text;
    v_offset         int;
    v_align          int;
    v_padding        int;
    v_num_cols       int;
    v_any_nullable   bool;
    col              record;
BEGIN
    -- Get table name for error message
    SELECT c.relname INTO v_relname
      FROM pg_class c
     WHERE c.oid = rel_oid;

    -- Count columns and check for nullable
    SELECT count(*)::int, bool_or(NOT a.attnotnull)
      INTO v_num_cols, v_any_nullable
      FROM pg_attribute a
     WHERE a.attrelid = rel_oid
       AND a.attnum > 0
       AND NOT a.attisdropped;

    IF v_num_cols = 0 THEN
        RETURN;
    END IF;

    -- -----------------------------------------------------------------------
    -- Pass 1: Current layout waste (attnum order)
    -- -----------------------------------------------------------------------
    v_offset := 23;
    IF v_any_nullable THEN
        v_offset := v_offset + ((v_num_cols + 7) / 8);
    END IF;
    v_offset := ((v_offset + 7) / 8) * 8;

    FOR col IN
        SELECT a.attname, t.typname, t.typalign, t.typlen, a.attnotnull, a.attnum
          FROM pg_attribute a
          JOIN pg_type t ON t.oid = a.atttypid
         WHERE a.attrelid = rel_oid
           AND a.attnum > 0
           AND NOT a.attisdropped
         ORDER BY a.attnum
    LOOP
        IF col.typlen = -1 THEN
            v_align := 4;
            v_offset := ((v_offset + v_align - 1) / v_align) * v_align + 4;
        ELSE
            v_align := CASE col.typalign
                WHEN 'd' THEN 8 WHEN 'i' THEN 4
                WHEN 's' THEN 2 WHEN 'c' THEN 1 ELSE 4
            END;
            v_padding := ((v_offset + v_align - 1) / v_align) * v_align - v_offset;
            v_current_waste := v_current_waste + v_padding;
            v_offset := ((v_offset + v_align - 1) / v_align) * v_align + col.typlen;
        END IF;
    END LOOP;

    -- -----------------------------------------------------------------------
    -- Pass 2: Optimal layout waste + build HINT string
    -- -----------------------------------------------------------------------
    v_offset := 23;
    IF v_any_nullable THEN
        v_offset := v_offset + ((v_num_cols + 7) / 8);
    END IF;
    v_offset := ((v_offset + 7) / 8) * 8;

    v_hint := E'Suggested order:\n    CREATE TABLE ' || v_relname || E' (\n';

    FOR col IN
        SELECT a.attname, t.typname, t.typalign, t.typlen, a.attnotnull, a.attnum,
               CASE
                   WHEN t.typlen = -1 THEN 5
                   WHEN t.typalign = 'd' THEN 1
                   WHEN t.typalign = 'i' THEN 2
                   WHEN t.typalign = 's' THEN 3
                   WHEN t.typalign = 'c' THEN 4
                   ELSE 5
               END AS sort_group,
               CASE WHEN a.attnotnull THEN 0 ELSE 1 END AS sort_notnull
          FROM pg_attribute a
          JOIN pg_type t ON t.oid = a.atttypid
         WHERE a.attrelid = rel_oid
           AND a.attnum > 0
           AND NOT a.attisdropped
         ORDER BY sort_group, sort_notnull, a.attnum
    LOOP
        IF col.typlen = -1 THEN
            v_align := 4;
            v_offset := ((v_offset + v_align - 1) / v_align) * v_align + 4;
            v_align_comment := 'varlena (last)';
        ELSE
            v_align := CASE col.typalign
                WHEN 'd' THEN 8 WHEN 'i' THEN 4
                WHEN 's' THEN 2 WHEN 'c' THEN 1 ELSE 4
            END;
            v_padding := ((v_offset + v_align - 1) / v_align) * v_align - v_offset;
            v_optimal_waste := v_optimal_waste + v_padding;
            v_offset := ((v_offset + v_align - 1) / v_align) * v_align + col.typlen;
            v_align_comment := v_align::text || '-byte aligned';
        END IF;

        v_hint := v_hint || '        ' || col.attname || ' ' || col.typname;
        IF col.attnotnull THEN
            v_hint := v_hint || ' NOT NULL';
        END IF;
        v_hint := v_hint || ',' || repeat(' ', greatest(1, 24 - length(col.attname || ' ' || col.typname)))
                || '-- ' || v_align_comment || E'\n';
    END LOOP;

    -- Remove trailing comma from last column
    v_hint := regexp_replace(v_hint, E',([^,]*)$', E'\\1');
    v_hint := v_hint || '    );';

    IF v_current_waste > v_optimal_waste THEN
        RAISE EXCEPTION 'suboptimal column alignment — % bytes of fixed-width padding wasted per row',
            v_current_waste
            USING DETAIL = format(
                'Current fixed-width layout wastes %s bytes per row in alignment padding; optimal order wastes %s.',
                v_current_waste, v_optimal_waste
            ),
            HINT = v_hint;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- suggest_rewrite(text) — Generate migration DDL
-- ---------------------------------------------------------------------------

CREATE FUNCTION column_tetris.suggest_rewrite(relation_name text)
RETURNS text
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_oid       oid;
    v_relname   text;
    v_schema    text;
    v_ddl       text;
    v_cols      text := '';
    v_select    text := '';
    col         record;
BEGIN
    v_oid := relation_name::regclass::oid;

    SELECT n.nspname, c.relname
      INTO v_schema, v_relname
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.oid = v_oid;

    FOR col IN
        SELECT a.attname, format_type(a.atttypid, a.atttypmod) AS col_type,
               a.attnotnull,
               CASE
                   WHEN t.typlen = -1 THEN 5
                   WHEN t.typalign = 'd' THEN 1
                   WHEN t.typalign = 'i' THEN 2
                   WHEN t.typalign = 's' THEN 3
                   WHEN t.typalign = 'c' THEN 4
                   ELSE 5
               END AS sort_group,
               CASE WHEN a.attnotnull THEN 0 ELSE 1 END AS sort_notnull,
               a.attnum
          FROM pg_attribute a
          JOIN pg_type t ON t.oid = a.atttypid
         WHERE a.attrelid = v_oid
           AND a.attnum > 0
           AND NOT a.attisdropped
         ORDER BY sort_group, sort_notnull, a.attnum
    LOOP
        IF v_cols <> '' THEN
            v_cols := v_cols || E',\n';
            v_select := v_select || ', ';
        END IF;
        v_cols := v_cols || '    ' || col.attname || ' ' || col.col_type;
        IF col.attnotnull THEN
            v_cols := v_cols || ' NOT NULL';
        END IF;
        v_select := v_select || col.attname;
    END LOOP;

    v_ddl := format(
        E'BEGIN;\n\nALTER TABLE %I.%I RENAME TO %I;\n\nCREATE TABLE %I.%I (\n%s\n);\n\nINSERT INTO %I.%I\nSELECT %s\n  FROM %I.%I;\n\nDROP TABLE %I.%I;\n\nCOMMIT;',
        v_schema, v_relname, v_relname || '_old',
        v_schema, v_relname, v_cols,
        v_schema, v_relname, v_select,
        v_schema, v_relname || '_old',
        v_schema, v_relname || '_old'
    );

    RETURN v_ddl;
END;
$$;

-- ---------------------------------------------------------------------------
-- ddl_check() — Event trigger function
-- ---------------------------------------------------------------------------

CREATE FUNCTION column_tetris.ddl_check()
RETURNS event_trigger
LANGUAGE plpgsql
SET search_path TO pg_catalog, pg_temp AS $$
DECLARE
    r            record;
    current_mode text;
BEGIN
    SELECT mode INTO current_mode FROM column_tetris.config LIMIT 1;

    IF current_mode = 'off' THEN
        RETURN;
    END IF;

    FOR r IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
        -- Only care about CREATE TABLE
        IF r.command_tag <> 'CREATE TABLE' THEN
            CONTINUE;
        END IF;

        -- Skip temp schemas
        IF r.schema_name LIKE 'pg_temp%' THEN
            CONTINUE;
        END IF;

        -- Skip system schemas
        IF r.schema_name IN ('pg_catalog', 'information_schema', 'column_tetris') THEN
            CONTINUE;
        END IF;

        -- Skip excluded tables
        IF EXISTS (
            SELECT 1 FROM column_tetris.exclusions
             WHERE relname = r.object_identity
                OR relname = split_part(r.object_identity, '.', 2)
                OR relname = split_part(r.object_identity, '.', 1)
        ) THEN
            CONTINUE;
        END IF;

        IF current_mode = 'strict' THEN
            -- Exception propagates → rolls back the CREATE TABLE
            PERFORM column_tetris.validate(r.objid);
        ELSIF current_mode = 'warn' THEN
            BEGIN
                PERFORM column_tetris.validate(r.objid);
            EXCEPTION WHEN raise_exception THEN
                RAISE NOTICE 'pg_column_tetris: %', SQLERRM;
                RAISE NOTICE 'HINT: Run SELECT * FROM column_tetris.check(''%'') for details', r.object_identity;
            END;
        END IF;
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Event trigger registration
-- ---------------------------------------------------------------------------

CREATE EVENT TRIGGER pg_column_tetris_ddl_check
    ON ddl_command_end
    EXECUTE FUNCTION column_tetris.ddl_check();
