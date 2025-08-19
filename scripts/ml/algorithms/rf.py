# scripts/ml/algorithms/rf.py
class RFModel:
    """
    sklearn RandomForestClassifier; params passed exactly as provided.
    If class_weights=True and user didn't set 'class_weight', we set 'balanced'.
    """
    def __init__(self, params=None, class_weights=False, random_state=42):
        from sklearn.ensemble import RandomForestClassifier
        params = dict(params or {})
        if class_weights and "class_weight" not in params:
            params["class_weight"] = "balanced"
        if "random_state" not in params:
            params["random_state"] = random_state
        self.clf = RandomForestClassifier(**params)

    def fit(self, X, y): self.clf.fit(X, y)
    def predict(self, X): return self.clf.predict(X)
    def predict_proba(self, X):
        return self.clf.predict_proba(X) if hasattr(self.clf, "predict_proba") else None
