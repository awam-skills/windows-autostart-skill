# Default chain: prefer scheduled task; no silent Startup fallback; hidden entry; never auto-write Run

## Status

Accepted; **amended 2026-10-24**.

## Decision

User-level logon autostart needs diagnosability and minimal console flash. When no landing is specified:

1. Prefer registering a **scheduled task**.
2. On scheduled-task write failure: **stop and report**. Do **not** silently fall back to a Startup shortcut. Explain why the task failed, explain Startup’s weaker keepalive (no task Restart; relaunch mainly on next logon), and only proceed if the caller explicitly retries with `-Landing startup`.
3. Land in exactly one place (no default dual-write).
4. Console-style business commands default through a **hidden entry** (`wscript` + VBS).
5. The registry Run key may be written when explicitly requested, but never enters the automatic default chain.

## Amendment note (2026-10-24)

Earlier wording allowed automatic Startup fallback on task failure. That contradicted the live Harness skill contract and hid keepalive degradation. Silent fallback is withdrawn; confirmation (or explicit `-Landing startup`) is required.

## Consequences

Agents must surface the failure and ask before degrading. Startup remains a supported explicit landing, not a silent default.
