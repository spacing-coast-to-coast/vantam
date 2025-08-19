#!/usr/bin/env bash
set -euo pipefail

# -------- Config --------
SERVICE="${SERVICE:-timescaledb}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-vantam}"

# Modes: fast | core | deep
MODE="${MODE:-core}"

# Window knobs
DAYS="${DAYS:-ALL}"          # daily coverage window; "ALL" = entire history
HOURS_DAYS="${HOURS_DAYS:-7}" # hourly coverage window; "ALL" = entire history (big)
TOP="${TOP:-50}"             # top-N largest gaps
WINDOW_DAYS="${WINDOW_DAYS:-}" # optional calendar window (e.g., 90)
WHERE_CLAUSE="${WHERE_CLAUSE:-}" # e.g., "WHERE symbol IN ('BTC/USDT') AND exchange='binanceus'"
BLACKOUT_THRESHOLD_MINUTES="${BLACKOUT_THRESHOLD_MINUTES:-1440}"

OUTDIR="${OUTDIR:-analysis/metrics/coverage}"
mkdir -p "$OUTDIR"

# -------- Mode switch -> which sections run --------
RUN_1=0 RUN_2=0 RUN_3=0 RUN_4=0 RUN_5=0 RUN_6=0 RUN_7=0 RUN_8=0 RUN_9=0 RUN_10=0 RUN_11=0 RUN_12=0 RUN_13=0
case "$MODE" in
  fast)
    RUN_1=1  # span coverage
    RUN_2=1  # daily (windowed by DAYS if set; use ALL carefully)
    RUN_6=1  # expected vs actual
    RUN_11=1 # monthly coverage
    ;;
  core)
    RUN_1=1
    RUN_2=1
    RUN_6=1
    RUN_9=1  # in-span daily (first nonzero -> last)
    RUN_11=1
    ;;
  deep)
    RUN_1=1
    RUN_2=1
    RUN_3=1  # hourly (windowed)
    RUN_4=1  # gap summary (heavy)
    RUN_5=1  # top gaps (heavy)
    RUN_6=1
    RUN_7=1  # duplicates
    RUN_8=1  # future rows
    RUN_9=1
    RUN_10=1 # calendar-window daily (only if WINDOW_DAYS set)
    RUN_11=1
    RUN_12=1 # blackout windows (heavy)
    RUN_13=1 # adjusted coverage (heavy)
    ;;
  *)
    echo "Unknown MODE='$MODE' (use fast|core|deep)"; exit 2;;
esac

# -------- Helper filters --------
FILTER_DAILY=""
if [[ "${DAYS}" != "ALL" && -n "${DAYS}" ]]; then
  FILTER_DAILY="WHERE ts >= now() - interval '${DAYS} days'"
fi

FILTER_HOURLY=""
if [[ "${HOURS_DAYS}" != "ALL" && -n "${HOURS_DAYS}" ]]; then
  FILTER_HOURLY="WHERE ts >= now() - interval '${HOURS_DAYS} days'"
fi

# -------- 1) Full-span coverage --------
if [[ $RUN_1 -eq 1 ]]; then
docker compose exec -T "$SERVICE" psql -U "$PGUSER" -d "$PGDATABASE" -c "COPY ( \
  SELECT symbol, exchange, MIN(ts) AS first_ts, MAX(ts) AS last_ts, COUNT(*) AS rows, \
         (EXTRACT(EPOCH FROM (MAX(ts)-MIN(ts)))/60 + 1)::bigint AS expected_rows, \
         ROUND(100.0 * COUNT(*) / NULLIF((EXTRACT(EPOCH FROM (MAX(ts)-MIN(ts)))/60 + 1),0), 2) AS coverage_pct, \
         ((EXTRACT(EPOCH FROM (MAX(ts)-MIN(ts)))/60 + 1)::bigint - COUNT(*)) AS missing_minutes \
  FROM ohlcv_1m ${WHERE_CLAUSE} \
  GROUP BY symbol, exchange \
  ORDER BY coverage_pct ASC, symbol \
) TO STDOUT WITH CSV HEADER" > "$OUTDIR/coverage.csv"
fi

