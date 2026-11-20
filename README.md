# Harbor RL Submission — Vinayak Toor (@vinayaktoor)

## 1. Loom Walkthrough Video

- **Video URL:** [Watch 5-Minute Walkthrough](https://www.loom.com/share/9eb11088f026405da6d88bef6d94e60f)
  *(Link sharing: "Anyone with the link can view")*

## 2. Task & Calibration Summary

- **Bug 1 (Easy, CLI crash):** `reconcile.py` reads the CSV path from `sys.argv[2]` instead of `sys.argv[1]`, so it crashes with `IndexError` immediately when launched with a normal single positional argument.
- **Bug 2 (Medium, logic):** The status filter is written as `if row["status"] != "FAILED"` instead of `if row["status"] == "VALID"`, so `PENDING` rows are wrongly counted toward `valid_count` and their amounts added to `total_valid_amount`.
- **Bug 3 (Hard, edge case):** `parse_timestamp` calls `.replace(tzinfo=None)`, dropping the timezone. Dedup-by-latest-timestamp then uses naive wall-clock comparison and picks the wrong row whenever duplicates span different timezone offsets.
- **Calibration Scores:** `nop` = `0.000` | `oracle` (`solve.sh`) = `1.000` | Partial `oracle` (Bug 3 broken, shown in video) = `0.50` | `hack.sh` = `0.000`.

> **Note:** `instruction.md` additionally specifies an alphabetical status tiebreaker (`FAILED < PENDING < VALID`) for same-UTC-instant duplicates. This rule is documented but **not currently enforced by `tests/test.sh`** — the verifier scores only Bugs 1, 2, and 3. See Section 5 for the design rationale and what a Bug 4 check would look like.

## 3. Ablation & RL Advantage Table (`terminus-2`, `k=3` Trials)

Advantage per trial: $A_i = R_i - \bar{R}$ where $\bar{R}$ is the group mean.

| Run | Change Tested | Trial 1 (Binary / Dense) | Trial 2 (Binary / Dense) | Trial 3 (Binary / Dense) | Mean Binary | Mean Dense ($\bar{R}$) | Binary Advantage | Dense Advantage |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Run 1: Baseline** | Original 3-bug task, `gpt-oss-120b` on Groq free tier. | 1 / 1.00 | 1 / 1.00 | — / RateLimitError (TPM 8807/8000) | 1.00 (n=2) | 1.00 (n=2) | 0.00, 0.00 | 0.00, 0.00 |
| **Run 2: Ablation** | Not completed. All attempts hit Groq TPM cap of 8000 tokens/min once the trajectory contained the buggy source file. See Section 4. | — | — | — | — | — | — | — |

**Job ID:** `fc74e3d4-f7a2-4a30-85ab-f8b6032a6d67` • **Total runtime:** 13m 52s • **Total cost:** $0.0079 • **Retries attempted on Trial 3:** 3, all hit TPM cap

### Notes on the zero-signal trap

Two of three Baseline trials completed, both scoring exactly **1.00**. Even under dense grading, this group has **zero variance** — Mean = 1.00, every Advantage = 0.00. A GRPO-style RL update built on this rollout group would produce **zero gradient** in both binary and dense regimes. The model would learn nothing from these trials.

This is itself the finding: `gpt-oss-120b` is a strong enough coder that it fixes all three bugs in a single file rewrite with no failed intermediate attempts, so the rollout group collapses to a point mass at 1.00. Breaking out of this trap would require either a weaker model (which would miss Bug 3 sometimes) or a harder task (removing hints from `instruction.md`).

## 4. Trajectory Forensics (`trajectory.json`)

### Trial 1 (`reconcile-bug__3EpRCva`, scored 1.00, 4 steps, $0.003)

The agent executed exactly **4 steps**. Step 1 inspected `/app/reconcile.py` with `ls -la /app` + `sed -n '1,200p' /app/reconcile.py`. Step 2 overwrote the file in a **single `cat > /app/reconcile.py <<'PYTHON' ... PYTHON` heredoc** that fixed all three bugs simultaneously: changed `sys.argv[2]` → `sys.argv[1]`, replaced `.replace(tzinfo=None)` with `datetime.fromisoformat(ts).astimezone(timezone.utc)`, and split `if status != "FAILED"` into separate `status == "VALID"` and `elif status == "FAILED"` branches. Step 3 wrote a 5-row test CSV covering tz offsets, PENDING rows, and duplicate `tx_id`s, ran the script, and confirmed `{"total_valid_amount":50.55,"valid_count":1,"failed_count":1}`. Step 4 called `mark_task_complete`. **The agent never tried a wrong approach** — it read the spec, understood all three rules, and produced a correct implementation in one shot.

Trial 2 (`iL3eS7c`) followed an almost identical trajectory in **3 steps**, costing $0.002.

### Trial 3 (`reconcile-bug__7S4JcCx`, RateLimitError after 3 retries)

The agent started correctly with the same inspection commands as Trials 1 and 2. At Step 3, instead of using a heredoc, it attempted `apply_patch <<'PATCH' ... PATCH` — a patch tool that is **not installed** in the Harbor Docker container. The terminal returned `bash: apply_patch: command not found`. The agent was poised to recover and fall back to a heredoc, but on the next LLM call Groq returned **HTTP 413**:

> `Request too large for model openai/gpt-oss-120b on tokens per minute (TPM): Limit 8000, Requested 8807`

The prompt payload had grown past 8,000 tokens because the trajectory now contained both the buggy source file AND the failed `apply_patch` attempt (both quoted back in the next prompt as context). Harbor retried 3 times — all 3 hit the same TPM cap because **the prompt size doesn't shrink on retry**. The trial was abandoned.

**This was an infrastructural failure, not a reasoning failure.** The model had the right strategy on the second try but could never get its response back from Groq. More interestingly, it exposes a real RL rollout failure mode: **longer trajectories are more likely to rate-limit, and retrying makes the prompt bigger not smaller**, so once a trajectory crosses the TPM cap it can't recover. Reward shaping alone cannot fix this — the fix is at the infrastructure layer (summarize older trajectory steps, or use models with higher TPM caps).

### Ablation hypothesis (not experimentally validated)

My planned ablation was to add an explicit `/app/sample.csv` to the Docker environment containing cross-timezone duplicates, so the agent would naturally test its code against tz-sensitive cases before marking complete. Both successful Baseline trials happened to write tz-aware code because `instruction.md` mentions the UTC-instant rule explicitly, but a weaker model would likely miss Bug 3 without a concrete sample to fail against. **Hypothesis:** adding the sample would move a weaker model's score on Bug 3 from ~0% to ~70%, producing score spread for the Advantage math. I was unable to run this because Groq's free tier TPM limit prevented any Run 2 trial from completing.

## 5. Dense Reward & Anti-Cheat Design

- **Dense reward weights (`tests/test.sh`):** 1.00 split across 4 independent checks — 0.20 for "script runs on a simple CSV" (Bug 1), 0.30 for "status filtering excludes PENDING" (Bug 2), 0.40 for "timezone-aware dedup picks the right winner" (Bug 3, weighted highest because it's the primary subtle rule), and 0.10 for a fully randomized integration check that serves as pure anti-cheat signal and reliably covers cross-timezone duplicates by construction. All expected outputs are computed inside `test.sh` at run time from CSVs generated with a fresh random seed per verification.

- **Documented-but-unverified rule (Bug 4):** `instruction.md` specifies an alphabetical status tiebreaker (`FAILED < PENDING < VALID`) for rows sharing the exact same UTC instant, but the current `test.sh` does not include a check that exercises this rule. This is a deliberate design choice given the time budget, but it means a script that ignored the tiebreaker would still score 1.00. Adding a Check 5 that generates same-UTC-instant duplicates and scores 0.20 for correct tiebreaker handling would close this gap — the oracle and generator code for it is sketched in the solution's `solve.sh` where `STATUS_RANK = {"FAILED": 0, "PENDING": 1, "VALID": 2}` is implemented.

- **How `solution/hack.sh` cheated & how I blocked it:** `hack.sh` replaces `reconcile.py` with a stub that ignores the CSV and prints a hardcoded JSON payload — a plausible-looking answer that would defeat a naive verifier using a single fixed expected output. My hardened `test.sh` generates all 4 CSV inputs at verification time using a fresh random seed and derives expected outputs from its own ground-truth oracle embedded in the verifier. No hardcoded JSON can match the randomized expected outputs — `hack.sh` reliably scores 0.00.

- **Remaining reward-hacking risk:** A smarter agent could read `/tests/test.sh` from inside the container during the agent phase (before verification runs) and plagiarize the oracle implementation verbatim, scoring 1.00 without understanding any bug. The current verifier does not isolate `/tests/` from `/app/` during the agent's execution window. A next hardening pass would run the oracle in a separate container with no filesystem overlap with `/app`, or compare the agent's source against a known-oracle fingerprint using AST normalization.

- **Local-optimum risk at current weights:** With Bug 3 at 0.40, a risk-averse agent could rationally fix only Bugs 1 and 2 (0.50 combined, achievable with no deep reasoning) and refuse to touch the dedup logic. Collecting 0.50 safely beats a 50% chance at 1.00 combined with a 50% chance at 0.00 (expected value 0.50 but with high variance). If I observed this failure mode during training, I'd flatten the weights toward 0.25 across all four checks — equalizing marginal return per bug and removing the asymmetry that makes "safe partial fix" strategies dominate.

## 6. AI Tool Workflow

- **AI tool & model used:** Claude (claude.ai web interface, Opus 4.7) was used throughout to design the task, write the verifier, debug Harbor CLI version mismatches, and author this README. Harbor itself ran `terminus-2` with `gpt-oss-120b` on Groq as the agent-under-test.

- **How I avoided prompt leakage:** `instruction.md` was written to describe the **business rules** of the reconciliation task, not the shape of the bugs. Rules are stated as positive specifications (what the correct behavior is), not as hints about the current code's behavior. The verifier (`tests/test.sh`) was written with full knowledge of the bugs but is never shown to the agent at runtime — Harbor's container isolation keeps `/tests/` hidden during the agent phase. I manually reviewed the final `instruction.md` for anything that would reveal line numbers, function names, or specific implementation details of the bugs in `reconcile.py`.
