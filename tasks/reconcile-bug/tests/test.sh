#!/bin/bash
# tests/test.sh — Dense reward verifier for reconcile-bug.
#
# Scoring (all independent, additive, sums to 1.00):
#   Check 1 (0.20) -- Script runs on a simple CSV and returns correct JSON.
#                     This essentially tests that Bug 1 (CLI/args) is fixed.
#   Check 2 (0.30) -- Status filtering: PENDING ignored, VALID counted, FAILED
#                     counted. This tests that Bug 2 (status logic) is fixed.
#   Check 3 (0.40) -- Timezone-aware deduplication by latest UTC instant.
#                     This tests that Bug 3 (the edge case) is fixed.
#   Check 4 (0.10) -- Fully randomized integration sample. Pure anti-cheat
#                     signal: if the agent's script matches here, it's doing
#                     real work rather than regurgitating hardcoded answers.
#
# Anti-cheat hardening:
#   - Every expected output is computed inside this script by a ground-truth
#     oracle, from CSVs generated at verification time.
#   - The random seed is sampled per verification, so no two runs produce
#     the same expected outputs.
#   - hack.sh (hardcoded JSON) will mismatch all four checks → 0.00.

set +e
mkdir -p /logs/verifier
PY=/app/reconcile.py
WORKDIR=$(mktemp -d)

# Random seed. Allow override via env for reproducibility during development,
# but default to a fresh seed per run so repeat trials don't share expected
# values.
SEED="${TEST_SEED:-$(( (RANDOM << 15) | RANDOM ))}"

# --- Ground-truth oracle used to compute expected outputs ----------------
cat > "$WORKDIR/oracle.py" <<'PYEOF'
import csv, json, sys
from datetime import datetime

def reconcile(path):
    rows = list(csv.DictReader(open(path, newline="")))
    latest = {}
    for r in rows:
        ts = datetime.fromisoformat(r["timestamp"])
        if r["tx_id"] not in latest \
           or ts > datetime.fromisoformat(latest[r["tx_id"]]["timestamp"]):
            latest[r["tx_id"]] = r
    vc = fc = 0
    tot = 0.0
    for r in latest.values():
        if r["status"] == "VALID":
            vc += 1
            tot += float(r["amount"])
        elif r["status"] == "FAILED":
            fc += 1
    return {"total_valid_amount": round(tot, 2),
            "valid_count": vc,
            "failed_count": fc}

if __name__ == "__main__":
    print(json.dumps(reconcile(sys.argv[1])))
PYEOF

# --- Output comparator (tolerant on floats, strict on counts) -----------
cat > "$WORKDIR/cmp.py" <<'PYEOF'
import json, sys
try:
    a = json.loads(sys.argv[1])
    e = json.loads(sys.argv[2])
    ok = (abs(float(a["total_valid_amount"]) - float(e["total_valid_amount"])) < 0.01
          and int(a["valid_count"])  == int(e["valid_count"])
          and int(a["failed_count"]) == int(e["failed_count"]))
    sys.exit(0 if ok else 1)
except Exception:
    sys.exit(2)
PYEOF

# --- Generate 4 randomized CSVs that each target a specific bug ---------
python3 - "$WORKDIR" "$SEED" <<'PYEOF'
import csv, random, sys
W, seed = sys.argv[1], int(sys.argv[2])
random.seed(seed)

def ts(y, mo, d, h, mi, tz):
    return f"{y:04d}-{mo:02d}-{d:02d}T{h:02d}:{mi:02d}:00{tz}"

