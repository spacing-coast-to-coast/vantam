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

Data is upserted into the `ohlcv_1m` hypertable by `(ts, symbol, exchange)`.

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

### Refresh recent data only (fast)

```bash
make db-refresh-recent
```

### Ingest + Refresh shortcut

```bash
make ingest-refresh
```

### Compression

```bash
make db-compress
```

### Check installed policies/jobs

```bash
make db-policies-check
```

---

## Metrics

Metrics scripts live in `scripts/metrics/` and write results under `analysis/metrics/`.

Examples:

```bash
make ingest-metrics
make storage-metrics
make coverage-core
make all-metrics
```

---

## ML

Machine learning pipelines live under `analysis/ml/`.
The workflow uses a separate `ml` container and Makefile commands.

### Build ML container

```bash
make ml-build
```

### Example config

`ml/config.yaml` controls dataset generation:

```yaml
dataset:
  exchange: binanceus
  symbols:
    - BTC/USDT
    - ETH/USDT
    - ADA/USDT
    - XRP/USDT
  start: '2019-01-01'
  end: null
  resample_to: 15T         # aggregate 1m candles into 15-minute bars
  out_parquet: analysis/ml/data/dataset.parquet
  mode: full               # full | incremental
  horizon_min: 4           # label horizon in minutes
  up_thr: 0.01             # +1% threshold for "up" label
  dn_thr: -0.01            # -1% threshold for "down" label
```

### Generate dataset

Datasets are saved to `analysis/ml/data/`.

* Use mode from `ml/config.yaml`:

```bash
make ml-dataset
```

* Force full rebuild:

```bash
make ml-dataset-full
```

* Force incremental update (append new rows after `make ingest-refresh`):

```bash
make ml-dataset-incremental
```

### End-to-end pipeline

```bash
make ml-pipeline
```

Runs:

1. `make ingest-refresh` → ingests fresh OHLCV + refreshes aggregates
2. `make ml-dataset-incremental` → appends dataset under `analysis/ml/data/dataset.parquet`

---

## Operational Workflow

A typical daily workflow:

1. **Start DB**

   ```bash
   make up
   ```

2. **Ingest fresh data**

   ```bash
   make ingest
   ```

3. **Update aggregates** (auto via policy, or manual refresh)

   ```bash
   make ingest-refresh
   ```

4. **Run ML dataset build**

   ```bash
   make ml-dataset-incremental
   ```

5. **Run metrics**

   ```bash
   make coverage-core
   ```

6. **Tear down**

   ```bash
   make down
   ```

