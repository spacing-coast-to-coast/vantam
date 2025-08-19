# scripts/ml/algorithms/__init__.py
from .logreg import LogRegModel
from .rf import RFModel
from .xgboost import XGBModel
from .lightgbm import LGBMModel

REGISTRY = {
    "logreg": LogRegModel,
    "rf": RFModel,
    "xgboost": XGBModel,
    "lightgbm": LGBMModel,
}

__all__ = ["REGISTRY", "LogRegModel", "RFModel", "XGBModel", "LGBMModel"]
