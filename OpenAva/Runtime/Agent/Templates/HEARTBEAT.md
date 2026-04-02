# HEARTBEAT.md - Periodic Checks

This file is checked by OpenAva on the configured heartbeat interval.

Use YAML front matter to control scheduling and notifications:

```yaml
---
every: 30m
active_hours: 09:00-18:00
notify: silent
---
```

- `every`: heartbeat interval. Supports values like `30m`, `10s`, `1h`.
- `active_hours`: optional active time windows, for example `09:00-12:00, 14:00-18:00`.
- `notify`: `silent` or `always`.

Add the tasks you want the agent to check or perform below.
If nothing needs to be done, the agent should reply with `HEARTBEAT_OK`.

## Active Tasks

<!-- Add your periodic tasks below this line -->

- Review outstanding reminders and deadlines.
- Check whether any scheduled follow-up needs to happen today.

## Notes

<!-- Keep extra heartbeat instructions or routing notes here if needed -->
