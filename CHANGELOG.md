# Changelog

## 0.5.0 — 2026-10-24

Control-plane migration complete (Phases 1–5 on `feat/control-plane-local`).

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

### Phase 5 — Migration & wrap-up
- Removed `litellm-watchdog.vbs` and `\asr-proxy-keepalive`
- Rewrote `migrate-to-scheduled-task.ps1` for control-plane model

## 0.0.1 — earlier

Initial skill + CLI MVP (recommend/add/run/status/uninstall).
