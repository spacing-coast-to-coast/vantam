# scripts/ml/features.py
import pandas as pd
import numpy as np

def add_basic_features(df: pd.DataFrame) -> pd.DataFrame:
    """
    Adds simple, robust features. Assumes df sorted by ["symbol","exchange","ts"].
    Features are computed using *past* information only (no leakage).
    """
    df = df.sort_values(["symbol","exchange","ts"]).copy()

    # 1) Simple past returns
    df["ret_1"] = df.groupby(["symbol","exchange"])["close"].pct_change(1)
    df["ret_2"] = df.groupby(["symbol","exchange"])["close"].pct_change(2)
    df["ret_3"] = df.groupby(["symbol","exchange"])["close"].pct_change(3)

    # 2) Candle structure
    with np.errstate(divide="ignore", invalid="ignore"):
        df["hl_spread"] = (df["high"] - df["low"]) / df["close"].replace(0, np.nan)
        df["oc_spread"] = (df["close"] - df["open"]) / df["open"].replace(0, np.nan)

    # 3) Rolling stats of returns (realized vol & mean)
    def roll_ret(col="ret_1", win=5):
        g = df.groupby(["symbol","exchange"])[col]
        r = g.rolling(win, min_periods=win)
        return r

    for w in (5, 10, 20, 50):
        r = roll_ret("ret_1", w)
        df[f"rvol_{w}"]  = r.std().values
        df[f"rmean_{w}"] = r.mean().values

    # 4) Price z-scores vs rolling mean
    for w in (10, 20, 50):
        g = df.groupby(["symbol","exchange"])["close"]
        r = g.rolling(w, min_periods=w)
        mu = r.mean().values
        sd = r.std().replace(0, np.nan).values
        df[f"zclose_{w}"] = (df["close"] - mu) / sd

    return df

FEATURE_COLUMNS = [
    "ret_1","ret_2","ret_3",
    "hl_spread","oc_spread",
    "rvol_5","rvol_10","rvol_20","rvol_50",
    "rmean_5","rmean_10","rmean_20","rmean_50",
    "zclose_10","zclose_20","zclose_50",
]
