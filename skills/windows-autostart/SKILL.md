---
name: windows-autostart
version: 0.5.0
description: "Create, inspect, smoke-run, and uninstall current-user Windows logon or scheduled startup entries via windows-autostart.ps1 (JSON). Use for login self-start / 登录自启, DAILY or MINUTE scheduled execution / 定时执行, status diagnosis, or uninstall. Not for Windows services, pre-logon boot, or machine-wide / HKLM / Public Startup."
---

# windows-autostart

Orchestrate user-level Windows startup entries (logon autostart / 登录自启,
scheduled execution / 定时执行) by driving the bundled `windows-autostart.ps1`
CLI. The CLI is the only writer; this skill detects, recommends, interprets, and
explains — it does not register tasks, shortcuts, or registry keys itself.

CLI identity: manifest schema `windows-autostart/2` (reads v1) (no separate `--version`
flag). Subcommands and flags below match the live ParamSpec / unknown-parameter
errors from the packaged script.

## Operating Contract

- Supported environments: Windows current-user session; prefer PowerShell 7
  (`pwsh`). Windows PowerShell 5.1 can parse the script but collapses
  single-element JSON arrays to scalars.
- Required setup: skill directory containing this file and
  `windows-autostart.ps1` (in-repo hard link to repo root; global install may be
  a junction).
- Allowed effects: only through CLI subcommands `add` / `run` / `uninstall` /
  `enable` / `disable` / `stop` (and optional `-Force` / `-Elevate` when the user
  explicitly requests them). `recommend`, `status`, and `list` are read-only probes.
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
| Inspect | `status -Name <n>` | none | `data.diagnosis`, `data.enabled`, `data.desiredEnabled`, `data.log.*Tail`, `data.landings` |
| List | `list [-Root <parent>]` | none | `data.entries[]` (`name`,`landing`,`mode`,`enabled`,`schema`,`root`) |
| Enable / disable | `enable` / `disable -Name <n>` | toggles landing + state intent | `data.enabled`, `data.desiredEnabled` |
| Stop (keep registration) | `stop -Name <n>` | ends process / task run | `data.stoppedPids`, `data.taskStopped` |
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
- No `-Landing` → default chain: try scheduled task first; on failure,
  **stop and report** — do NOT silently fall back to Startup. Tell the user why
  scheduled-task failed, explain the impact of degrading to Startup (no crash
  auto-restart; only relaunched on next logon), and ask whether to retry with
  `-Landing startup`. Only ONE landing; never Run key (ADR-0003).
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


## Management commands (Phase 2) & control plane

Registration plane CLI now includes inventory/control helpers. A **control plane (Manager)** still owns health probes, file-watch hot reload, tray + localhost Web UI (Phase 3–4). See design.md / ADR-0005 / ADR-0006.

| Intent | Command form | Effect |
|--------|--------------|--------|
| List all entries | `list [-Root <parent>]` | read-only scan of package parent (default `~\.win-autostart`, skips `_manager`) → `data.entries[]` |
| Enable | `enable -Name <n> [-Root]` | enable landing; writes `desiredEnabled=true` to `~\.win-autostart\_manager\state.json` |
| Disable | `disable -Name <n> [-Root]` | disable landing; writes `desiredEnabled=false` (does not uninstall) |
| Stop process | `stop -Name <n> [-Root]` | end business process / Stop-ScheduledTask; **does not** disable |
| Inspect (enhanced) | `status -Name <n>` | also `data.enabled`, `data.desiredEnabled`, `data.manager` |

Never invent package-local `*-watchdog.vbs` as the recommended keepalive path (Manager Phase 3+).

## Manager Core (Phase 3)

Control-plane console host (no tray UI yet): `win-autostart-manager.ps1` + `manager/` modules.

Config under `~\.win-autostart\_manager\`:
- `manager.json` — schema `windows-autostart-manager/1` (listen `127.0.0.1`, port `18765`, cooldown/backoff, optional `token`)
- `watches.json` — schema `windows-autostart-watches/1` (debounceMs + items[])
- `state.json` — shared with CLI; manager merges runtime fields (`consecutiveHealthFailures`, `lastRestartAt`, `lastHealthOkAt`, `lastWatchFireAt`) without wiping `desiredEnabled`
- `manager.log` — append-only control-plane log

### Run

```powershell
# Ensure defaults
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL_DIR\win-autostart-manager.ps1" init

