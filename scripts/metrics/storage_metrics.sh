#!/usr/bin/env bash
set -euo pipefail
SERVICE="${SERVICE:-timescaledb}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-vantam}"
OUTDIR="${OUTDIR:-analysis/metrics/storage}"
mkdir -p "$OUTDIR"

# DB size (txt)
docker compose exec -T "$SERVICE" psql -U "$PGUSER" -d "$PGDATABASE" -t -A -c \
"SELECT pg_size_pretty(pg_database_size('$PGDATABASE'))" > "$OUTDIR/db_size.txt"

# Hypertable size breakdown
docker compose exec -T "$SERVICE" psql -U "$PGUSER" -d "$PGDATABASE" -c \
"COPY (
  SELECT pg_size_pretty(table_bytes)  AS table_size,
         pg_size_pretty(index_bytes)  AS index_size,
         pg_size_pretty(toast_bytes)  AS toast_size,
         pg_size_pretty(total_bytes)  AS total_size
  FROM hypertable_detailed_size('ohlcv_1m')
) TO STDOUT WITH CSV HEADER" > "$OUTDIR/hypertable_size.csv"

# Chunk count & top chunks
docker compose exec -T "$SERVICE" psql -U "$PGUSER" -d "$PGDATABASE" -t -A -c \
"SELECT COUNT(*) FROM timescaledb_information.chunks WHERE hypertable_name='ohlcv_1m'" > "$OUTDIR/chunk_count.txt"

docker compose exec -T "$SERVICE" psql -U "$PGUSER" -d "$PGDATABASE" -c \
"COPY (
  SELECT chunk_schema||'.'||chunk_name AS chunk,
         pg_size_pretty(total_bytes)   AS total,
         pg_size_pretty(table_bytes)   AS table_only,
         pg_size_pretty(index_bytes)   AS indexes
  FROM chunks_detailed_size('ohlcv_1m')
  ORDER BY total_bytes DESC
  LIMIT 20
) TO STDOUT WITH CSV HEADER" > "$OUTDIR/chunks_top20.csv"

echo "✅ Storage metrics in $OUTDIR"
ls -1 "$OUTDIR"
