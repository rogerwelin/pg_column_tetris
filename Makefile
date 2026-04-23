EXTENSION = pg_column_tetris
DATA = pg_column_tetris--0.1.0.sql

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
