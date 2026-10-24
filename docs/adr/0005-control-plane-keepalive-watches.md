# Control plane, keepalive tiers, and unified watches

## Status

Accepted (2026-10-24). Implements the approved control-plane design.

## Context

MVP scoped the CLI to register / status / uninstall and treated process daemons and continuous health checks as out of scope. Real usage (e.g. ad-hoc `litellm-watchdog.vbs`) showed keepalive and management need a first-class home without stuffing a watchdog into every package.

## Decision

1. **Two planes.** Registration plane remains `windows-autostart.ps1` (package + landing). A **control plane (Manager)** owns inventory aggregation, start/stop/enable/disable, health probes, and file-watch hot reload. UI talks only to the control plane.
2. **Keepalive tiers.** `task-restart` is mandatory for scheduled-task landings (RestartCount/Interval constants in one place). Optional `process` and `health` (TCP/HTTP) run in the Manager, configured on manifest `windows-autostart/2` `keepalive` blocks. Optional `watch` is development hot reload, not a production substitute for task-restart.
3. **Unified watches.** Paths (may be outside the package) are registered in `~\.win-autostart\_manager\watches.json` and mapped to entry `targets`; Manager debounces and dispatches restart. Do not ship per-entry VBS watchers as the recommended path.
4. **Disable respects.** User `stop` / `disable` skips health and watch restarts until enable/start.

## Consequences

- MVP “no daemon” out-of-scope is narrowed: registration plane still does not daemonize; control plane does.
- Package-local watchdog scripts are deprecated for new work; migrate existing ones into Manager config.
- See `docs/superpowers/specs/2026-10-24-control-plane-design.md`.
