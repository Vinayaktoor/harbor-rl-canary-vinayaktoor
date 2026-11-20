#!/bin/bash
# Reference solution: replace /app/reconcile.py with a correct implementation.
set -e

cat > /app/reconcile.py << 'PYEOF'
#!/usr/bin/env python3
"""Payment reconciliation tool (reference solution)."""
import sys
import csv
import json
from datetime import datetime


def parse_timestamp(ts: str) -> datetime:
    # Preserve timezone so cross-TZ comparisons are correct.
    return datetime.fromisoformat(ts)


def load_rows(csv_path: str):
    with open(csv_path, newline="") as f:
        return list(csv.DictReader(f))


# FAILED < PENDING < VALID — alphabetical order, per spec tiebreaker.
STATUS_RANK = {"FAILED": 0, "PENDING": 1, "VALID": 2}


def dedupe_latest(rows):
    latest = {}
    for row in rows:
        tx_id = row["tx_id"]
        ts = parse_timestamp(row["timestamp"])
        if tx_id not in latest:
            latest[tx_id] = row
            continue
        cur_ts = parse_timestamp(latest[tx_id]["timestamp"])
        if ts > cur_ts:
            latest[tx_id] = row
        elif ts == cur_ts:
            # Tiebreaker: alphabetical status wins (lower rank).
            if STATUS_RANK[row["status"]] < STATUS_RANK[latest[tx_id]["status"]]:
                latest[tx_id] = row
    return list(latest.values())


def summarize(rows):
    valid_count = 0
    failed_count = 0
    total_valid_amount = 0.0
    for row in rows:
        status = row["status"]
        amount = float(row["amount"])
        if status == "VALID":
            valid_count += 1
            total_valid_amount += amount
        elif status == "FAILED":
            failed_count += 1
        # PENDING deliberately ignored.
    return {
        "total_valid_amount": round(total_valid_amount, 2),
        "valid_count": valid_count,
        "failed_count": failed_count,
    }


def main():
    csv_path = sys.argv[1]
    rows = load_rows(csv_path)
    deduped = dedupe_latest(rows)
    summary = summarize(deduped)
    print(json.dumps(summary))


if __name__ == "__main__":
    main()
PYEOF

echo "Reference fix applied to /app/reconcile.py"