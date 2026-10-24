# Tray host as localhost server plus Web panel

## Status

Accepted (2026-10-24).

## Context

Operators need a list and controls for startup entries. A CLI alone is enough for agents; humans need a small UI. Binding beyond the current user or exposing a LAN port is out of scope (ADR-0004).

## Decision

1. Ship a **tray application** that hosts the control-plane HTTP API (prefer .NET single-file publish).
2. Serve a **Web panel** on `127.0.0.1` only (default port configurable in `manager.json`, e.g. 18765).
3. Tray menu: open panel, pause all probes/watches, exit Manager (does not stop business entries by default).
4. Register the Manager itself as a win-autostart logon entry (`win-autostart-manager`).
5. UI never writes Task Scheduler / Startup / Run directly; it calls control-plane APIs which call the registration CLI or Task APIs.

## Consequences

- Phase 4 deliverable; API surface is defined in the design doc and may land in Phase 3 without UI.
- No non-localhost bind in v1.
