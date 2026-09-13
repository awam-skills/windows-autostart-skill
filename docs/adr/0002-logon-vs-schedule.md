# Timing mode: logon and schedule are mutually exclusive; schedule is scheduled-task only

Logon autostart and scheduled execution have different semantics, and Startup / Run cannot express arbitrary timetables. Decide that one startup entry uses exactly one timing mode (`logon` | `schedule`); `schedule` forces the landing to scheduled task. v1 schedule support is once per day at a clock time (DAILY) and every N minutes (MINUTE); richer calendar rules come later. No pre-logon Windows Service / AtStartup unless a future ADR reopens that.
