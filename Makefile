# Defaults (override like: make coverage-metrics SERVICE=mydb PGUSER=foo PGDATABASE=bar)
SERVICE ?= timescaledb
PGUSER ?= postgres
PGDATABASE ?= vantam
VANTAM_MAX_CONCURRENT_REQUESTS ?= 2
VANTAM_MAX_POOL_CONNS ?= 4

## Default values for metrics scripts
DAYS ?= ALL                # full history by default
HOURS_DAYS ?= 7            # 7 days by default
TOP ?= 50                  # top 50 gaps by default
WINDOW_DAYS ?=             # empty means skip window export
WHERE_CLAUSE ?=            # e.g. WHERE symbol IN ('BTC/USDT') AND exchange='binanceus'
BLACKOUT_THRESHOLD_MINUTES ?= 1440  # What qualifies as a blackout (1 day)

# ---- ML defaults (override on the CLI) ----
SYMBOLS ?= BTC/USDT,ETH/USDT
EXCHANGE ?= binanceus
START ?= 2019-01-01T00:00:00Z
END ?= 2100-01-01T00:00:00Z
HORIZON_MIN ?= 60
UP_THR ?= 0.001
DN_THR ?= 0.001
DATA_PARQUET ?= analysis/ml/data/dataset.parquet

MODEL_PATH ?= analysis/ml/models/lgbm_cls.pkl
N_SPLITS ?= 5
RANDOM_STATE ?= 42
CLASS_WEIGHTS ?= 1,0.5,1

COST_BPS ?= 10
ALLOW_SHORT ?= 0
REPORT_PATH ?= analysis/ml/reports/backtest_summary.txt

.PHONY: up down clean ingest \
        ingest-metrics storage-metrics coverage-metrics all-metrics \
        coverage-fast coverage-core coverage-deep 

# ------- Make Commands -------

## ---- Start/stop services ----
up:
	@docker compose up -d timescaledb

down:
	@docker compose down

clean: down

## -------- Ingest data --------
ingest:
	@docker compose run --rm \
		-e VANTAM_MAX_CONCURRENT_REQUESTS=$(VANTAM_MAX_CONCURRENT_REQUESTS) \
		-e VANTAM_MAX_POOL_CONNS=$(VANTAM_MAX_POOL_CONNS) \
		ingestor

## ---------- Metrics ----------
ingest-metrics:
	@chmod +x scripts/metrics/ingest_metrics.sh
	@SERVICE=$(SERVICE) PGUSER=$(PGUSER) PGDATABASE=$(PGDATABASE) OUTDIR=analysis/metrics/ingest \
		./scripts/metrics/ingest_metrics.sh

storage-metrics:
	@chmod +x scripts/metrics/storage_metrics.sh
	@SERVICE=$(SERVICE) PGUSER=$(PGUSER) PGDATABASE=$(PGDATABASE) OUTDIR=analysis/metrics/storage \
		./scripts/metrics/storage_metrics.sh

coverage-fast:
	@chmod +x scripts/metrics/coverage_metrics.sh
	@MODE=fast SERVICE=$(SERVICE) PGUSER=$(PGUSER) PGDATABASE=$(PGDATABASE) OUTDIR=analysis/metrics/coverage \
		DAYS=$(DAYS) HOURS_DAYS=$(HOURS_DAYS) TOP=$(TOP) WHERE_CLAUSE="$(WHERE_CLAUSE)" \
		./scripts/metrics/coverage_metrics.sh

coverage-core:
	@chmod +x scripts/metrics/coverage_metrics.sh
	@MODE=core SERVICE=$(SERVICE) PGUSER=$(PGUSER) PGDATABASE=$(PGDATABASE) OUTDIR=analysis/metrics/coverage \
		DAYS=$(DAYS) HOURS_DAYS=$(HOURS_DAYS) TOP=$(TOP) WHERE_CLAUSE="$(WHERE_CLAUSE)" \
		./scripts/metrics/coverage_metrics.sh

coverage-deep:
	@chmod +x scripts/metrics/coverage_metrics.sh
	@MODE=deep SERVICE=$(SERVICE) PGUSER=$(PGUSER) PGDATABASE=$(PGDATABASE) OUTDIR=analysis/metrics/coverage \
		DAYS=$(DAYS) HOURS_DAYS=$(HOURS_DAYS) TOP=$(TOP) WINDOW_DAYS="$(WINDOW_DAYS)" WHERE_CLAUSE="$(WHERE_CLAUSE)" \
		BLACKOUT_THRESHOLD_MINUTES=$(BLACKOUT_THRESHOLD_MINUTES) \
		./scripts/metrics/coverage_metrics.sh

all-metrics: ingest-metrics storage-metrics coverage-deep


## ---------- ML ----------
