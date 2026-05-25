# pg_clickhouse → Tinybird bridge

> **Example repository — provided as-is, not actively maintained.** A working
> starting point for connecting Postgres-only BI tools (Amazon QuickSight,
> Metabase OSS, Looker Studio, ...) to [Tinybird](https://www.tinybird.co) via
> the [`pg_clickhouse`](https://github.com/ClickHouse/pg_clickhouse) Foreign
> Data Wrapper. Adapt it freely; issues and PRs are welcome but no support is
> guaranteed.

A small docker-compose stack that runs `pg_clickhouse` inside Postgres 18 and
points it at Tinybird's [ClickHouse-compatible HTTP interface](https://www.tinybird.co/docs/forward/work-with-data/publish-data/clickhouse-interface).

The motivating use case is **Amazon QuickSight**, which only speaks Postgres.
Pointing QuickSight at this bridge lets it issue SQL that the FDW transparently
pushes down to Tinybird.

```
+-------------+        Postgres wire        +-------------------+       HTTPS / TSV       +----------------+
| QuickSight  | ─────────────────────────▶  | Postgres 18 +     | ──────────────────────▶ | Tinybird CH    |
| (or any PG  |                             | pg_clickhouse FDW |                         | interface :443 |
| client)     | ◀─────────────────────────  |                   | ◀────────────────────── |                |
+-------------+                             +-------------------+                         +----------------+
```

## Quick start

Prerequisites: Docker with Compose v2, and `make`.

```sh
# 1. Configure your Tinybird credentials
cp .env.example .env
# Edit .env and fill in TB_HOST, TB_WORKSPACE, TB_TOKEN

# 2. Start the bridge — boots Postgres, runs the init script, imports your tables
make up

# 3. Open a psql shell against the bridge
make psql
```

Once inside `psql`, sanity-check the setup:

```sql
-- Extension and foreign server are installed
\dx pg_clickhouse
SELECT srvname, srvoptions FROM pg_foreign_server WHERE srvname = 'tinybird';

-- Foreign tables imported from your workspace into schema `tb`
\det tb.*

-- Run a query against one of your data sources
SELECT * FROM tb.<your_data_source> LIMIT 10;

-- Confirm predicate / aggregate pushdown (look for "Remote SQL")
EXPLAIN (VERBOSE, COSTS off)
SELECT date_trunc('hour', <ts_col>) AS hour, count(*)
FROM tb.<your_data_source>
WHERE <ts_col> >= now() - interval '24 hours'
GROUP BY 1;
```

The bridge listens on `localhost:5432` (overridable with `POSTGRES_PORT`).
Point QuickSight (or any Postgres client) at it: database `tinybird_bridge`,
schema `tb`, the credentials you set in `.env`.

## How the mapping works

| pg_clickhouse                                           | Tinybird CH interface                                                                                                                                                                                                                                |
|---------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `driver 'http'`                                         | Required — Tinybird only exposes HTTP, no native protocol                                                                                                                                                                                            |
| `port '443'`                                            | Treated as HTTPS by pg_clickhouse (`src/http.c` `HTTP_TLS_PORT`)                                                                                                                                                                                     |
| `host` URL with Basic Auth                              | `Authorization: Basic` → token taken from password, user discarded                                                                                                                                                                                   |
| `OPTIONS (password '...')`                              | Use a Tinybird token with read scope; the `user` field is ignored                                                                                                                                                                                    |
| `dbname '<workspace>'`                                  | **Not** used for routing on the server — the token decides. The FDW does prepend it to outgoing SQL (`SELECT ... FROM <workspace>.foo`), so cross-database refs (e.g. `system.tables`) need a per-foreign-table `OPTIONS (database '...')` override. |
| `X-ClickHouse-Database` header                          | **Ignored** by Tinybird                                                                                                                                                                                                                              |
| `SHOW DATABASES` / `SHOW TABLES`                        | Translated server-side to queries over `system.tables`/`system.databases`                                                                                                                                                                            |
| `EXISTS TABLE x`                                        | Translated to `SELECT 1 FROM system.tables WHERE ...`                                                                                                                                                                                                |
| `currentUser()` / `currentDatabase()` / `displayName()` | Replaced with constants (e.g. `currentDatabase()` returns `default`, not the actual workspace name)                                                                                                                                                  |
| `IMPORT FOREIGN SCHEMA`                                 | Works — but pre-probe `system.columns` and `EXCEPT` tables with `AggregateFunction(...)` columns; pg_clickhouse can't map those types and one bad table aborts the whole import                                                                      |
| `?date_time_output_format=iso` etc.                     | Not in the allow-list, silently dropped — CH's default format works                                                                                                                                                                                  |

## Known limitations

1. **`dbname` doesn't route.** Tinybird routes by token, period. If your token
   belongs to workspace `analytics`, you can only see tables in `analytics`.
   Cross-workspace queries are not possible through one server. To bridge
   multiple workspaces, define multiple `CREATE SERVER`s, each with its own
   `USER MAPPING` carrying that workspace's token.

2. **Fully qualified names.** Inside the workspace, references like
   `system.tables` work, but if you write SQL that depends on
   `currentDatabase()` returning the actual CH database (e.g.
   `SELECT ... FROM currentDatabase() || '.foo'`), it won't — the function is
   stubbed.

3. **DateTime formatting.** pg_clickhouse forces
   `date_time_output_format=iso`, but Tinybird drops that. The TSV parser in
   pg_clickhouse copes with CH's default `YYYY-MM-DD HH:MM:SS` form, so this
   is not a blocker. If a query returns columns of an unusual type and parses
   oddly, this is the first place to look.

4. **Writes are not supported.** The Tinybird CH interface is read-only. The
   FDW will accept `INSERT/UPDATE/DELETE` syntactically but Tinybird will
   reject them.

5. **Rate limits and `max_execution_time`.** Queries are subject to your
   workspace's CH limits. Long BI-tool queries may need a token attached to
   a workspace with raised limits.

6. **`AggregateFunction(...)` columns.** Materialized-view backing tables
   often have columns like `AggregateFunction(quantilesTiming(0.95, 0.99), Float64)`.
   pg_clickhouse cannot map these to a Postgres type, and one such column
   aborts the entire `IMPORT FOREIGN SCHEMA`. `setup_fdw.sql` probes
   `system.columns` first and rewrites the import to `EXCEPT (...)` those
   tables. The skipped tables are listed in the init log; you can still query
   them via a handwritten foreign table that lists only the supported
   columns. Materialized views you `SELECT` from in your pipes usually import
   cleanly.

7. **Querying `system.*` tables.** The FDW prefixes table names with the
   server-level `dbname`, so a foreign table over `system.tables` is sent as
   `SELECT … FROM <workspace>.system.tables`, which Tinybird rejects (HTTP
   403). Override per foreign table with `OPTIONS (database 'system',
   table_name 'tables')`. `setup_fdw.sql` pre-creates `tb._ch_system_tables`
   and `tb._ch_system_columns` so callers don't have to remember.

## Files

```
pg_clickhouse_poc/
├── .env.example          # template — copy to .env and fill in
├── .gitignore            # keeps your .env out of git
├── docker-compose.yml    # ghcr.io/clickhouse/pg_clickhouse:18 (mounts pgdata
│                         #   at /var/lib/postgresql, not /var/lib/postgresql/data
│                         #   — Postgres 18 layout, see docker-library/postgres#1259)
├── LICENSE               # MIT
├── Makefile              # up / down / reset / psql / logs shortcuts
├── README.md             # this file
└── init/
    ├── 01_setup_fdw.sh        # Postgres init hook; runs once on first start
    └── lib/
        └── setup_fdw.sql      # CREATE EXTENSION / SERVER / USER MAPPING,
                               # convenience tb._ch_system_{tables,columns}
                               # foreign tables, and dynamic IMPORT FOREIGN
                               # SCHEMA that EXCEPTs AggregateFunction tables
                               # (lib/ keeps it out of Postgres's auto-run path)
```

## Iterating on the setup

The init scripts only run on **first** container start (Postgres convention).
If you change `.env` or `setup_fdw.sql`, recreate the volume:

```sh
make reset
```

`make logs` tails the Postgres logs (useful to see which tables were skipped
during the initial import).

## Pointing QuickSight at the bridge

In QuickSight's "New data source" flow:

- Type: **PostgreSQL**
- Server: the hostname running this stack (or its public IP / VPC endpoint)
- Port: `5432` (or whatever `POSTGRES_PORT` you set)
- Database: `tinybird_bridge`
- Username / password: the values from `.env`
- SSL: enable if you've fronted the bridge with TLS (recommended for prod)

QuickSight will then list `tb.*` as available tables.

## Going to production

This stack is a PoC — things you'd want to harden before depending on it:

- Put the bridge behind TLS (Cloud SQL, RDS Postgres + pg_clickhouse build,
  or a sidecar with `stunnel` / `pgbouncer`).
- Store `TB_TOKEN` in a secret manager rather than a `.env` file.
- Set tight `max_execution_time` / `max_result_bytes` on the Tinybird
  workspace to bound runaway dashboard queries.
- Consider one Postgres user per BI dataset, each with its own `USER MAPPING`
  carrying a narrowly scoped Tinybird token.
- Monitor `pipe_stats_rt` in Tinybird — every BI query lands there under the
  CH-interface pipe.

## Upstream references

- Tinybird CH interface docs: <https://www.tinybird.co/docs/forward/work-with-data/publish-data/clickhouse-interface>
- pg_clickhouse repo: <https://github.com/ClickHouse/pg_clickhouse>
- pg_clickhouse tutorial: <https://github.com/ClickHouse/pg_clickhouse/blob/main/doc/tutorial.md>
- pg_clickhouse SQL reference: <https://github.com/ClickHouse/pg_clickhouse/blob/main/doc/pg_clickhouse.md>

## License

MIT — see [LICENSE](LICENSE).
