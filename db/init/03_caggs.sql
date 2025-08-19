-- ===== Reset & Rebuild CAGGs safely =====

-- 0) Drop thin view if it exists
DROP VIEW IF EXISTS v_ohlcv_1mo;

-- 1) Remove policies if they exist (ignore errors if not present)
DO $$
BEGIN
  PERFORM remove_continuous_aggregate_policy('ohlcv_1h');
EXCEPTION WHEN OTHERS THEN
  NULL;
END$$;

DO $$
BEGIN
  PERFORM remove_continuous_aggregate_policy('ohlcv_1d');
EXCEPTION WHEN OTHERS THEN
  NULL;
END$$;

DO $$
BEGIN
  PERFORM remove_continuous_aggregate_policy('ohlcv_1mo');
EXCEPTION WHEN OTHERS THEN
  NULL;
END$$;

DO $$
BEGIN
  PERFORM remove_compression_policy('ohlcv_1m');
EXCEPTION WHEN OTHERS THEN
  NULL;
END$$;

-- 2) Drop continuous aggregates (and their chunks)
DROP MATERIALIZED VIEW IF EXISTS ohlcv_1h  CASCADE;
DROP MATERIALIZED VIEW IF EXISTS ohlcv_1d  CASCADE;
DROP MATERIALIZED VIEW IF EXISTS ohlcv_1mo CASCADE;

-- 3) (Re)enable compression config on base minutes & add policy
ALTER TABLE ohlcv_1m
  SET (timescaledb.compress = true,
       timescaledb.compress_segmentby = 'symbol,exchange');

-- Use if_not_exists => true to avoid errors if a policy is already there
SELECT add_compression_policy('ohlcv_1m', INTERVAL '14 days', if_not_exists => true);

-- 4) Recreate CAGGs (WITH NO DATA goes at the end)

-- 4a) Hourly
CREATE MATERIALIZED VIEW ohlcv_1h
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 hour', ts) AS bucket,
  symbol, exchange,
  (ARRAY_AGG(open  ORDER BY ts ASC))[1]  AS open,
  MAX(high)                              AS high,
  MIN(low)                               AS low,
  (ARRAY_AGG(close ORDER BY ts DESC))[1] AS close,
  SUM(volume)                            AS volume,
  COUNT(*)                               AS rows
FROM ohlcv_1m
GROUP BY 1,2,3
WITH NO DATA;

CREATE INDEX IF NOT EXISTS ohlcv_1h_sym_ex_bucket_idx
  ON ohlcv_1h (symbol, exchange, bucket DESC);

-- 4b) Daily
CREATE MATERIALIZED VIEW ohlcv_1d
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 day', ts) AS day,
  symbol, exchange,
  (ARRAY_AGG(open  ORDER BY ts ASC))[1]  AS open,
  MAX(high)                              AS high,
  MIN(low)                               AS low,
  (ARRAY_AGG(close ORDER BY ts DESC))[1] AS close,
  SUM(volume)                            AS volume,
  COUNT(*)                               AS rows,
  1440                                   AS expected_rows,
  ROUND(100.0 * COUNT(*) / 1440.0, 2)    AS day_coverage_pct
FROM ohlcv_1m
GROUP BY 1,2,3
WITH NO DATA;

CREATE INDEX IF NOT EXISTS ohlcv_1d_sym_ex_day_idx
  ON ohlcv_1d (symbol, exchange, day DESC);

-- 4c) Monthly (keep “coverage math” out of the CAGG to avoid immutability warnings)
CREATE MATERIALIZED VIEW ohlcv_1mo
WITH (timescaledb.continuous) AS
SELECT
  time_bucket('1 month', ts) AS month,
  symbol, exchange,
  (ARRAY_AGG(open  ORDER BY ts ASC))[1]  AS open,
  MAX(high)                              AS high,
  MIN(low)                               AS low,
  (ARRAY_AGG(close ORDER BY ts DESC))[1] AS close,
  SUM(volume)                            AS volume,
  COUNT(*)                               AS rows
FROM ohlcv_1m
GROUP BY 1,2,3
WITH NO DATA;

CREATE INDEX IF NOT EXISTS ohlcv_1mo_sym_ex_month_idx
  ON ohlcv_1mo (symbol, exchange, month DESC);

-- 5) Thin view on top of monthly for expected_rows/coverage (pure SELECT)
CREATE OR REPLACE VIEW v_ohlcv_1mo AS
SELECT
  month, symbol, exchange, open, high, low, close, volume, rows,
  (EXTRACT(day FROM (date_trunc('month', month) + interval '1 month'
                     - date_trunc('month', month)))::int * 1440) AS expected_rows,
  ROUND(
    100.0 * rows /
    NULLIF((EXTRACT(day FROM (date_trunc('month', month) + interval '1 month'
                              - date_trunc('month', month)))::int * 1440), 0),
    2
  ) AS coverage_pct
FROM ohlcv_1mo;

-- 6) Re-add refresh policies (use if_not_exists => true if your version supports it)
SELECT add_continuous_aggregate_policy(
  'ohlcv_1h',
  start_offset => INTERVAL '2 days',
  end_offset   => INTERVAL '5 minutes',
  schedule_interval => INTERVAL '15 minutes'
);

SELECT add_continuous_aggregate_policy(
  'ohlcv_1d',
  start_offset => INTERVAL '30 days',
  end_offset   => INTERVAL '5 minutes',
  schedule_interval => INTERVAL '30 minutes'
);

SELECT add_continuous_aggregate_policy(
  'ohlcv_1mo',
  start_offset => INTERVAL '12 months',
  end_offset   => INTERVAL '1 day',
  schedule_interval => INTERVAL '1 hour'
);