# -------- 2) Daily coverage (windowed by DAYS if set) --------
if [[ $RUN_2 -eq 1 ]]; then
docker compose exec -T "$SERVICE" psql -U "$PGUSER" -d "$PGDATABASE" -c "COPY ( \
  WITH d AS ( \
    SELECT symbol, exchange, time_bucket('1 day', ts) AS day, COUNT(*) AS rows \
    FROM ohlcv_1m ${FILTER_DAILY} \
    GROUP BY symbol, exchange, day \
  ) \
  SELECT symbol, exchange, day::date AS day, rows, 1440 AS expected_rows, \
         ROUND(100.0 * rows / 1440.0, 2) AS day_coverage_pct \
  FROM d \
  ORDER BY symbol, exchange, day \
) TO STDOUT WITH CSV HEADER" > "$OUTDIR/daily_coverage.csv"
fi

# -------- 3) Hourly coverage (windowed) --------
if [[ $RUN_3 -eq 1 ]]; then
docker compose exec -T "$SERVICE" psql -U "$PGUSER" -d "$PGDATABASE" -c "COPY ( \
  WITH h AS ( \
    SELECT symbol, exchange, time_bucket('1 hour', ts) AS hour, COUNT(*) AS rows \
    FROM ohlcv_1m ${FILTER_HOURLY} \
    GROUP BY symbol, exchange, hour \
  ) \
  SELECT symbol, exchange, hour, rows, 60 AS expected_rows, \
         ROUND(100.0 * rows / 60.0, 2) AS hour_coverage_pct \
  FROM h \
  ORDER BY symbol, exchange, hour \
) TO STDOUT WITH CSV HEADER" > "$OUTDIR/hourly_coverage.csv"
fi

# -------- 4) Gap summary (heavy) --------
if [[ $RUN_4 -eq 1 ]]; then
docker compose exec -T "$SERVICE" psql -U "$PGUSER" -d "$PGDATABASE" -c "COPY ( \
  WITH s AS ( \
    SELECT symbol, exchange, ts, LEAD(ts) OVER (PARTITION BY symbol, exchange ORDER BY ts) AS next_ts \
    FROM ohlcv_1m ${WHERE_CLAUSE} \
  ) \
  SELECT symbol, exchange, \
         COALESCE(SUM(CASE WHEN next_ts IS NULL THEN 0 \
                           WHEN next_ts > ts + interval '1 minute' \
                             THEN (EXTRACT(EPOCH FROM (next_ts - ts))/60)::bigint - 1 \
                           ELSE 0 END),0) AS missing_minutes, \
         COUNT(*) FILTER (WHERE next_ts > ts + interval '1 minute') AS gap_count \
  FROM s \
  GROUP BY symbol, exchange \
  ORDER BY symbol, exchange \
) TO STDOUT WITH CSV HEADER" > "$OUTDIR/gaps_summary.csv"
fi

# -------- 5) Largest gaps (heavy) --------
if [[ $RUN_5 -eq 1 ]]; then
docker compose exec -T "$SERVICE" psql -U "$PGUSER" -d "$PGDATABASE" -c "COPY ( \
  WITH s AS ( \
    SELECT symbol, exchange, ts, LEAD(ts) OVER (PARTITION BY symbol, exchange ORDER BY ts) AS next_ts \
    FROM ohlcv_1m ${WHERE_CLAUSE} \
  ) \
  SELECT symbol, exchange, ts AS gap_start, next_ts AS gap_end, \
         (EXTRACT(EPOCH FROM (next_ts - ts))/60)::bigint - 1 AS missing_minutes \
  FROM s \
  WHERE next_ts > ts + interval '1 minute' \
  ORDER BY missing_minutes DESC \
  LIMIT ${TOP} \
) TO STDOUT WITH CSV HEADER" > "$OUTDIR/gaps_top${TOP}.csv"
fi

