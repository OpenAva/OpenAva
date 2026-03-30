---
name: memory-maintenance
description: Review, distill, and maintain long-term memory and searchable history.
metadata:
  display_name: Memory Maintenance
  emoji: 🧠
---

# Memory Maintenance

Use this skill when the task is specifically about cleaning up, curating, or consolidating memory.

## Retrieval Rules

- Read current long-term memory before making broad edits.
- For historical events, call `memory_history_search` with a focused query.
- Read recent `memory/YYYY-MM-DD.md` files when the request depends on raw daily notes.

## Update Rules

- Save durable facts to long-term memory only when confidence is high.
- Use `memory_write_long_term` instead of generic file writes for `MEMORY.md`.
- Use `memory_append_history` instead of generic file writes for `HISTORY.md`.
- Keep history entries factual, concise, and time-oriented.
- Do not duplicate unchanged long-term memory content.

## Workflow

1. Inspect the current memory state.
2. Separate durable facts from transient notes.
3. Update `MEMORY.md` only with information worth carrying forward.
4. Append a factual `HISTORY.md` entry when a decision, milestone, or summary should stay searchable.
5. Report what changed and why.
