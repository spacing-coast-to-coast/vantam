import pandas as pd
from pathlib import Path

DATA_PATH = Path("analysis/ml/data/dataset.parquet")
REPORT_PATH = Path("analysis/ml/reports/dataset_profile.txt")

def main():
    print(f"📂 Loading dataset from {DATA_PATH} ...")
    df = pd.read_parquet(DATA_PATH)

    lines = []
    lines.append("=== Dataset Profile ===")
    lines.append(f"Shape: {df.shape[0]} rows × {df.shape[1]} columns")
    lines.append("")

    lines.append("=== Columns & Types ===")
    lines.append(str(df.dtypes))
    lines.append("")

    lines.append("=== First 5 rows ===")
    lines.append(str(df.head()))
    lines.append("")

    lines.append("=== Descriptive Stats (numeric only) ===")
    lines.append(str(df.describe().T))
    lines.append("")

    lines.append("=== Null Counts ===")
    lines.append(str(df.isnull().sum()))
    lines.append("")

    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text("\n".join(lines), encoding="utf-8")

    print(f"✅ Profile written to {REPORT_PATH}")

if __name__ == "__main__":
    main()
