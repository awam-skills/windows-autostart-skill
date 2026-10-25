# Changelog

## 0.6.0 — 2026-10-26

### Added
- `stop` now actually ends real business processes: package-marker matches plus
  `exposedPorts` listeners (uv / python / uvicorn style leaves carry no markers),
  expanded into deduped process trees and killed parent-first
  (`Get-ProcessTreeIdOrder`), with the CLI's own PID + ancestor chain protected
- Intent protocol: explicit `stop` writes `desiredEnabled=false` (auto keepalive
  stands down until the next `run` writes `desiredEnabled=true`); explicit
  (`api` / `manual`) manager restarts bypass `desiredEnabled` and cooldown gates
  and reset backoff, automatic (`health` / `watch:*`) restarts stay gated
- Post-restart startup grace window in the health tick: probe failures within
  `max(15s, intervalSec)` after a restart count as `grace`, not failures
- `stop` envelope exposes `ports` / `portPids`

### Fixes
- PS 5.1 kill fallback: `Stop-Process` can fail with Access Denied on some
  token combos while `.NET Process.Kill()` succeeds — `Stop-ProcessTreePid`
  now tries `.Kill()` → `Stop-Process` → `taskkill`
- Health tick no longer leaks `Update-ManagerEntryState` return values into the
  action pipeline (StrictMode `PropertyNotFoundException` in callers)
- UTF-8 BOM added to all repo `.ps1` files: PS 5.1 parses BOM-less UTF-8 with
  Chinese comments as ANSI/GBK, swallowing following ASCII bytes mid-statement

## 0.5.1 — 2026-10-25

### Fixes
- Control-plane self restart/stop no longer suicides without coming back: API restart of `win-autostart-manager` schedules a deferred CLI `run` and exits via `STOP`
- `stop` no longer falls back to killing every process named after the business command host (`powershell` / `python` / …); matches package path markers (and optional `commandLineContains`) instead

## 0.5.0 — 2026-10-24

Control-plane complete (Phases 1–5).

### Phase 1 — Keepalive standard
- Manifest schema `windows-autostart/2` with `keepalive` block
- Scheduled-task baseline: RestartCount 999 / Interval 1 minute

### Phase 2 — CLI management
- `list` / `enable` / `disable` / `stop`
- Shared `_manager/state.json` desiredEnabled

### Phase 3 — Manager Core
- Health loop (TCP/HTTP), watches, restart pipeline
- Localhost HTTP API (`127.0.0.1:18765`)

### Phase 4 — Tray + Web panel
- .NET tray host + Chinese web panel
- Contract tests for panel ↔ API

### Phase 5 — Migration helper & wrap-up
- Rewrote `scripts/migrate-to-scheduled-task.ps1` for control-plane model
  (scheduled-task landing + `taskRestart`; delete package-local `*-watchdog.vbs`)
- Package-external watchdogs are not the recommended keepalive path
- Operator cutover notes stay on the machine (not vendored in this repo)

## 0.0.1 — earlier

Initial skill + CLI MVP (recommend/add/run/status/uninstall).
