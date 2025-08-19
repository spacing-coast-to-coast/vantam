# scripts/ml/train.py
import os, json, time, yaml
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from sklearn.metrics import classification_report, confusion_matrix
from joblib import dump

from features import add_basic_features, FEATURE_COLUMNS
from labels import add_labels
from algorithms import REGISTRY  # <- models are in scripts/ml/algorithms

# ---------- plotting helpers ----------

def save_confusion_matrix_png(cm, labels, out_path, title="Confusion Matrix"):
    fig = plt.figure(figsize=(5, 4), dpi=150)
    ax = fig.add_subplot(111)
    im = ax.imshow(cm, aspect="auto")
    ax.set_title(title)
    ax.set_xlabel("Predicted")
    ax.set_ylabel("True")
    ax.set_xticks(range(len(labels)))
    ax.set_yticks(range(len(labels)))
    ax.set_xticklabels(labels)
    ax.set_yticklabels(labels)
    for i in range(len(labels)):
        for j in range(len(labels)):
            ax.text(j, i, cm[i][j], ha="center", va="center")
    fig.colorbar(im, ax=ax, fraction=0.046, pad=0.04)
    fig.tight_layout()
    fig.savefig(out_path, bbox_inches="tight")
    plt.close(fig)

def extract_feature_importance(model_clf, feature_names):
    """
    Returns (names, importances) if available; else None.
    - Tree models: 'feature_importances_'
    - LogisticRegression: mean |coef_| per feature across classes
    """
    if hasattr(model_clf, "feature_importances_"):
        imp = np.asarray(model_clf.feature_importances_, dtype=float)
        return feature_names, imp
    if hasattr(model_clf, "coef_"):
        coefs = np.asarray(model_clf.coef_, dtype=float)  # (n_classes, n_features)
        imp = np.mean(np.abs(coefs), axis=0)
        return feature_names, imp
    return None

def save_feature_importance(names, imps, csv_path, png_path, top_k=25, title="Feature Importance"):
    df_imp = pd.DataFrame({"feature": names, "importance": imps}).sort_values("importance", ascending=False)
    df_imp.to_csv(csv_path, index=False)

    top = df_imp.head(top_k)
    fig = plt.figure(figsize=(7, max(3, 0.25*len(top))), dpi=150)
    ax = fig.add_subplot(111)
    ax.barh(top["feature"][::-1], top["importance"][::-1])
    ax.set_title(title)
    ax.set_xlabel("Importance")
    fig.tight_layout()
    fig.savefig(png_path, bbox_inches="tight")
    plt.close(fig)

# ---------- config ----------

def load_cfg(path="ml/config.yaml"):
    with open(path, "r") as f:
        return yaml.safe_load(f)

# ---------- training ----------

