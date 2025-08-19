# scripts/ml/algorithms/xgboost.py
class XGBModel:
    """
    xgboost.XGBClassifier; params passed exactly as provided.
    NOTE: You must provide appropriate objective/num_class if needed.
    """
    def __init__(self, params=None, class_weights=False, random_state=42):
        from xgboost import XGBClassifier
        self.clf = XGBClassifier(**(params or {}))

    def fit(self, X, y): self.clf.fit(X, y)
    def predict(self, X): return self.clf.predict(X)
    def predict_proba(self, X):
        return self.clf.predict_proba(X) if hasattr(self.clf, "predict_proba") else None
