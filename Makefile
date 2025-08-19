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



.PHONY: up down clean \
        ingest \
        db-caggs db-refresh db-compress db-policies-check db-refresh-recent ingest-refresh \
        ingest-metrics storage-metrics coverage-metrics coverage-fast coverage-core coverage-deep \
        all-metrics

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

## --- Continuous Aggregates ---
## Create/refresh CAGG objects & policies from SQL file
db-caggs:
	@docker compose exec -T timescaledb psql -U $(PGUSER) -d $(PGDATABASE) -f /docker-entrypoint-initdb.d/03_caggs.sql

## Manually refresh CAGGs over the entire span (big hammer)
db-refresh:
	@docker compose exec -T timescaledb psql -U $(PGUSER) -d $(PGDATABASE) -c "CALL refresh_continuous_aggregate('ohlcv_1h',  NULL, NULL);"
	@docker compose exec -T timescaledb psql -U $(PGUSER) -d $(PGDATABASE) -c "CALL refresh_continuous_aggregate('ohlcv_1d',  NULL, NULL);"
	@docker compose exec -T timescaledb psql -U $(PGUSER) -d $(PGDATABASE) -c "CALL refresh_continuous_aggregate('ohlcv_1mo', NULL, NULL);"

## Compress old chunks (manual kick; you also have a compression policy on ohlcv_1m)
db-compress:
	@docker compose exec -T timescaledb psql -U $(PGUSER) -d $(PGDATABASE) -c \
	"SELECT compress_chunk(i) FROM show_chunks('ohlcv_1m') i WHERE i < now() - interval '90 days';"

## Verify policies/jobs (works across Timescale versions)
db-policies-check:
	@docker compose exec -T timescaledb psql -U $(PGUSER) -d $(PGDATABASE) -c \
	"SELECT view_name, materialized_only FROM timescaledb_information.continuous_aggregates ORDER BY view_name;"
	@docker compose exec -T timescaledb psql -U $(PGUSER) -d $(PGDATABASE) -c \
	"SELECT job_id, proc_name, schedule_interval, hypertable_name \
	   FROM timescaledb_information.jobs \
	  WHERE proc_name IN ('policy_refresh_continuous_aggregate','policy_compression') \
	  ORDER BY proc_name, job_id;"

## Fast tail refresh after an ingest (bounded windows = quick & safe)
db-refresh-recent:
	@echo "Refreshing ohlcv_1h (last 2 days)…"
	@docker compose exec -T timescaledb psql -U $(PGUSER) -d $(PGDATABASE) -c \
	"CALL refresh_continuous_aggregate('ohlcv_1h', now() - interval '2 days', NULL);"
	@echo "Refreshing ohlcv_1d (last 30 days)…"
	@docker compose exec -T timescaledb psql -U $(PGUSER) -d $(PGDATABASE) -c \
	"CALL refresh_continuous_aggregate('ohlcv_1d', now() - interval '30 days', NULL);"
	@echo "Refreshing ohlcv_1mo (last 13 months)…"
	@docker compose exec -T timescaledb psql -U $(PGUSER) -d $(PGDATABASE) -c \
	"CALL refresh_continuous_aggregate('ohlcv_1mo', date_trunc('month', now()) - interval '13 months', NULL);"

## Convenience: run ingest then immediately refresh recent windows
ingest-refresh: ingest db-refresh-recent

## ---------- Metrics ----------
ingest-metrics:
	@chmod +x scripts/metrics/ingest_metrics.sh
	@SERVICE=$(SERVICE) PGUSER=$(PGUSER) PGDATABASE=$(PGDATABASE) OUTDIR=analysis/metrics/ingest \
		./scripts/metrics/ingest_metrics.sh

storage-metrics:
	@chmod +x scripts/metrics/storage_metrics.sh
	@SERVICE=$(SERVICE) PGUSER=$(PGUSER) PGDATABASE=$(PGDATABASE) OUTDIR=analysis/metrics/storage \
		./scripts/metrics/storage_metrics.sh

coverage-metrics:
	@chmod +x scripts/metrics/coverage_metrics.sh
	@SERVICE=$(SERVICE) PGUSER=$(PGUSER) PGDATABASE=$(PGDATABASE) OUTDIR=analysis/metrics/coverage \
		DAYS=$(DAYS) HOURS_DAYS=$(HOURS_DAYS) TOP=$(TOP) \
		WINDOW_DAYS="$(WINDOW_DAYS)" WHERE_CLAUSE="$(WHERE_CLAUSE)" BLACKOUT_THRESHOLD_MINUTES=$(BLACKOUT_THRESHOLD_MINUTES) \
		./scripts/metrics/coverage_metrics.sh

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