# Serve (HTTP + health + watches) until Ctrl+C or _manager\STOP
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL_DIR\win-autostart-manager.ps1" serve

# Optional: -DryRun / env WIN_AUTOSTART_MANAGER_DRYRUN=1 → restart intents to test-restarts.jsonl
# Optional: once-health / once-watch for tests
```

Self-register at logon (scheduled-task; **no silent Startup fallback** — ADR-0003):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL_DIR\register-manager.ps1"
```

### HTTP API smoke (`127.0.0.1` only)

```bash
curl -s http://127.0.0.1:18765/api/v1/health
curl -s http://127.0.0.1:18765/api/v1/entries
curl -s -X POST http://127.0.0.1:18765/api/v1/entries/<name>/restart
curl -s http://127.0.0.1:18765/api/v1/watches
```

If `manager.json` sets `token`, send header `X-Win-Autostart-Token: <token>`.

### Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL_DIR\tests-manager.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL_DIR\tests-tray-contract.ps1"
```

Health/watch respect `desiredEnabled=false` (skip restart). Prefer Manager over package-local `*-watchdog.vbs`.

## Phase 4 — Tray + Web panel

Human operators use the localhost panel; agents still prefer CLI.

### Run panel without tray

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL_DIR\win-autostart-manager.ps1" serve
# Open http://127.0.0.1:18765/  (static files from tray/www)
```

### Tray host (.NET 8 WinForms)

Build on Windows (see `tray/README.md`):

```powershell
cd "$SKILL_DIR\tray\WinAutostartTray"
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o ..\publish
..\publish\WinAutostartTray.exe --root "$SKILL_DIR"
```

Tray menu (Chinese): 打开面板 / 暂停探针与热重载 / 恢复 / 退出.  
Pause writes `%USERPROFILE%\.win-autostart\_manager\PAUSE` (health + watch skip restarts).  
Exit writes `STOP` and stops Manager only (business entries keep running).

### Extra API (Phase 4)

| Method | Path | Notes |
|--------|------|-------|
| GET/PUT | `/api/v1/entries/{name}/keepalive` | Read/write manifest.keepalive |
| POST | `/api/v1/pause` | Create PAUSE flag |
| POST | `/api/v1/pause/resume` | Clear PAUSE |
| GET | `/` | Static panel (`tray/www`) |

### Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL_DIR\tests-tray-contract.ps1"
```

Manual checklist (Chinese): `docs/manual-acceptance-phase4.md`.

## Out of scope

No Service, no all-users / HKLM / Public Startup, no default elevation.
Registration CLI does not daemonize; continuous health/watch belongs to the
Manager Core + tray/Web panel (Phase 3–4; ADR-0005 / ADR-0006). `status` remains a snapshot; continuous
health/watch run in `win-autostart-manager.ps1` (optionally hosted by the tray). Mutating registration
actions still go through the CLI (or Manager HTTP which calls the CLI).

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

## Phase 5 - Migration & wrap-up

Package-external watchdogs are **not** the recommended keepalive path.

Migration helper (control-plane aligned):

```powershell
# Prefer elevated when rewriting tasks
powershell -NoProfile -ExecutionPolicy Bypass -File "$SKILL_DIR\scripts\migrate-to-scheduled-task.ps1"
# Live copy may also exist at ~\.win-autostart\migrate-to-scheduled-task.ps1
```

What migration does:
1. Ensure Scheduled Task landing + RestartCount 999 / Interval 1min
2. Upgrade manifest to `windows-autostart/2`, `landing=scheduled-task`, `keepalive.taskRestart=true`
3. Delete per-package `*-watchdog.vbs` and Startup watchdog shortcuts
4. Does **not** create new package-local watchdogs — configure Manager `process` / `health` and `~\.win-autostart\_manager\watches.json` instead

Machine-specific cutover notes (which packages were moved on a given host) belong outside this repo; keep only the helper script and skill/CLI contracts here.

CHANGELOG: repo-root `CHANGELOG.md` (0.5.0).

