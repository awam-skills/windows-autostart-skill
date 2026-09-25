---
name: windows-autostart
description: "Create, inspect, smoke-run, and uninstall current-user Windows logon or scheduled startup entries via windows-autostart.ps1 (JSON). Use for login self-start / 登录自启, DAILY or MINUTE scheduled execution / 定时执行, status diagnosis, or uninstall. Not for Windows services, pre-logon boot, or machine-wide / HKLM / Public Startup."
---

# windows-autostart

Orchestrate user-level Windows startup entries (logon autostart / 登录自启,
scheduled execution / 定时执行) by driving the bundled `windows-autostart.ps1`
CLI. The CLI is the only writer; this skill detects, recommends, interprets, and
explains — it does not register tasks, shortcuts, or registry keys itself.

CLI identity: manifest schema `windows-autostart/1` (no separate `--version`
flag). Subcommands and flags below match the live ParamSpec / unknown-parameter
errors from the packaged script.

## Operating Contract

- Supported environments: Windows current-user session; prefer PowerShell 7
  (`pwsh`). Windows PowerShell 5.1 can parse the script but collapses
  single-element JSON arrays to scalars.
- Required setup: skill directory containing this file and
  `windows-autostart.ps1` (in-repo hard link to repo root; global install may be
  a junction).
- Allowed effects: only through CLI subcommands `add` / `run` / `uninstall`
  (and optional `-Force` / `-Elevate` when the user explicitly requests them).
  `recommend` and `status` are read-only probes.
- Primary observable: each CLI call prints one JSON envelope to stdout
  (`command`, `result`=`ok|partial|error`, `error`, `data`) and exits
  `0` / `1` / `2`.

## Invocation

Skill directory: the directory that contains this file — call it `$SKILL_DIR`.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "$SKILL_DIR\windows-autostart.ps1" <subcommand> [flags]
```

Parse stdout JSON; do not guess from tables. Treat list fields (`removed`,
`skipped`, `absent`, `failed`, `pids`) as "string or array" under Windows
PowerShell 5.1.

## Command Map

| User intent | Command form | Effect | Verification |
|-------------|--------------|--------|--------------|
| Rank landings | `recommend [-Mode logon\|schedule]` | none | `data.landings[]`, `data.environment.canWriteScheduledTask` |
| Register logon entry | `add -Name <n> -Command "<cmd>" -Mode logon [opts]` | writes one landing + package; smoke-runs unless `-NoRun` | `data.landing`, `data.artifacts`, `data.ranNow` / `data.run`, then `status` |
| Register scheduled entry | `add ... -Mode schedule -ScheduleType DAILY -At HH:mm` or `-ScheduleType MINUTE -Every <n>` | scheduled-task only | same as above; landing must be `scheduled-task` |
| Smoke / re-trigger | `run -Name <n>` | starts via landing path | `result`, then `status` |
| Visible diagnose | `run -Name <n> -Visible` | opens business `.cmd` in `cmd /k` | user-visible console + `status` |
| Inspect | `status -Name <n>` | none | `data.diagnosis`, `data.log.*Tail`, `data.landings` |
| Remove | `uninstall -Name <n>` | removes owned landings + package | `data.removed` / `skipped` / `absent` |

`add` optional flags (ParamSpec): `WorkDir`, `Landing`
(`scheduled-task`|`startup`|`run-key`), `-Elevate`, `-Force`, `-NoRun`, `Root`.
`Root` overrides the **base** directory; package lands at `<Root>\<name>\`
(read resolved paths from `data.root` / `data.artifacts.*`).

`Command` is the full business command. If the executable path contains spaces,
the caller must quote it, e.g.
`-Command '"C:\Program Files\App\app.exe" --flag value'`. Script business
commands (`.ps1` / `.vbs` / `.lnk`) are auto-wrapped by the packaging layer.

## Orchestration flow

### 1. Detect + recommend (always first)

```powershell
... recommend [-Mode logon|schedule]
```

Explain `data.landings[].{name,rank,reason}` and
`data.environment.canWriteScheduledTask`. Ordering: scheduled-task first when
writable; otherwise Startup fallback; Run key never auto-ranks. For
`-Mode schedule` the only landing is `scheduled-task` (ADR-0002).

### 2. Register with `add` (default: smoke-run)

```powershell
... add -Name <name> -Command "<business command>" -Mode logon
```

Interpret `data.landing`, `data.artifacts`, and — if `data.fallback` is true —
explain Startup fallback (`data.fallbackReason`).

Smoke-run fields: `data.ranNow` (false only with `-NoRun`), `data.run.via`
(`scheduled-task`|`hidden-entry`), `result=partial` + `data.run.error` when
register succeeded but immediate run failed.

Rules:
- No `-Landing` → default chain: scheduled task → Startup on failure; only ONE
  spot; never Run key (ADR-0003).
- Same name exists → refused without `-Force`; with `-Force` uninstall then
  recreate.
- Do **not** pass `-NoRun` unless the user explicitly asks not to start yet.

### 3. Verify + help fix run problems (required after add)

Always follow a successful or partial `add` with:

```powershell
... status -Name <name>
```

If the business command did not come up cleanly, stay on the CLI:

1. Re-read `status` and log tails under `data.root` / `data.artifacts`.
2. Re-trigger: `run -Name <name>`.
3. If still unclear: `run -Name <name> -Visible`.
4. Fix path / `WorkDir` / args / `-Elevate` / quoting, recreate with `-Force`,
   re-check `status`.

Never improvise `Start-ScheduledTask` / `wscript` / raw `.cmd` — always use
`run` / `status`.

### 4. Diagnose with `status`

Map `data.diagnosis`:
- `not_found` → not registered (ok result, not an error)
- `started` / `started_with_stderr` → process up; err-log warnings are not
  launch failures
- `failed_to_start` → no log + non-zero task last result: parse / launch failure
- `running` / `not_started` → observed / not yet observed

Distinguish command parse failure (no log + non-zero) from in-app warning (log
present). Report `data.task.runState`, `data.landings.*`, and `data.log.*Tail`.

### 5. Remove with `uninstall`

```powershell
... uninstall -Name <name>
```

Read `data.removed`, `data.skipped` (exists but not ours), `data.absent`.
Idempotent. Only owned entries are removed (hidden entry referenced by the
landing + manifest under the package root).

## Out of scope

No Service, no all-users / HKLM / Public Startup, no default elevation, no
daemon / auto-relaunch (`status` is a snapshot). Mutating actions go only through
the CLI.

## Verified Gotchas

- Prefer `pwsh`: Windows PowerShell 5.1 fails to parse UTF-8 scripts without BOM
  and collapses single-element JSON arrays.
- There is no `-?` / `--help` subcommand; unknown flags return JSON
  `error` listing supported parameter names — use that as the live contract.
- Spaces in executable paths require caller-supplied quotes inside `-Command`.

## Completion Gate

Done when: every CLI form used matches the ParamSpec above; JSON `result` was
parsed (not guessed); after `add`, `status` was run and explained; any mutation
went through the CLI; out-of-scope requests were declined without improvising
machine-wide or service landings.
