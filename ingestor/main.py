import os, asyncio, asyncpg, yaml, math
from datetime import datetime, timezone
import ccxt.async_support as ccxt

UPSERT_SQL = """
INSERT INTO {table} (ts, symbol, exchange, open, high, low, close, volume)
VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
ON CONFLICT (ts, symbol, exchange) DO UPDATE
SET open=EXCLUDED.open, high=EXCLUDED.high, low=EXCLUDED.low,
    close=EXCLUDED.close, volume=EXCLUDED.volume;
"""
LAST_TS_SQL = "SELECT MAX(ts) AS last_ts FROM {table} WHERE symbol=$1 AND exchange=$2;"

# Limit concurrent outbound exchange requests to avoid rate-limit thrashing
REQ_SEM = asyncio.Semaphore(int(os.getenv("VANTAM_MAX_CONCURRENT_REQUESTS", "2")))

# Progress config
PROGRESS_ENABLED = os.getenv("VANTAM_PROGRESS", "1") != "0"
PROGRESS_EVERY   = int(os.getenv("VANTAM_PROGRESS_EVERY", "10"))   # print every N batches
PROGRESS_TARGET  = os.getenv("VANTAM_PROGRESS_TARGET_MS")          # optional override target in ms

def iso_to_ms(iso: str) -> int:
    return int(datetime.fromisoformat(iso.replace("Z","+00:00")).timestamp() * 1000)

def ms_to_dt(ms: int) -> datetime:
    return datetime.fromtimestamp(ms/1000, tz=timezone.utc)

def now_ms() -> int:
    return int(datetime.now(tz=timezone.utc).timestamp() * 1000)

def fmt_int(n: int) -> str:
    return f"{n:,}"

def fmt_eta(seconds: float) -> str:
    if not math.isfinite(seconds) or seconds < 0: return "?"
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    if h: return f"~{h}h {m}m"
    if m: return f"~{m}m"
    return f"~{s}s"

async def fetch_and_upsert(pool, ex, cfg, symbol):
    table   = cfg["postgres"]["table"]
    ex_name = cfg["exchange"]
    tf      = cfg["timeframe"]
    limit   = cfg["batch_candles"]
    rate_ms = cfg.get("rate_limit_ms") or ex.rateLimit

    async with pool.acquire() as conn:
        row = await conn.fetchrow(LAST_TS_SQL.format(table=table), symbol, ex_name)
        last_ts = row["last_ts"] if row and row["last_ts"] else None
        # establish starting point
        start_ms = (int(last_ts.timestamp()*1000)+60_000) if last_ts else iso_to_ms(cfg["backfill"]["start"])
        # target is "now" by default; you can override with env if you want to stop earlier
        target_ms = int(PROGRESS_TARGET) if PROGRESS_TARGET else now_ms()
        if target_ms <= start_ms:
            if PROGRESS_ENABLED:
                print(f"[{symbol} {ex_name}] up-to-date (start >= target)")
            return

        batches = 0
        written = 0
        since_ms = start_ms

        while True:
            try:
                # Bound concurrent HTTP calls
                async with REQ_SEM:
                    ohlcv = await ex.fetch_ohlcv(symbol, timeframe=tf, since=since_ms, limit=limit)
            except ccxt.BaseError as e:
                if PROGRESS_ENABLED:
                    print(f"[{symbol} {ex_name}] fetch error: {e!s} (retrying after rate sleep)")
                await asyncio.sleep((rate_ms/1000)+1)
                continue

            if not ohlcv:
                # nothing returned (either finished or exchange has no more)
                if PROGRESS_ENABLED and batches == 0:
                    print(f"[{symbol} {ex_name}] no new candles from exchange")
                break

            rows = []
            for ts_ms, o, h, l, c, v in ohlcv:
                rows.append((ms_to_dt(ts_ms), symbol, ex_name, float(o), float(h), float(l), float(c), float(v)))
                since_ms = ts_ms + 60_000

            async with conn.transaction():
                await conn.executemany(UPSERT_SQL.format(table=table), rows)
            written += len(rows)
            batches += 1

            # progress log (every N batches)
            if PROGRESS_ENABLED and (batches % PROGRESS_EVERY == 0):
                total_min = max(1, (target_ms - start_ms) // 60_000)
                done_min  = max(0, (min(since_ms, target_ms) - start_ms) // 60_000)
                pct = 100.0 * done_min / total_min
                rem_min = max(0, total_min - done_min)
                # naive ETA: remaining minutes / (avg minutes per batch)
                avg_per_batch = max(1, (done_min or 1) // batches)
                eta_sec = (rem_min / avg_per_batch) * ((rate_ms/1000.0) + 0.1)  # +0.1s fudge
                print(f"[{symbol} {ex_name}] {pct:5.1f}% {fmt_int(done_min)}/{fmt_int(total_min)} min"
                      f" | rem {fmt_int(rem_min)} | ETA {fmt_eta(eta_sec)} | batches {fmt_int(batches)}")

            await asyncio.sleep(rate_ms/1000)
            # if the exchange returned < limit, we've probably reached the end of available history for 'since'
            if len(ohlcv) < limit or since_ms >= target_ms:
                # final progress line
                if PROGRESS_ENABLED:
                    total_min = max(1, (target_ms - start_ms) // 60_000)
                    done_min  = max(0, (min(since_ms, target_ms) - start_ms) // 60_000)
                    pct = 100.0 * done_min / total_min
                    print(f"[{symbol} {ex_name}] done {pct:5.1f}%"
                          f" | wrote {fmt_int(written)} rows in {fmt_int(batches)} batches")
                break

async def main():
    cfg_path = os.getenv("VANTAM_CONFIG", "/app/config.yaml")
    with open(cfg_path, "r") as f:
        cfg = yaml.safe_load(f)

    dsn = (
        f"postgresql://{os.getenv('PGUSER')}:{os.getenv('PGPASSWORD')}"
        f"@{os.getenv('PGHOST')}:{os.getenv('PGPORT')}/{os.getenv('PGDATABASE')}"
    )
    ex = getattr(ccxt, cfg["exchange"])({"enableRateLimit": True})

    try:
        await ex.load_markets()
        max_pool_conns = int(os.getenv("VANTAM_MAX_POOL_CONNS", "8"))
        pool_size = min(max_pool_conns, max(1, len(cfg["symbols"])))
        async with asyncpg.create_pool(dsn, min_size=1, max_size=pool_size) as pool:
            await asyncio.gather(*(fetch_and_upsert(pool, ex, cfg, sym) for sym in cfg["symbols"]))
    finally:
        await ex.close()

if __name__ == "__main__":
    asyncio.run(main())
