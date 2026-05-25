#!/usr/bin/env bash
# Postgres init hook (runs once on first container start).
# We use a shell script (not plain .sql) so we can pipe the values of
# TB_HOST/TB_WORKSPACE/TB_TOKEN from compose env into psql as bound
# variables — never substituting them into raw SQL text.
set -euo pipefail

: "${TB_HOST:?TB_HOST must be set}"
: "${TB_WORKSPACE:?TB_WORKSPACE must be set}"
: "${TB_TOKEN:?TB_TOKEN must be set}"
: "${POSTGRES_USER:?POSTGRES_USER must be set}"
: "${POSTGRES_DB:?POSTGRES_DB must be set}"

psql -v ON_ERROR_STOP=1 \
     --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" \
     --set=tb_host="${TB_HOST}" \
     --set=tb_workspace="${TB_WORKSPACE}" \
     --set=tb_token="${TB_TOKEN}" \
     --set=pg_role="${POSTGRES_USER}" \
     --file=/docker-entrypoint-initdb.d/lib/setup_fdw.sql

echo "pg_clickhouse FDW setup complete. Foreign server: tinybird -> ${TB_HOST}:443"
