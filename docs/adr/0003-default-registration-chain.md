# Default chain: scheduled task → Startup; hidden entry; never auto-write Run

User-level logon autostart needs fallback, diagnosability, and minimal console flash. When no landing is specified: prefer registering a scheduled task, then fall back to a Startup shortcut on failure, and land in exactly one place (no default dual-write). Console-style business commands default through a hidden entry (`wscript` + VBS). The registry Run key may be written when explicitly requested, but never enters the automatic default chain, to reduce quoting breakage and hard-to-log / hard-to-restart failures.
