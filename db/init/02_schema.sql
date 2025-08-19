-- Single hypertable partitioned by symbol (recommended).
CREATE TABLE IF NOT EXISTS ohlcv_1m (
  ts        TIMESTAMPTZ NOT NULL,
  symbol    TEXT        NOT NULL,  -- 'BTC/USDT'
  exchange  TEXT        NOT NULL,  -- 'binanceus'
  open      NUMERIC     NOT NULL,
  high      NUMERIC     NOT NULL,
  low       NUMERIC     NOT NULL,
  close     NUMERIC     NOT NULL,
  volume    NUMERIC     NOT NULL,
  PRIMARY KEY (ts, symbol, exchange)
);

SELECT create_hypertable('ohlcv_1m',
                         'ts',
                         partitioning_column => 'symbol',
                         number_partitions   => 16,
                         if_not_exists       => TRUE);


CREATE INDEX IF NOT EXISTS ohlcv_1m_symbol_ts_idx ON ohlcv_1m (symbol, ts DESC);
CREATE INDEX IF NOT EXISTS ohlcv_1m_exchange_idx  ON ohlcv_1m (exchange);

-- (Optional) continuous aggregate example (comment in later)
-- CREATE MATERIALIZED VIEW ohlcv_5m
-- WITH (timescaledb.continuous) AS
-- SELECT time_bucket('5 minutes', ts) AS bucket,
--        symbol, exchange,
--        first(open, ts)  AS open,
--        max(high)        AS high,
--        min(low)         AS low,
--        last(close, ts)  AS close,
--        sum(volume)      AS volume
-- FROM ohlcv_1m
-- GROUP BY bucket, symbol, exchange;
