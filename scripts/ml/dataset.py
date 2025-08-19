# scripts/ml/dataset.py
import os
import yaml
import pandas as pd
from sqlalchemy import create_engine
from pandas.tseries.frequencies import to_offset

CONFIG_PATH = os.getenv("ML_CONFIG", "ml/config.yaml")

# -------- Config / DB ----------

def load_config(path=CONFIG_PATH):
    with open(path, "r") as f:
        return yaml.safe_load(f)

def get_engine():
    pguser = os.getenv("PGUSER", "postgres")
    pgpass = os.getenv("PGPASSWORD", "")
    pgdb   = os.getenv("PGDATABASE", "vantam")
    pghost = os.getenv("PGHOST", "localhost")
    pgport = os.getenv("PGPORT", "5432")
    url = f"postgresql+psycopg2://{pguser}:{pgpass}@{pghost}:{pgport}/{pgdb}"
    return create_engine(url)

# -------- Raw 1m fetch (for resample_to = "") ----------

def fetch_from_db(symbols, exchange, start=None, end=None) -> pd.DataFrame:
    conds = []
    if symbols:
        syms = ",".join(f"'{s}'" for s in symbols)
        conds.append(f"symbol IN ({syms})")
    if exchange:
        conds.append(f"exchange = '{exchange}'")
    if start:
        conds.append(f"ts >= '{start}'")
    if end:
        conds.append(f"ts <= '{end}'")
    where = " AND ".join(conds) if conds else "TRUE"

    sql = f"""
        SELECT ts, symbol, exchange, open, high, low, close, volume
          FROM ohlcv_1m
         WHERE {where}
         ORDER BY symbol, exchange, ts
    """

    engine = get_engine()
    try:
        df = pd.read_sql_query(sql, engine, parse_dates=["ts"])
    finally:
        engine.dispose()

    if df.empty:
        return df

    # make tz-aware UTC
    if df["ts"].dt.tz is None:
        df["ts"] = df["ts"].dt.tz_localize("UTC")
    else:
        df["ts"] = df["ts"].dt.tz_convert("UTC")

    return df.sort_values(["symbol","exchange","ts"]).reset_index(drop=True)

# -------- SQL-side resample (preferred for 5T/15T/30T/1H/4H) ----------

_RULE_MAP = {
    "5T":  "5 minutes",
    "15T": "15 minutes",
    "30T": "30 minutes",
    "1H":  "1 hour",
    "4H":  "4 hours",
}

def fetch_resampled_from_db(symbols, exchange, start=None, end=None, rule="15T") -> pd.DataFrame:
    interval = _RULE_MAP.get(rule)
    if not interval:
        raise ValueError(f"Unsupported resample_to='{rule}'. Allowed: {sorted(_RULE_MAP)}")

    syms = ",".join(f"'{s}'" for s in symbols) if symbols else None
    conds = []
    if syms:     conds.append(f"symbol IN ({syms})")
    if exchange: conds.append(f"exchange = '{exchange}'")
    if start:    conds.append(f"ts >= '{start}'")
    if end:      conds.append(f"ts <= '{end}'")
    where = " AND ".join(conds) if conds else "TRUE"

    # time_bucket + array_agg for first/last close; max/min for H/L; sum for volume
    sql = f"""
    WITH b AS (
      SELECT time_bucket('{interval}', ts) AS bucket,
             ts, symbol, exchange, open, high, low, close, volume
      FROM ohlcv_1m
      WHERE {where}
    )
    SELECT bucket AS ts,
           symbol,
           exchange,
           (ARRAY_AGG(open  ORDER BY ts ASC))[1] AS open,
           MAX(high)                              AS high,
           MIN(low)                               AS low,
           (ARRAY_AGG(close ORDER BY ts ASC))[CARDINALITY(ARRAY_AGG(close ORDER BY ts ASC))] AS close,
           SUM(volume)                            AS volume
    FROM b
    GROUP BY bucket, symbol, exchange
    ORDER BY symbol, exchange, bucket;
    """

    engine = get_engine()
    try:
        df = pd.read_sql_query(sql, engine, parse_dates=["ts"])
    finally:
        engine.dispose()

    if df.empty:
        return df

    if df["ts"].dt.tz is None:
        df["ts"] = df["ts"].dt.tz_localize("UTC")
    else:
        df["ts"] = df["ts"].dt.tz_convert("UTC")

    return df.sort_values(["symbol","exchange","ts"]).reset_index(drop=True)

# -------- Pandas resample helper (kept for completeness) ----------

def _resample_one_group(g: pd.DataFrame, rule: str) -> pd.DataFrame:
    g = g.set_index("ts").sort_index()
    out = g.resample(rule).agg(
        open=("open", "first"),
        high=("high", "max"),
        low=("low", "min"),
        close=("close", "last"),
        volume=("volume", "sum"),
    ).dropna()
    out = out.reset_index()
    out["symbol"] = g["symbol"].iloc[0]
    out["exchange"] = g["exchange"].iloc[0]
    return out[["ts","symbol","exchange","open","high","low","close","volume"]]