# -------- 6) Expected vs actual (cheap, essential) --------
if [[ $RUN_6 -eq 1 ]]; then
docker compose exec -T "$SERVICE" psql -U "$PGUSER" -d "$PGDATABASE" -c "COPY ( \
  SELECT symbol, exchange, MIN(ts) AS first_ts, MAX(ts) AS last_ts, COUNT(*) AS rows, \
         (EXTRACT(EPOCH FROM (MAX(ts)-MIN(ts)))/60 + 1)::bigint AS expected_rows, \
         ((EXTRACT(EPOCH FROM (MAX(ts)-MIN(ts)))/60 + 1)::bigint - COUNT(*)) AS missing_minutes \
  FROM ohlcv_1m ${WHERE_CLAUSE} \
  GROUP BY symbol, exchange \
  ORDER BY symbol, exchange \
) TO STDOUT WITH CSV HEADER" > "$OUTDIR/span_expected_vs_actual.csv"
fi

# -------- 7) Duplicates (tiny) --------
if [[ $RUN_7 -eq 1 ]]; then
docker compose exec -T "$SERVICE" psql -U "$PGUSER" -d "$PGDATABASE" -c "COPY ( \
  SELECT symbol, exchange, ts, COUNT(*) AS dup_count \
  FROM ohlcv_1m ${WHERE_CLAUSE} \
  GROUP BY symbol, exchange, ts \
  HAVING COUNT(*) > 1 \
) TO STDOUT WITH CSV HEADER" > "$OUTDIR/duplicates.csv"
fi

# -------- 8) Future timestamps (tiny) --------
if [[ $RUN_8 -eq 1 ]]; then
docker compose exec -T "$SERVICE" psql -U "$PGUSER" -d "$PGDATABASE" -c "COPY ( \
  SELECT symbol, exchange, COUNT(*) AS future_rows \
  FROM ohlcv_1m ${WHERE_CLAUSE} \
  WHERE ts > now() \
  GROUP BY symbol, exchange \
) TO STDOUT WITH CSV HEADER" > "$OUTDIR/future_rows.csv"
fi

# -------- 9) Daily coverage IN SPAN (respects listing date) --------
if [[ $RUN_9 -eq 1 ]]; then
docker compose exec -T "$SERVICE" psql -U "$PGUSER" -d "$PGDATABASE" -c "COPY ( \
  WITH edges AS ( \
    SELECT symbol, exchange, MIN(CASE WHEN GREATEST(open,high,low,close) > 0 THEN ts END) AS first_nonzero_ts, \
           MAX(ts) AS last_ts \
    FROM ohlcv_1m ${WHERE_CLAUSE} \
    GROUP BY symbol, exchange \
  ), days AS ( \
    SELECT e.symbol, e.exchange, \
           generate_series(date_trunc('day', e.first_nonzero_ts)::date, \
                           date_trunc('day', e.last_ts)::date, interval '1 day')::date AS day \
    FROM edges e WHERE e.first_nonzero_ts IS NOT NULL \
  ), counts AS ( \
    SELECT symbol, exchange, time_bucket('1 day', ts)::date AS day, COUNT(*) AS rows \
    FROM ohlcv_1m ${WHERE_CLAUSE} \
    GROUP BY symbol, exchange, day \
  ) \
  SELECT d.symbol, d.exchange, d.day, COALESCE(c.rows, 0) AS rows, 1440 AS expected_rows, \
         ROUND(100.0 * COALESCE(c.rows,0) / 1440.0, 2) AS day_coverage_pct \
  FROM days d LEFT JOIN counts c USING (symbol, exchange, day) \
  ORDER BY d.symbol, d.exchange, d.day \
) TO STDOUT WITH CSV HEADER" > "$OUTDIR/daily_coverage_in_span.csv"
fi