def main():
    cfg = load_cfg()
    ds = cfg["dataset"]
    mc = cfg.get("model", {})

    parquet = ds.get("out_parquet", "analysis/ml/data/dataset.parquet")
    horizon_bars = int(ds.get("horizon_min", 4))
    up_thr = float(ds.get("up_thr", 0.01))
    dn_thr = float(ds.get("dn_thr", -0.01))

    model_name = (mc.get("name") or "xgboost").lower()
    if model_name not in REGISTRY:
        raise ValueError(f"Unknown model '{model_name}'. Options: {list(REGISTRY)}")

    params_by_model = mc.get("options") or {}
    params = params_by_model.get(model_name) or {}

    class_weights = bool(mc.get("class_weights", True))
    random_state = int(mc.get("random_state", 42))
    test_days = int(mc.get("test_days", 30))

    out_dir = "analysis/ml"
    models_dir = os.path.join(out_dir, "models", model_name)
    reports_dir = os.path.join(out_dir, "reports", model_name)
    os.makedirs(models_dir, exist_ok=True)
    os.makedirs(reports_dir, exist_ok=True)

    # Load dataset
    df = pd.read_parquet(parquet)
    df["ts"] = pd.to_datetime(df["ts"], utc=True)
    df = df.sort_values(["symbol","exchange","ts"])

    # Features + labels
    df = add_basic_features(df)
    df = add_labels(df, horizon_bars=horizon_bars, up_thr=up_thr, dn_thr=dn_thr)

    # Drop rows with NaN
    cols = FEATURE_COLUMNS
    df = df.dropna(subset=cols + ["y"]).reset_index(drop=True)

    # Time-based split
    cutoff = df["ts"].max() - pd.Timedelta(days=test_days)
    train = df[df["ts"] < cutoff].copy()
    test  = df[df["ts"] >= cutoff].copy()
    if train.empty or test.empty:
        raise RuntimeError("Train/Test split is empty. Adjust test_days or ensure dataset span is sufficient.")

    X_train, y_train = train[cols].values, train["y"].values
    X_test,  y_test  = test[cols].values,  test["y"].values

    # Encode labels to 0..K-1 (esp. for XGBoost) but keep reporting in original labels
    classes = sorted(pd.unique(df["y"]))
    class_to_idx = {c: i for i, c in enumerate(classes)}
    idx_to_class = {i: c for c, i in class_to_idx.items()}
    y_train_enc = pd.Series(y_train).map(class_to_idx).astype(int).values
    y_test_enc  = pd.Series(y_test ).map(class_to_idx).astype(int).values

    # Build + fit
    ModelCls = REGISTRY[model_name]
    model = ModelCls(params=params, class_weights=class_weights, random_state=random_state)
    model.fit(X_train, y_train_enc)

    # Evaluate
    y_pred_idx = model.predict(X_test)
    try:
        y_proba = model.predict_proba(X_test)
    except Exception:
        y_proba = None

    y_pred = pd.Series(y_pred_idx).map(idx_to_class).values
    report = classification_report(y_test, y_pred, output_dict=True, zero_division=0)
    cm_arr = confusion_matrix(y_test, y_pred, labels=classes)
    cm = cm_arr.tolist()

    # Timestamp for artifacts
    ts_tag = time.strftime("%Y%m%d_%H%M%S")

    # Save CM PNG
    cm_png = os.path.join(reports_dir, f"cm_{ts_tag}.png")
    save_confusion_matrix_png(cm, labels=classes, out_path=cm_png, title=f"CM: {model_name}")

    # Save model
    model_path = os.path.join(models_dir, f"model_{ts_tag}.joblib")
    dump(getattr(model, "clf", model), model_path)

    # Save metrics
    metrics = {
        "model": model_name,
        "params": params,
        "class_weights": class_weights,
        "random_state": random_state,
        "test_days": test_days,
        "cutoff": cutoff.isoformat(),
        "report": report,
        "confusion_matrix": cm,
        "n_train": int(len(train)),
        "n_test": int(len(test)),
        "features": cols,
        "horizon_bars": horizon_bars,
        "up_thr": up_thr,
        "dn_thr": dn_thr,
    }
    metrics_path = os.path.join(reports_dir, f"metrics_{ts_tag}.json")
    with open(metrics_path, "w") as f:
        json.dump(metrics, f, indent=2)

    # Save predictions
    preds = test[["ts","symbol","exchange"]].copy()
    preds["y_true"] = y_test
    preds["y_pred"] = y_pred
    if y_proba is not None:
        proba_df = pd.DataFrame(y_proba)
        proba_df.columns = [f"p_{idx_to_class[i]}" for i in range(proba_df.shape[1])]
        preds = pd.concat([preds.reset_index(drop=True), proba_df.reset_index(drop=True)], axis=1)
    preds_path = os.path.join(reports_dir, f"preds_{ts_tag}.parquet")
    preds.to_parquet(preds_path, index=False)

    # Feature importance (if available)
    fi = extract_feature_importance(getattr(model, "clf", model), FEATURE_COLUMNS)
    if fi is not None:
        names, imps = fi
        fi_csv = os.path.join(reports_dir, f"feat_importance_{ts_tag}.csv")
        fi_png = os.path.join(reports_dir, f"feat_importance_{ts_tag}.png")
        save_feature_importance(names, imps, fi_csv, fi_png, top_k=25, title=f"Feature Importance: {model_name}")
        print(f"✅ Saved feature importance → {fi_csv}, {fi_png}")

    print(f"✅ Saved model → {model_path}")
    print(f"✅ Saved metrics → {metrics_path}")
    print(f"✅ Saved predictions → {preds_path}")
    print(f"✅ Saved confusion matrix → {cm_png}")

if __name__ == "__main__":
    main()
