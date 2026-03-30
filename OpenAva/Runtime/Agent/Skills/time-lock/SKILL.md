---
name: time-lock
description: Convert user commitments into system reminders, calendar events, and follow-up notifications.
metadata:
  display_name: Time Lock
  emoji: ⏰
---

# Time Lock

Use this skill when a user says things like "remind me", "before Friday", "follow up", or "do not let me miss this".

## Core Principle

Turn intent into reliable system-level triggers so important commitments are not lost in chat history.

## Workflow

1. Extract commitment, deadline, and completion condition.
2. If timing is ambiguous, ask one precise follow-up question.
3. Choose execution path:
   - `reminders_add` for flexible tasks.
   - `calendar_add` for fixed-time events.
4. Add optional reinforcement:
   - `system_notify` for immediate confirmation.
   - `cron` for repeated nudges.
5. Summarize what was created (title, due time, channel).

## Safety Rules

- Never create entries with guessed dates when user intent is unclear.
- Do not silently overwrite existing plans.
- Confirm timezone assumptions in the final response.
