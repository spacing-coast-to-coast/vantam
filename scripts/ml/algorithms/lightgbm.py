# scripts/ml/algorithms/lightgbm.py
class LGBMModel:
    """
    lightgbm.LGBMClassifier; params passed exactly as provided.
    """
    def __init__(self, params=None, class_weights=False, random_state=42):
        from lightgbm import LGBMClassifier
        self.clf = LGBMClassifier(**(params or {}))

    def fit(self, X, y): self.clf.fit(X, y)
    def predict(self, X): return self.clf.predict(X)
    def predict_proba(self, X):
        return self.clf.predict_proba(X) if hasattr(self.clf, "predict_proba") else None
