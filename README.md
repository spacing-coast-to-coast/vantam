# VANTAM

## Setup

### 1. Environment

Create a `.env` file at the project root with your Postgres and exchange credentials:

```bash
PGUSER=postgres
PGPASSWORD=yourpassword
PGDATABASE=vantam

# Optional if you use private endpoints/keys
CCXT_API_KEY=
CCXT_SECRET=
CCXT_EXCHANGE=
```

### 2. Start TimescaleDB

```bash
make up
```

This starts a TimescaleDB container (with data persisted via Docker volumes).

Bring everything down (stops all containers, clears networks):

```bash
make down
```

For a quick teardown/reset (alias for `down`):

```bash
make clean
```

---

## Ingest

### Ingest OHLCV data from CCXT into TimescaleDB

```bash
make ingest
```

This uses:

* `VANTAM_MAX_CONCURRENT_REQUESTS` → how many CCXT API calls in parallel (default 2)
* `VANTAM_MAX_POOL_CONNS` → DB pool connections (default 4)

Data is upserted into the `candles` table by `(ts, symbol, exchange)`.

---

## Metrics

Metrics scripts live in `scripts/metrics/` and write results under `analysis/metrics/`.

### Ingest health

```bash
make ingest-metrics
```

* Checks ingest lag and freshness
* Exports CSV/plots under `analysis/metrics/ingest`

### Storage usage

```bash
make storage-metrics
```

* Reports hypertable chunk sizes, indexes, and storage footprint
* Outputs to `analysis/metrics/storage`

### Coverage analysis

Coverage = completeness of OHLCV candles by minute.

Modes:

```bash
make coverage-fast   # quick sample-level coverage check
make coverage-core   # balanced speed vs detail
make coverage-deep   # full blackout detection, window analysis
```

All results are written to `analysis/metrics/coverage`.

Options (override on CLI):

* `DAYS=ALL` → lookback horizon (`ALL` or integer days)
* `HOURS_DAYS=7` → rolling coverage window in days (default 7)
* `TOP=50` → top N gap intervals to export
* `WHERE_CLAUSE="WHERE symbol IN ('BTC/USDT')" ` → filter subset of markets
* `BLACKOUT_THRESHOLD_MINUTES=1440` → what counts as a “blackout” (default: 1 day gap)

### Run everything at once

```bash
make all-metrics
```

Runs:

* `ingest-metrics`
* `storage-metrics`
* `coverage-deep`

---

## ML (coming later)