# -------- 10) Daily coverage over calendar window --------
if [[ $RUN_10 -eq 1 && -n "${WINDOW_DAYS}" ]]; then
docker compose exec -T "$SERVICE" psql -U "$PGUSER" -d "$PGDATABASE" -c "COPY ( \
  WITH edges AS ( \
    SELECT symbol, exchange, MIN(CASE WHEN GREATEST(open,high,low,close) > 0 THEN ts END) AS first_nonzero_ts, \
           MAX(ts) AS last_ts \
    FROM ohlcv_1m ${WHERE_CLAUSE} \
    GROUP BY symbol, exchange \
  ), window AS ( \
    SELECT (now() - interval '${WINDOW_DAYS} days')::date AS start_day, now()::date AS end_day \
  ), days AS ( \
    SELECT generate_series((SELECT start_day FROM window),(SELECT end_day FROM window), interval '1 day')::date AS day \
  ), universe AS ( \
    SELECT DISTINCT symbol, exchange FROM ohlcv_1m ${WHERE_CLAUSE} \
  ), grid AS ( \
    SELECT u.symbol, u.exchange, d.day FROM universe u CROSS JOIN days d \
    JOIN edges e ON e.symbol=u.symbol AND e.exchange=u.exchange \
    WHERE d.day BETWEEN date_trunc('day', e.first_nonzero_ts)::date AND date_trunc('day', e.last_ts)::date \
  ), counts AS ( \
    SELECT symbol, exchange, time_bucket('1 day', ts)::date AS day, COUNT(*) AS rows \
    FROM ohlcv_1m ${WHERE_CLAUSE} \
    GROUP BY symbol, exchange, day \
  ) \
  SELECT g.symbol, g.exchange, g.day, COALESCE(c.rows, 0) AS rows, 1440 AS expected_rows, \
         ROUND(100.0 * COALESCE(c.rows,0) / 1440.0, 2) AS day_coverage_pct \
  FROM grid g LEFT JOIN counts c USING (symbol, exchange, day) \
  ORDER BY g.symbol, g.exchange, g.day \
) TO STDOUT WITH CSV HEADER" > "$OUTDIR/daily_coverage_window.csv"
fi

# -------- 11) Monthly OHLCV + coverage (cheap) --------
if [[ $RUN_11 -eq 1 ]]; then
docker compose exec -T "$SERVICE" psql -U "$PGUSER" -d "$PGDATABASE" -c "COPY ( \
WITH monthly AS ( \
  SELECT time_bucket('1 month', ts) AS month, symbol, exchange, \
         first(open, ts) AS open, max(high) AS high, min(low) AS low, last(close, ts) AS close, \
         sum(volume) AS volume, count(*) AS rows \
  FROM ohlcv_1m ${WHERE_CLAUSE} \
  GROUP BY 1,2,3 \
) \
SELECT month, symbol, exchange, open, high, low, close, volume, rows, \
       (EXTRACT(day FROM (date_trunc('month', month) + interval '1 month' - date_trunc('month', month)))::int * 1440) AS expected_rows, \
       ROUND(100.0 * rows / NULLIF((EXTRACT(day FROM (date_trunc('month', month) + interval '1 month' - date_trunc('month', month)))::int * 1440), 0), 2) AS coverage_pct \
FROM monthly \
ORDER BY symbol, exchange, month \
) TO STDOUT WITH CSV HEADER" > "$OUTDIR/monthly_ohlcv_coverage.csv"
fi

