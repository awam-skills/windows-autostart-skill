# Changelog

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
