---
name: memory-maintenance
description: Review, distill, and maintain durable agent memory topics and transcript-backed history.
metadata:
  display_name: Memory Maintenance
  emoji: 🧠
---

# Memory Maintenance

Use this skill when the task is specifically about cleaning up, curating, or consolidating memory.

## Retrieval Rules

- Start with `memory_recall` to inspect relevant durable memory topics.
- Use `memory_transcript_search` only when exact past conversation details or timelines matter.

## Update Rules

- Save durable facts only when confidence is high.
- Use `memory_upsert` to create or update typed durable memories.
- Use `memory_forget` when a memory is stale, superseded, or incorrect.
- Prefer updating an existing topic over creating duplicates.
- Reserve `memory_transcript_search` for recall, not as a write path.

## Workflow

1. Inspect the current durable memory state with `memory_recall`.
2. Separate durable facts from transient notes.
3. Update or create typed memory topics with `memory_upsert`.
4. Remove obsolete topics with `memory_forget` when needed.
5. Use `memory_transcript_search` if you need evidence from past sessions before editing.
6. Report what changed and why.
