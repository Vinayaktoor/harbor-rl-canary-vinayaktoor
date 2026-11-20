#!/usr/bin/env python3
"""Payment reconciliation tool.

Reads a CSV of transactions and prints a JSON summary of valid/failed counts
and total valid amount.
"""
import sys
import csv
import json
from datetime import datetime


def parse_timestamp(ts: str) -> datetime:
    """Parse an ISO-8601 timestamp into a datetime for comparison."""
    # Keep it simple: drop tz so comparisons work uniformly.
    return datetime.fromisoformat(ts).replace(tzinfo=None)


def load_rows(csv_path: str):
    with open(csv_path, newline="") as f:
        return list(csv.DictReader(f))


def dedupe_latest(rows):
    """For each tx_id, keep only the row with the latest timestamp."""
    latest = {}
    for row in rows:
        tx_id = row["tx_id"]
        ts = parse_timestamp(row["timestamp"])
        # Replace only on strictly later timestamp -- on ties, keep the
        # first row we saw (insertion order).
        if tx_id not in latest or ts > parse_timestamp(latest[tx_id]["timestamp"]):
            latest[tx_id] = row
    return list(latest.values())


def summarize(rows):
    valid_count = 0
    failed_count = 0
    total_valid_amount = 0.0
    for row in rows:
        status = row["status"]
        amount = float(row["amount"])
        if status != "FAILED":
            valid_count += 1
            total_valid_amount += amount
        else:
            failed_count += 1
    return {
        "total_valid_amount": round(total_valid_amount, 2),
        "valid_count": valid_count,
        "failed_count": failed_count,
    }


def main():
    # Expect: python3 reconcile.py <path_to_csv>
    csv_path = sys.argv[2]
    rows = load_rows(csv_path)
    deduped = dedupe_latest(rows)
    summary = summarize(deduped)
    print(json.dumps(summary))


if __name__ == "__main__":
    main()