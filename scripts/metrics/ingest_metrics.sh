#!/usr/bin/env bash
set -euo pipefail
SERVICE="${SERVICE:-timescaledb}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-vantam}"
OUTDIR="${OUTDIR:-analysis/metrics/ingest}"
mkdir -p "$OUTDIR"

# Progress
docker compose exec -T "$SERVICE" psql -U "$PGUSER" -d "$PGDATABASE" -c \
"COPY (
  SELECT symbol, exchange, MIN(ts) AS first_ts, MAX(ts) AS last_ts, COUNT(*) AS rows
  FROM ohlcv_1m GROUP BY symbol, exchange ORDER BY symbol
) TO STDOUT WITH CSV HEADER" > "$OUTDIR/progress.csv"

# Lag vs now
docker compose exec -T "$SERVICE" psql -U "$PGUSER" -d "$PGDATABASE" -c \
"COPY (
  SELECT symbol, (now() - MAX(ts))::text AS lag
  FROM ohlcv_1m GROUP BY symbol ORDER BY symbol
) TO STDOUT WITH CSV HEADER" > "$OUTDIR/lag.csv"

echo "✅ Ingest metrics in $OUTDIR"
ls -1 "$OUTDIR"