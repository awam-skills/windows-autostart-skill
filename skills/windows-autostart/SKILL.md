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

Orchestrate user-level Windows startup entries (登录自启 / 定时执行) by driving the
`windows-autostart.ps1` CLI. The CLI is the only writer; this skill detects,
recommends, interprets, and explains — it does not register tasks, shortcuts, or
registry keys on its own.

## When to use

- "登录后自动运行 X" / "把这条命令设为登录自启"
- "每天 09:00 跑一次" (DAILY) / "每隔 N 分钟跑一次" (MINUTE)
- "看看这个启动项现在什么状态" / "卸载这个自启"

Not for (out of scope — step away, don't improvise):
- Windows 服务 / 登录前开机 (AtStartup / SYSTEM)
- 所有用户 / HKLM / 公共 Startup（机器级作用域，需管理员）
- 默认提权（只有显式 `-Elevate` 才可能，且默认 Limited）
- 复杂日历规则（weekly 等）——首版只有 DAILY 与 MINUTE

## Input contract (add)

One 启动项 = name + business command + timing mode. Required: `Name`, `Command`,
`Mode` (`logon` | `schedule`). Conditional when `Mode=schedule`: `ScheduleType`
(`DAILY` with `At=HH:mm`, or `MINUTE` with `Every=<minutes>`). Optional:
`WorkDir`, `Landing` (`scheduled-task` | `startup` | `run-key`), `-Elevate`,
`-Force`, `Root` (封装根目录 override). `Root` overrides the **base** directory;
the per-name subdirectory is always appended, so the package lands at
`<Root>\<name>\` — the resolved path is whatever `add` returns in `data.root`
and `data.artifacts.*`.

`Command` is the full business command (executable + args). If the executable
path contains spaces it MUST be quoted by the caller, e.g.
`-Command '"C:\Program Files\App\app.exe" --flag value'`. Script business
commands (`.ps1` / `.vbs` / `.lnk`) are auto-wrapped with their interpreter by
the packaging layer.

## How to invoke the CLI

技能目录：本文件所在目录，记为 `$SKILL_DIR`。CLI 与本文件同目录（仓库内为指向根目录脚本的硬链接；全局安装为对该技能目录的 junction）。

优先用 **PowerShell 7 (`pwsh`)**（UTF-8 无 BOM 下 Windows PowerShell 5.1 会解析失败）：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "$SKILL_DIR\windows-autostart.ps1" <subcommand> [flags]
```

Every subcommand prints a single JSON object to stdout and exits
`0` (ok) / `1` (error) / `2` (partial). Envelope: `command`, `result`
(`ok|partial|error`), `error`, `data`. Parse stdout, don't guess tables.

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

### 2. register with `add`

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

### 3. diagnose with `status`

```powershell
... status -Name <name>
```

Map `data.diagnosis` to plain language:
- `not_found` → 未注册（可解析，非报错）
- `started` / `started_with_stderr` → 业务已起；err 日志里的应用内告警**不是**失败
- `failed_to_start` → 无日志且任务最近结果码非 0：命令解析/启动失败
- `running` / `not_started` → 运行中 / 尚未观测到运行

Distinguish "command parse failure" (no log + non-zero result) from
"in-app warning" (log present). Report `data.task.runState`, `data.landings.*`,
and `data.log.*Tail` as the observability snapshot.

### 4. remove with `uninstall`

```powershell
... uninstall -Name <name>
```

Read `data.removed` (cleaned), `data.skipped` (exists but not ours — left
alone), `data.absent` (already gone). Idempotent: re-running returns ok. Only
entries owned by this tool are removed (ownership = hidden entry referenced by
the landing spot + manifest in the 封装根目录).

## Out of scope (never do these in this skill)

No Service, no all-users/HKLM/公共 Startup, no default elevation, no
守护/自动拉起 (status is a snapshot only). Reads and interpretations here; every
mutating action goes through the CLI.