# -------- 12) Blackout windows (heavy) --------
if [[ $RUN_12 -eq 1 ]]; then
docker compose exec -T "$SERVICE" psql -U "$PGUSER" -d "$PGDATABASE" -c "COPY ( \
  WITH s AS ( \
    SELECT symbol, exchange, ts, LEAD(ts) OVER (PARTITION BY symbol, exchange ORDER BY ts) AS next_ts \
    FROM ohlcv_1m ${WHERE_CLAUSE} \
  ), gaps AS ( \
    SELECT symbol, exchange, ts AS gap_start, next_ts AS gap_end, \
           (EXTRACT(EPOCH FROM (next_ts - ts))/60)::bigint - 1 AS missing_minutes \
    FROM s WHERE next_ts > ts + interval '1 minute' \
  ) \
  SELECT symbol, exchange, gap_start, gap_end, missing_minutes, ROUND(missing_minutes/1440.0, 2) AS missing_days \
  FROM gaps WHERE missing_minutes >= ${BLACKOUT_THRESHOLD_MINUTES} \
  ORDER BY missing_minutes DESC \
) TO STDOUT WITH CSV HEADER" > "$OUTDIR/blackout_windows.csv"
fi

# -------- 13) Adjusted coverage (heavy) --------
if [[ $RUN_13 -eq 1 ]]; then
docker compose exec -T "$SERVICE" psql -U "$PGUSER" -d "$PGDATABASE" -c "COPY ( \
  WITH edges AS ( \
    SELECT symbol, exchange, MIN(ts) AS first_ts, MAX(ts) AS last_ts, \
           (EXTRACT(EPOCH FROM (MAX(ts)-MIN(ts)))/60 + 1)::bigint AS expected_rows_span \
    FROM ohlcv_1m ${WHERE_CLAUSE} GROUP BY symbol, exchange \
  ), counts AS ( \
    SELECT symbol, exchange, COUNT(*) AS rows \
    FROM ohlcv_1m ${WHERE_CLAUSE} GROUP BY symbol, exchange \
  ), gaps AS ( \
    SELECT symbol, exchange, ts AS gap_start, LEAD(ts) OVER (PARTITION BY symbol, exchange ORDER BY ts) AS next_ts \
    FROM ohlcv_1m ${WHERE_CLAUSE} \
  ), blackouts AS ( \
    SELECT symbol, exchange, \
           SUM((EXTRACT(EPOCH FROM (next_ts - gap_start))/60)::bigint - 1) AS blackout_minutes, \
           COUNT(*) AS blackout_periods \
    FROM gaps \
    WHERE next_ts > gap_start + interval '1 minute' \
      AND ((EXTRACT(EPOCH FROM (next_ts - gap_start))/60)::bigint - 1) >= ${BLACKOUT_THRESHOLD_MINUTES} \
    GROUP BY symbol, exchange \
  ) \
  SELECT e.symbol, e.exchange, e.first_ts, e.last_ts, c.rows, e.expected_rows_span AS expected_rows, \
         COALESCE(b.blackout_minutes, 0) AS blackout_minutes, COALESCE(b.blackout_periods, 0) AS blackout_periods, \
         GREATEST(e.expected_rows_span - COALESCE(b.blackout_minutes,0), 0) AS adjusted_expected_rows, \
         (e.expected_rows_span - c.rows) AS original_missing_minutes, \
         GREATEST((e.expected_rows_span - COALESCE(b.blackout_minutes,0)) - c.rows, 0) AS adjusted_missing_minutes, \
         ROUND(100.0 * c.rows / NULLIF(e.expected_rows_span,0), 2) AS coverage_pct, \
         ROUND(100.0 * c.rows / NULLIF(GREATEST(e.expected_rows_span - COALESCE(b.blackout_minutes,0),0), 0), 2) AS adjusted_coverage_pct \
  FROM edges e JOIN counts c USING (symbol, exchange) LEFT JOIN blackouts b USING (symbol, exchange) \
  ORDER BY adjusted_coverage_pct ASC, e.symbol \
) TO STDOUT WITH CSV HEADER" > "$OUTDIR/coverage_blackout_adjusted.csv"
fi

echo "✅ Coverage metrics ($MODE) in $OUTDIR:"
ls -1 "$OUTDIR"
