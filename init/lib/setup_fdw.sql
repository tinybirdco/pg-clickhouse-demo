-- Sourced by 01_setup_fdw.sh on first container start.
-- Variables bound by psql --set on the command line:
--   :tb_host        Tinybird CH-interface host (e.g. clickhouse.us-east.aws.tinybird.co)
--   :tb_workspace   Workspace name (informational; routing is by token)
--   :tb_token       A Tinybird token with read scope
--   :pg_role        Local Postgres role that the USER MAPPING targets
--
-- psql variable quoting reminders:
--   :'name'   -> quoted as a SQL string literal
--   :"name"   -> quoted as a SQL identifier

CREATE EXTENSION IF NOT EXISTS pg_clickhouse;

-- Foreign server pointing at the Tinybird CH interface.
--   driver = http  -> HTTP transport. Tinybird does not expose the native TCP protocol.
--   port   = 443   -> recognized as TLS by pg_clickhouse (src/http.c HTTP_TLS_PORT).
--   dbname = workspace name. Tinybird ignores X-ClickHouse-Database and routes
--            entirely by token; pg_clickhouse uses it to prefix table names in
--            outgoing SQL (e.g. SELECT ... FROM <workspace>.foo). For tables that
--            live in `system.*`, override with `OPTIONS (database 'system', ...)`.
DROP SERVER IF EXISTS tinybird CASCADE;
CREATE SERVER tinybird
  FOREIGN DATA WRAPPER clickhouse_fdw
  OPTIONS (
    driver 'http',
    host :'tb_host',
    port '443',
    dbname :'tb_workspace'
  );

-- The Basic-Auth "user" is discarded by Tinybird; the token goes in `password`.
CREATE USER MAPPING FOR :"pg_role"
  SERVER tinybird
  OPTIONS (user 'tinybird', password :'tb_token');

-- Local schema to hold the imported foreign tables.
CREATE SCHEMA IF NOT EXISTS tb;

-- Convenience foreign tables over system.* so callers can introspect the
-- workspace without re-deriving the `database 'system'` override every time.
DROP FOREIGN TABLE IF EXISTS tb._ch_system_tables;
CREATE FOREIGN TABLE tb._ch_system_tables (
  database TEXT,
  name     TEXT,
  engine   TEXT
) SERVER tinybird OPTIONS (database 'system', table_name 'tables');

DROP FOREIGN TABLE IF EXISTS tb._ch_system_columns;
CREATE FOREIGN TABLE tb._ch_system_columns (
  database TEXT,
  "table"  TEXT,
  name     TEXT,
  type     TEXT
) SERVER tinybird OPTIONS (database 'system', table_name 'columns');

-- IMPORT FOREIGN SCHEMA bails on the whole import if any table has a column
-- type pg_clickhouse can't map. The most common offender in real Tinybird
-- workspaces is `AggregateFunction(...)` on materialized-view backing tables.
-- We probe system.columns first and EXCEPT those tables out, so the import
-- always brings in everything that *can* be imported.
\echo Discovering tables with unsupported AggregateFunction columns...
SELECT "table" AS skipped_table
FROM tb._ch_system_columns
WHERE database = :'tb_workspace' AND type LIKE 'AggregateFunction%'
GROUP BY 1 ORDER BY 1;

-- Build and execute the IMPORT statement. \gexec runs each returned row as SQL.
WITH bad AS (
  SELECT DISTINCT quote_ident("table") AS qname
  FROM tb._ch_system_columns
  WHERE database = :'tb_workspace' AND type LIKE 'AggregateFunction%'
)
SELECT CASE WHEN (SELECT count(*) FROM bad) > 0
            THEN format('IMPORT FOREIGN SCHEMA %I EXCEPT (%s) FROM SERVER tinybird INTO tb',
                        :'tb_workspace',
                        (SELECT string_agg(qname, ', ') FROM bad))
            ELSE format('IMPORT FOREIGN SCHEMA %I FROM SERVER tinybird INTO tb',
                        :'tb_workspace')
       END AS import_stmt
\gexec

\echo Imported foreign tables:
SELECT count(*) AS imported_foreign_tables
FROM information_schema.foreign_tables
WHERE foreign_table_schema = 'tb' AND foreign_table_name NOT LIKE '\_%';
