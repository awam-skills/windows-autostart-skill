---
name: windows-autostart
description: >-
  Create, inspect, and remove current-user Windows logon/scheduled startup
  entries through the repo's windows-autostart.ps1 CLI (JSON output). Use when
  the user wants to "login self-start / 登录自启", "run on a schedule / 定时执行",
  register a business command to launch on Windows login or on a DAILY/MINUTE
  timer, list its status, or uninstall it. Passes everything through the CLI —
  this skill never writes system state itself.
---

# windows-autostart

Orchestrate user-level Windows startup entries (logon autostart / 登录自启, scheduled
execution / 定时执行) by driving the `windows-autostart.ps1` CLI. The CLI is the
only writer; this skill detects, recommends, interprets, and explains — it does
not register tasks, shortcuts, or registry keys on its own.

## When to use

- "登录后自动运行 X" / "把这条命令设为登录自启" / "run this on login"
- "每天 09:00 跑一次" (DAILY) / "每隔 N 分钟跑一次" (MINUTE) / "run every day at 09:00"
- "看看这个启动项现在什么状态" / "卸载这个自启" / "what's the status" / "uninstall this"

Not for (out of scope — step away, don't improvise):
- Windows services / pre-logon boot (AtStartup / SYSTEM)
- All-users / HKLM / Public Startup (machine-wide scope; needs admin)
- Elevation by default (only with explicit `-Elevate`, and default remains Limited)
- Complex calendar rules (weekly, etc.) — v1 is DAILY and MINUTE only

## Input contract (add)

One startup entry = name + business command + timing mode. Required: `Name`,
`Command`, `Mode` (`logon` | `schedule`). Conditional when `Mode=schedule`:
`ScheduleType` (`DAILY` with `At=HH:mm`, or `MINUTE` with `Every=<minutes>`).
Optional: `WorkDir`, `Landing` (`scheduled-task` | `startup` | `run-key`),
`-Elevate`, `-Force`, `Root` (package-root override). `Root` overrides the
**base** directory; the per-name subdirectory is always appended, so the package
lands at `<Root>\<name>\` — the resolved path is whatever `add` returns in
`data.root` and `data.artifacts.*`.

`Command` is the full business command (executable + args). If the executable
path contains spaces it MUST be quoted by the caller, e.g.
`-Command '"C:\Program Files\App\app.exe" --flag value'`. Script business
commands (`.ps1` / `.vbs` / `.lnk`) are auto-wrapped with their interpreter by
the packaging layer.

## How to invoke the CLI

Skill directory: the directory that contains this file — call it `$SKILL_DIR`.
The CLI lives alongside this file (in-repo: hard link to the repo-root script;
global install: junction to this skill directory).

Prefer **PowerShell 7 (`pwsh`)** (Windows PowerShell 5.1 fails to parse UTF-8
without BOM):

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "$SKILL_DIR\windows-autostart.ps1" <subcommand> [flags]
```

Every subcommand prints a single JSON object to stdout and exits
`0` (ok) / `1` (error) / `2` (partial). Envelope: `command`, `result`
(`ok|partial|error`), `error`, `data`. Parse stdout; do not guess from tables.

> Windows PowerShell 5.1 collapses single-element arrays to scalars in JSON;
> treat list fields (`removed`, `skipped`, `absent`, `failed`, `pids`) as
> "string or array".

## Orchestration flow

### 1. Detect + recommend (always first)

```powershell
... recommend [-Mode logon|schedule]
```

Read `data.landings[].{name,rank,reason}` and `data.environment.canWriteScheduledTask`.
Explain the ordering: scheduled-task first when writable; otherwise Startup
fallback; Run key never appears in the auto ranking. For `-Mode schedule` the
only landing is `scheduled-task` (ADR-0002).

### 2. Register with `add`

```powershell
... add -Name <name> -Command "<business command>" -Mode logon
```

Interpret `data.landing` (actual spot written), `data.artifacts` (business
script / hidden entry / log paths / manifest, plus scheduledTaskName or
startupShortcut or runKeyValue), and — if `data.fallback` is true — explain that
the scheduled task was rejected and Startup was used (`data.fallbackReason`).

Rules to convey:
- No `-Landing` → default chain: scheduled task first, fall back to Startup on
  failure, only ONE spot, never Run key (ADR-0003).
- Same name already exists → refused without `-Force`; with `-Force` it
  uninstalls then recreates.

### 3. Diagnose with `status`

```powershell
... status -Name <name>
```

Map `data.diagnosis` to plain language:
- `not_found` → not registered (parseable result, not an error)
- `started` / `started_with_stderr` → business process is up; in-app warnings in
  the err log are **not** failures
- `failed_to_start` → no log and the task’s last result code is non-zero: command
  parse / launch failure
- `running` / `not_started` → running / not observed running yet

Distinguish "command parse failure" (no log + non-zero result) from
"in-app warning" (log present). Report `data.task.runState`, `data.landings.*`,
and `data.log.*Tail` as the observability snapshot.

### 4. Remove with `uninstall`

```powershell
... uninstall -Name <name>
```

Read `data.removed` (cleaned), `data.skipped` (exists but not ours — left
alone), `data.absent` (already gone). Idempotent: re-running returns ok. Only
entries owned by this tool are removed (ownership = hidden entry referenced by
the landing + manifest under the package root).

## Out of scope (never do these in this skill)

No Service, no all-users / HKLM / Public Startup, no default elevation, no
daemon / auto-relaunch (status is a snapshot only). Reads and interpretations
here; every mutating action goes through the CLI.
