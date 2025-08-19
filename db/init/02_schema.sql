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