# ---- t1.csv — simple CSV. Unique tx_ids, same timezone, only VALID/FAILED.
# Even an agent that fixed only Bug 1 will pass this one. That's intentional:
# Check 1 isolates "the script runs at all".
with open(f"{W}/t1.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["tx_id", "timestamp", "amount", "status"])
    for i in range(6):
        amt = round(random.uniform(10, 500), 2)
        st  = random.choice(["VALID", "FAILED"])
        w.writerow([f"A{i:03d}", ts(2024, 3, 1+i, 10, 0, "+00:00"), amt, st])

# ---- t2.csv — status mix. Includes PENDING (must be ignored), unique tx_ids.
# Isolates Bug 2 (the agent must recognize PENDING is not VALID).
with open(f"{W}/t2.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["tx_id", "timestamp", "amount", "status"])
    mix = [("VALID",   random.randint(3, 5)),
           ("FAILED",  random.randint(2, 4)),
           ("PENDING", random.randint(3, 5))]
    idx = 0
    for st, n in mix:
        for _ in range(n):
            amt = round(random.uniform(10, 500), 2)
            w.writerow([f"B{idx:03d}", ts(2024, 4, 1 + idx % 20, 10, 0, "+00:00"), amt, st])
            idx += 1

# ---- t3.csv — timezone duplicates. For each tx_id, write two rows where the
# naive wall-clock comparison picks the WRONG winner. The row with the small
# clock time but very negative offset is actually later in UTC.
with open(f"{W}/t3.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["tx_id", "timestamp", "amount", "status"])
    for i in range(5):
        tx = f"C{i:03d}"
        # Loser row:  11:00+00:00 == 11:00 UTC (naive picks this).
        # Winner row: 02:00-10:00 == 12:00 UTC (actually later).
        winner_status = random.choice(["VALID", "FAILED"])
        loser_status  = "PENDING" if winner_status != "PENDING" else "FAILED"
        # Ensure the two rows give different outcomes under the two logics.
        if winner_status == loser_status:
            loser_status = "PENDING"
        w.writerow([tx, ts(2024, 5, 10+i, 11, 0, "+00:00"),
                    round(random.uniform(50, 300), 2), loser_status])
        w.writerow([tx, ts(2024, 5, 10+i,  2, 0, "-10:00"),
                    round(random.uniform(50, 300), 2), winner_status])

# ---- t4.csv — integration test. Repeats, multiple timezones, PENDING.
# We DELIBERATELY inject tx_ids whose rows would be dedup'd differently
# under naive wall-clock vs tz-aware comparison. This guarantees Check 4
# is sensitive to Bug 3 — otherwise a lucky seed could let a partial-fix
# agent collect free credit here and make the partial score non-reproducible.
with open(f"{W}/t4.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["tx_id", "timestamp", "amount", "status"])

    # Injected tz-sensitive duplicates. Winner (02:00-10:00 == 12:00 UTC) is
    # later than loser (11:00+00:00 == 11:00 UTC), but naive compare picks
    # the loser. Status flips so the outcome actually changes.
    for i in range(2):
        tx = f"X{i:03d}"
        w.writerow([tx, ts(2024, 7, 1+i, 11, 0, "+00:00"),
                    round(random.uniform(50, 300), 2), "PENDING"])
        w.writerow([tx, ts(2024, 7, 1+i,  2, 0, "-10:00"),
                    round(random.uniform(50, 300), 2), "VALID"])

    n = random.randint(28, 48)
    tzs = ["+00:00", "-05:00", "-08:00", "+09:00", "+05:30", "-03:00"]
    pool = []
    for i in range(n):
        if pool and random.random() < 0.3:
            tx = random.choice(pool)
        else:
            tx = f"R{i:04d}"
            pool.append(tx)
        mo = random.randint(1, 12)
        d  = random.randint(1, 28)
        h  = random.randint(0, 23)
        tz = random.choice(tzs)
        amt = round(random.uniform(1, 1000), 2)
        st  = random.choice(["VALID", "FAILED", "PENDING"])
        w.writerow([tx, ts(2024, mo, d, h, 0, tz), amt, st])
PYEOF

# --- Compute expected outputs from the oracle ----------------------------
E1=$(python3 "$WORKDIR/oracle.py" "$WORKDIR/t1.csv")
E2=$(python3 "$WORKDIR/oracle.py" "$WORKDIR/t2.csv")
E3=$(python3 "$WORKDIR/oracle.py" "$WORKDIR/t3.csv")
E4=$(python3 "$WORKDIR/oracle.py" "$WORKDIR/t4.csv")

# --- Run the agent's script on each CSV (stdout only) --------------------
A1=$(python3 "$PY" "$WORKDIR/t1.csv" 2>/dev/null || true)
A2=$(python3 "$PY" "$WORKDIR/t2.csv" 2>/dev/null || true)
A3=$(python3 "$PY" "$WORKDIR/t3.csv" 2>/dev/null || true)
A4=$(python3 "$PY" "$WORKDIR/t4.csv" 2>/dev/null || true)

# --- Grade ---------------------------------------------------------------
PASS_1=0; PASS_2=0; PASS_3=0; PASS_4=0

if [ -n "$A1" ] && python3 "$WORKDIR/cmp.py" "$A1" "$E1"; then PASS_1=1; fi
if [ -n "$A2" ] && python3 "$WORKDIR/cmp.py" "$A2" "$E2"; then PASS_2=1; fi
if [ -n "$A3" ] && python3 "$WORKDIR/cmp.py" "$A3" "$E3"; then PASS_3=1; fi
if [ -n "$A4" ] && python3 "$WORKDIR/cmp.py" "$A4" "$E4"; then PASS_4=1; fi

SCORE=$(python3 -c "print(round($PASS_1*0.20 + $PASS_2*0.30 + $PASS_3*0.40 + $PASS_4*0.10, 4))")

echo "$SCORE" > /logs/verifier/reward.txt

echo "========== Verifier Report =========="
echo "Seed used:              $SEED"
echo "Check 1 (CLI/runs):     $PASS_1  x 0.20"
echo "Check 2 (status/PEND):  $PASS_2  x 0.30"
echo "Check 3 (tz dedup):     $PASS_3  x 0.40"
echo "Check 4 (random int):   $PASS_4  x 0.10"
echo "----------------------------------------"
echo "Total reward:           $SCORE"
echo "========================================"