def maybe_resample(df: pd.DataFrame, rule: str | None) -> pd.DataFrame:
    rule = (rule or "").strip()
    if not rule:
        return df.sort_values(["symbol","exchange","ts"]).reset_index(drop=True)
    grouped = (
        df.groupby(["symbol","exchange"], group_keys=False)
          .apply(lambda g: _resample_one_group(g, rule))
    )
    return grouped.reset_index(drop=True)

# -------- Incremental helpers ----------

def _safety_margin(rule: str | None) -> pd.Timedelta:
    """Look back slightly to avoid boundary artifacts."""
    if not rule or not rule.strip():
        return pd.Timedelta(minutes=2)
    try:
        off = to_offset(rule)
        # two buckets worth of lookback
        return pd.Timedelta(off.delta) * 2 if hasattr(off, "delta") else pd.Timedelta(minutes=2)
    except Exception:
        return pd.Timedelta(minutes=2)

def _read_existing(out_path: str) -> pd.DataFrame:
    if not os.path.exists(out_path):
        return pd.DataFrame(columns=["ts","symbol","exchange","open","high","low","close","volume"])
    df = pd.read_parquet(out_path)
    if pd.api.types.is_datetime64_any_dtype(df["ts"]):
        if getattr(df["ts"].dt, "tz", None) is None:
            df["ts"] = df["ts"].dt.tz_localize("UTC")
        else:
            df["ts"] = df["ts"].dt.tz_convert("UTC")
    return df

def _max_ts_per_group(df: pd.DataFrame):
    if df.empty:
        return {}
    g = df.groupby(["symbol","exchange"])["ts"].max()
    return {k: v for k, v in g.items()}

# -------- Main ----------

def main():
    cfg = load_config()["dataset"]

    # Read config first
    symbols     = cfg.get("symbols") or []
    exchange    = cfg.get("exchange")
    start_cfg   = cfg.get("start")
    end         = cfg.get("end")
    resample_to = (cfg.get("resample_to") or "").strip()  # "" means raw 1m
    out_path    = cfg.get("out_parquet", "analysis/ml/data/dataset.parquet")
    mode        = (os.getenv("MODE") or cfg.get("mode") or "full").lower()

    # Normalize output path & ensure dir
    out_path = os.path.abspath(out_path)
    print("Writing to:", out_path)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    if mode == "incremental":
        # Read existing
        existing = _read_existing(out_path)
        last_ts = _max_ts_per_group(existing)
        margin = _safety_margin(resample_to)
        start = start_cfg
        if last_ts:
            min_last = min(last_ts.values())
            start = (min_last - margin).isoformat()

        # Fetch fresh slice using SQL-side resampling if requested
        if resample_to:
            fresh = fetch_resampled_from_db(symbols, exchange, start=start, end=end, rule=resample_to)
        else:
            fresh = fetch_from_db(symbols, exchange, start=start, end=end)

        if fresh.empty and not existing.empty:
            print("ℹ️ No new rows in DB; keeping existing dataset.")
            existing.to_parquet(out_path, index=False)
            print(f"✅ Saved dataset with {len(existing)} rows to {out_path}")
            return

        # Merge, de-dup, sort
        combined = pd.concat([existing, fresh], ignore_index=True)
        combined = (combined
            .drop_duplicates(subset=["symbol","exchange","ts"])
            .sort_values(["symbol","exchange","ts"])
            .reset_index(drop=True)
        )
        combined.to_parquet(out_path, index=False)
        print(combined.groupby(["symbol","exchange"]).size().reset_index(name="rows").to_string(index=False))
        print(f"✅ Saved dataset with {len(combined)} rows to {out_path}")
        return

    # --- full rebuild ---
    if resample_to:
        df = fetch_resampled_from_db(symbols, exchange, start=start_cfg, end=end, rule=resample_to)
    else:
        df = fetch_from_db(symbols, exchange, start=start_cfg, end=end)

    if df.empty:
        print("⚠️ No rows returned from DB for the given filters.")
        pd.DataFrame(columns=["ts","symbol","exchange","open","high","low","close","volume"]).to_parquet(out_path, index=False)
        print(f"✅ Saved EMPTY dataset to {out_path}")
        return

    # If we fetched raw 1m, we already returned it ordered; if needed, pandas resample:
    if not resample_to:
        df = maybe_resample(df, resample_to)

    df.to_parquet(out_path, index=False)
    print(df.groupby(["symbol","exchange"]).size().reset_index(name="rows").to_string(index=False))
    print(f"✅ Saved dataset with {len(df)} rows to {out_path}")

if __name__ == "__main__":
    main()
