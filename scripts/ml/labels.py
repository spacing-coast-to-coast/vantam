# scripts/ml/labels.py
import pandas as pd

def add_labels(df: pd.DataFrame, horizon_bars: int, up_thr: float, dn_thr: float) -> pd.DataFrame:
    """
    Forward-return labels from future close / current close - 1.
    horizon_bars is counted in *post-resample* bars (e.g., 4 bars at 15T = 1 hour).
    Label scheme:
      y = +1 if ret_fwd >= up_thr
      y = -1 if ret_fwd <= dn_thr
      y =  0 otherwise
    Rows without full future window are dropped.
    """
    df = df.sort_values(["symbol","exchange","ts"]).copy()
    grp = df.groupby(["symbol","exchange"], sort=False)
    future_close = grp["close"].shift(-horizon_bars)
    df["ret_fwd"] = (future_close / df["close"]) - 1.0

    df["y"] = 0
    df.loc[df["ret_fwd"] >= up_thr, "y"] = 1
    df.loc[df["ret_fwd"] <= dn_thr, "y"] = -1

    # Drop rows that don't have the future horizon
    df = df.dropna(subset=["ret_fwd"])
    return df
