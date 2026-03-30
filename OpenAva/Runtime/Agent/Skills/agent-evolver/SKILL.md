---
name: agent-evolver
description: Self-evolving agent skill that closes a learn-from-experience loop — act, evaluate, reflect, write memory, then inject relevant lessons into the next task to reduce repeated mistakes and improve over time.
metadata:
  display_name: Agent Evolver
  emoji: 🔄
---

# Agent Evolver

Use this skill when the task is:

- A **multi-step long-horizon task** (coding, data analysis, research reports) where the agent should refine strategy mid-flight and carry lessons into future runs.
- A **high-stakes task** (production changes, compliance checks) that requires a built-in critic review before delivering output.
- A **recurring task** where user preferences, domain SOPs, or past failure patterns should be remembered and re-applied automatically.

## Inputs

- `task_goal`: Clear, measurable description of what success looks like.
- `evaluation_criteria`: How to judge success — automated tests, data rules, or a human review checklist.
- `context` *(optional)*: Relevant past session notes, user profile, or domain reference documents.

## Core Workflow

Run each phase in sequence. Never skip Reflect or Memory Write after a task completes.

### Phase 1 — Act

Plan and execute the task using the current task goal plus any lessons injected from memory.

Produce:
- Final task output.
- Execution log with key decisions and evidence.

### Phase 2 — Evaluate

Compare actual output against `evaluation_criteria`.

Produce a structured evaluation with:
- Pass/fail verdict and score.
- Identified failure points with supporting evidence.
- Identified success factors.

### Phase 3 — Reflect

Distill the evaluation into one or more plain-text **lessons** — one lesson per distinct insight.

Rules:
- Only write a lesson when there is concrete evidence (logs, test results, data snapshots). Conclusions unsupported by evidence must be tagged `[confidence:low]`.
- Keep each lesson to 1–3 sentences: what triggered it, what went wrong (if anything), and what to do next time.
- Tag each lesson with short domain labels so future searches can find it.

Lesson format:
```
[lesson][tag1/tag2][confidence:high] When <trigger>, do <action>. Root cause if failed: <cause>.
```

Example:
```
[lesson][golang/concurrency][confidence:high] When generating Go concurrency tests, always add the -race flag and use t.Parallel() for subtests. Root cause: missing -race caused undetected race conditions.
```

### Phase 4 — Write Memory

Write each lesson to the appropriate layer. Do not create separate files.

- **`HISTORY.md`** (via `memory_append_history`): Write all task-level lessons here with domain tags. This is the primary store for experience — searchable on demand, not loaded into every session.
- **`MEMORY.md`** (via `memory_write_long_term`, mode: append): Only write a lesson here if it is universal across all task types and worth loading into every future session. Keep this rare — `MEMORY.md` is always fully injected and must stay lean.

### Phase 5 — Evolve (next task start)

Before acting on any new task, retrieve relevant lessons from memory and inject them.

Retrieval rules:
- Call `memory_history_search` with keywords or regex matching the current task domain and type.
- Prefer lessons tagged `[confidence:high]`; treat `[confidence:low]` lessons as advisory only.
- Deduplicate overlapping lessons before injection.

Injection rules:
- Restate retrieved lessons as **Reminders** in plain language — short imperatives, not raw tagged text.
- Keep injection concise: aim for ≤ 5 reminders.

Example injection:
```
Reminders from past experience:
- Always add the `-race` flag when compiling Go concurrency tests.
- Use relative paths; never hardcode absolute file paths.
- Validate output schema against the contract before returning.
```

## Critic Loop (High-Risk Tasks)

For tasks flagged as high-risk or high-uncertainty, run one extra review cycle after Phase 1:

1. Apply pre-defined principles or safety baselines to the initial output.
2. List specific violations or gaps with evidence.
3. Rewrite or patch the output to resolve each issue.
4. Re-evaluate before proceeding to Phase 2.

## Quality Controls

- **Confidence tiers**: High / Medium / Low. Downgrade any conclusion that lacks verifiable evidence. Deprioritize Low-confidence lessons during retrieval.
- **Evidence-first**: Every failure mode and lesson must be traceable to an artifact — a log line, test result, or data sample. No speculation.
- **No calcification**: Never treat a Low-confidence lesson as a default rule without re-validation.

## Evolution Metrics (long-term)

Track these to confirm the skill is working:
- Failure rate on recurring task types decreasing over time.
- Mean cycles to resolve a known issue decreasing.
- Number of iterations required for a task decreasing.
