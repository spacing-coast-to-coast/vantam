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

* `VANTAM_MAX_CONCURRENT_REQUESTS` → max parallel CCXT API calls (default 2)
* `VANTAM_MAX_POOL_CONNS` → Postgres pool connections (default 4)

Data is upserted into the `candles` hypertable by `(ts, symbol, exchange)`.

---

## Continuous Aggregates (CAGGs)

Timescale continuous aggregates provide pre-rolled OHLCV at hourly, daily, and monthly resolutions.

### Create or re-create CAGGs

```bash
make db-caggs
```

Runs `/docker-entrypoint-initdb.d/03_caggs.sql`.

### Manual full refresh

```bash
make db-refresh
```

Forces a full backfill of all CAGGs. Heavy operation.

### Refresh recent data only (fast)

```bash
make db-refresh-recent
```

Refreshes only the recent tail:

* 1h → last 2 days
* 1d → last 30 days
* 1mo → last 13 months

### Ingest + Refresh shortcut

```bash
make ingest-refresh
```

Runs `make ingest` followed by a fast tail refresh.

### Compression

```bash
make db-compress
```

Manually compresses old `ohlcv_1m` chunks (older than 90 days).
Note: you can also enable automatic compression policies.

### Check installed policies/jobs

```bash
make db-policies-check
```

Lists:

* Continuous aggregates and whether they are materialized-only
* Any background jobs (refresh policies, compression policies)

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

Machine learning pipelines and backtests will live under `analysis/ml/`.
