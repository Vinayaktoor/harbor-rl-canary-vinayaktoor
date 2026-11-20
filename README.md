# Harbor RL Submission — <Your Name> (@your-github-username)

## 1. Loom Walkthrough Video

- **Video URL:** [Watch 5-Minute Walkthrough](https://www.loom.com/share/YOUR_VIDEO_ID)
  *(Make sure link sharing is set to "Anyone with the link can view")*

## 2. Task & Calibration Summary

- **Bug 1 (Easy, CLI crash):** `reconcile.py` reads the CSV path from `sys.argv[2]` instead of `sys.argv[1]`, so it crashes with `IndexError` the moment it is launched with a normal single positional argument.
- **Bug 2 (Medium, logic):** The status filter is written as `if row["status"] != "FAILED"` instead of `if row["status"] == "VALID"`, so `PENDING` rows are wrongly counted toward `valid_count` and added to `total_valid_amount`.
- **Bug 3 (Hard, edge case):** `parse_timestamp` calls `.replace(tzinfo=None)`, dropping the timezone. Dedup-by-latest-timestamp then uses naive wall-clock comparison and picks the wrong row whenever duplicates span different timezone offsets.
- **Calibration Scores:** `nop` = `0.000` | `oracle` (`solve.sh`) = `1.000` | Partial `oracle` (Bug 1 + Bug 2 fixed, Bug 3 broken, shown in video) = `0.500` | `hack.sh` = `0.000`.

## 3. Ablation & RL Advantage Table (`terminus-2`, `k=3` trials)

Fill the table in from your actual `result.json` files. Advantage is computed per-trial as $A_i = R_i - \bar{R}$ where $\bar{R}$ is the mean reward over the 3 trials in the group.

| Run | Change Tested | Trial 1 (Binary / Dense) | Trial 2 (Binary / Dense) | Trial 3 (Binary / Dense) | Mean Binary | Mean Dense ($\bar{R}$) | Binary Advantage ($R_i - \bar{R}$) | Dense Advantage ($R_i - \bar{R}$) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Run 1: Baseline** | Original 3-bug task, no hints. | `<0 / 0.50>` | `<0 / 0.20>` | `<0 / 0.60>` | `<0.00>` | `<0.43>` | `<0.00, 0.00, 0.00>` | `<+0.07, -0.23, +0.17>` |
| **Run 2: Ablation** | `<e.g. "Added a sample CSV at /app/sample.csv so the agent naturally tests cross-TZ dedup before stopping.">` | `<...>` | `<...>` | `<...>` | `<...>` | `<...>` | `<...>` | `<...>` |

> **Note on "Binary" column:** compute what the trial *would have scored* under a 0/1 verifier (1 only if all 3 bugs were fixed, else 0). That's the hypothetical binary version I upgraded away from.

## 4. Trajectory Forensics (`trajectory.json`)

- **Where the agent failed in Run 1:** `<2–3 sentences. Name the exact bash command in trajectory.json where the agent stopped short, e.g.: "In Trial 2 the agent ran `python3 reconcile.py sample.csv` after fixing sys.argv[1], saw the status counts looked plausible on a CSV with no PENDING rows, ran one more sanity print, and called `done`. It never constructed a cross-timezone test case, so Bug 3 was never observed.">`
- **Ablation hypothesis & result:** `<2–3 sentences. Describe the single change you made and what you expected vs saw. E.g.: "I added a sample CSV at /app/sample_with_tz_dups.csv containing duplicate tx_ids across +00:00 and -10:00, with the latest UTC row as FAILED. Hypothesis: the agent would run its script on that sample, see counts it couldn't explain, and investigate. Result: 2 of 3 trials now attempted tz-aware parsing and Bug 3 fixes went from 0/3 → 2/3.">`

## 5. Dense Reward & Anti-Cheat Design

- **Dense reward weights (`tests/test.sh`):** I split 1.00 across 4 independent checks: 0.20 for "script runs on a simple CSV" (isolates Bug 1), 0.30 for "status filtering excludes PENDING" (isolates Bug 2), 0.40 for "timezone-aware dedup picks the right winner" (isolates Bug 3, weighted highest because it's the hardest and would otherwise be the local-optimum trap), and 0.10 for a fully randomized integration check that pure anti-cheat signal — no single check can be passed by a script that doesn't actually read its input.
- **How `solution/hack.sh` cheated & how I blocked it:** `hack.sh` replaces `reconcile.py` with a stub that ignores the CSV and prints a hardcoded `{"total_valid_amount": 175.0, "valid_count": 2, "failed_count": 1}`. My hardened `test.sh` generates all 4 CSVs at verification time using a fresh random seed per run and derives expected outputs from its own ground-truth oracle, so no hardcoded JSON can match any of the four expected outputs — the hack scores 0.00.
- **Remaining reward-hacking risk:** A smarter agent could read `/tests/test.sh` while it runs (or inspect the oracle it embeds) and plagiarize the reference reconciliation logic without actually understanding the bugs. The verifier currently makes no attempt to hide its oracle from the agent's environment, nor does it isolate `/tests/` from `/app/` at runtime — a next hardening step would be to run the oracle in a separate container or hash-check that `/app/reconcile.py` was not edited after `/tests/test.sh` started.

## 6. AI Tool Workflow

- **AI tool & model used:** `<e.g., Claude Code + Sonnet / Gemini CLI / Cursor + Claude>`
- **How I avoided prompt leakage:** I used two separate AI sessions. Session A got the buggy `reconcile.py`, the spec, and no access to `tests/`, `solution/`, or even a filename hint — it wrote `instruction.md` purely from the spec and reviewed it for spoilers. Session B got `tests/test.sh`, `solve.sh`, and `hack.sh` but was never shown `instruction.md`. This prevented the chat that wrote the instructions from accidentally pattern-matching to the exact line numbers or function names of the planted bugs.
