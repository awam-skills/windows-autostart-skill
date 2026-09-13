# Delivery shape: Harness skill + PowerShell CLI

To serve both Agent orchestration and repeatable local execution, and to avoid the model assembling `schtasks` / quoting / redirection ad hoc each time, adopt: **Harness skill** for detection, recommendation, and result explanation + this repo’s single PowerShell **CLI** (JSON output; subcommands add / recommend / status / uninstall) as the only write/execution surface — not a docs-only Skill, and not a thin wrap of StartupManager (which does not create Startup shortcuts, has no silent VBS path, and is not JSON).
