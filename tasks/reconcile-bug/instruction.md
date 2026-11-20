# Transaction Reconciliation

The Python script at `/app/reconcile.py` is a payment reconciliation tool. It
reads a CSV of transactions and prints a JSON summary. **It currently does not
behave correctly.** Your job is to make it correctly implement the
specification below. You may edit `/app/reconcile.py` however you like.

## Usage

The script takes exactly one positional argument: the path to a CSV file.

```
python3 /app/reconcile.py <path_to_csv>
```

It must print **one** JSON object to stdout — nothing else — with this shape:

```json
{"total_valid_amount": <float>, "valid_count": <int>, "failed_count": <int>}
```

## Input CSV format

The CSV has a header row with exactly these columns, in this order:

- `tx_id` — a string identifier for the transaction.
- `timestamp` — an ISO-8601 timestamp **with a timezone offset**
  (e.g. `2024-01-15T10:00:00-05:00` or `2024-01-15T12:00:00+00:00`).
- `amount` — a decimal number (dollars).
- `status` — one of `VALID`, `FAILED`, or `PENDING`.

## Business rules

1. **Status handling.**
   - `VALID` rows contribute to `valid_count` and their `amount` is added to
     `total_valid_amount`.
   - `FAILED` rows contribute to `failed_count`.
   - `PENDING` rows are ignored entirely — they do not contribute to any
     count or to any total.

2. **Deduplication.** The same `tx_id` may appear in more than one row
   (retries, replays, updates from different systems, etc.). Before applying
   the status rules in (1), deduplicate so that only one row per `tx_id`
   survives, chosen as follows:

   a. Compare rows by their **absolute UTC instant**. Timestamps carry
      timezone offsets, so two rows with different offsets must be compared
      as actual UTC moments — not as naive wall-clock strings. Keep the row
      with the latest UTC instant.

   b. **Tiebreaker.** If two or more rows for the same `tx_id` share the
      *exact* same UTC instant, choose the winner using a deterministic rule
      based on the row contents (not insertion order — different systems
      may produce the CSV in different orders, so the winner must be fully
      determined by what each row says). The tiebreaker is designed so that
      a human reconciling these transactions would pick the most conservative
      interpretation.

3. **Rounding.** `total_valid_amount` must be rounded to 2 decimal places
   using Python's `round()`.

4. **Output.** Print exactly one line of JSON to stdout. No logging, no
   banner, no trailing text. Any extra output on stdout will cause downstream
   parsing to fail.

## Constraints

- Python 3.12 standard library only. Do not `pip install` anything.
- The script must exit with code 0 on well-formed input.
- Keep the file under ~90 lines of code.

When you believe the script is correct, you are done. Hidden tests will
verify your output against a ground-truth implementation using CSV inputs
you have not seen.