---
name: meeting-brief
description: Generate pre-meeting briefs from calendar, reminders, and memory context.
metadata:
  display_name: Meeting Brief
  emoji: 🗓️
---

# Meeting Brief

Use this skill to prepare users for upcoming meetings with concise, actionable context.

## Inputs To Gather

- Upcoming events from `calendar_events`.
- Relevant pending items from `reminders_list`.
- Historical commitments via `memory_history_search` when needed.

## Workflow

1. Identify the target meeting (usually next event or user-specified event).
2. Collect context from calendar, reminders, and memory history.
3. Build a briefing package with:
   - Meeting objective
   - Key commitments and unresolved items
   - Top risks and likely questions
   - Suggested opening statement
4. If requested, schedule a reminder before meeting start using `system_notify` or `cron`.

## Output Template

- Event: title + time + participants (if available)
- Must-say points: 3-5 bullets
- Risks: up to 3 bullets
- Next actions after meeting: 2-3 bullets
