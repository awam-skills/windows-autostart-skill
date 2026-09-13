# Windows Startup Entry Harness

Skill and companion CLI for creating, recommending, verifying, and uninstalling current-user Windows startup entries. Covers logon autostart and scheduled execution via Task Scheduler; does not cover pre-logon boot services.

## Language

**Startup entry** (启动项):
A registered, persistent configuration that launches a **business command** at an agreed timing (includes landing metadata and optional packaging artifacts).
_Avoid_: 自启动, 开机项, persistence (generic security sense)

**Business command** (业务命令):
The executable plus arguments the user actually wants to run (the external entry point). Scripts and shortcuts are wrapped internally into interpreter invocations before being written to a landing.
_Avoid_: target program, payload, entry command (when that would confuse with the hidden entry)

**Landing** (落点):
The concrete mechanism where a startup entry is written: scheduled task, Startup-folder shortcut, or registry Run key, among others.
_Avoid_: backend, storage, channel

**Recommendation engine** (推荐引擎):
Ranks landings and gives reasons from environment checks (permissions, policy, whether a scheduled task can be written, etc.). When the user does not specify a landing, the **default chain** applies.
_Avoid_: wizard, policy engine

**Default chain** (默认链):
For logon autostart with no landing specified: prefer scheduled task → on failure, Startup shortcut; default via **hidden entry**; do not write the Run key by default.
_Avoid_: Hermes scheme (implementation nickname, not a domain name)

**Hidden entry** (隐藏入口):
Launch the business script with `wscript` + VBS (window style 0) so logon does not flash a console and CTRL_CLOSE_EVENT does not tear the process down.
_Avoid_: silent wrapper, launcher (too vague)

**Logon autostart** (登录自启):
Timing that fires after the user logs on (scheduled task AtLogOn, Startup folder, Run key).
_Avoid_: 开机自启 (easy to confuse with pre-logon boot)

**Scheduled execution** (定时执行):
Time-based triggers on the scheduled-task landing only. v1 supports once per day at a clock time (DAILY) and every N minutes (MINUTE). Mutually exclusive with logon autostart: one startup entry uses exactly one timing mode.
_Avoid_: cron (not a native Windows name), scheduling (too vague)

**Timing mode** (时机模式):
Trigger category when creating a startup entry: `logon` (logon autostart) or `schedule` (scheduled execution). Choose one; do not stack both on the same startup entry.
_Avoid_: trigger combination, mixed triggers

**Elevated run** (提权运行):
Run the scheduled task at Highest (avoid repeated UAC). Off by default; requires an explicit switch. Default is always user-level Limited.
_Avoid_: admin mode, UAC bypass

**CLI**:
This repo’s single PowerShell entry point, driven by subcommands (including recommend / add / status / uninstall). Stdout is primarily JSON for the Harness skill to parse.
_Avoid_: StartupManager (external reference tool), module (unless specifically this entry point)

**Harness skill** (Harness 技能):
This repo’s Agent Skill (`windows-autostart`): orchestrates detection, recommendation, CLI calls, and result explanation. It is not the sole execution surface by itself.
_Avoid_: docs-only skill, plugin

**Package root** (封装根目录):
Directory that holds a startup entry’s business script, hidden entry, logs, and related artifacts. Default `%USERPROFILE%\.win-autostart\<name>\`; overridable.
_Avoid_: install directory, data directory (too vague)

**Current-user scope** (当前用户作用域):
v1 landings apply only to the current logged-on user. No all-users / HKLM / Public Startup.
_Avoid_: machine-wide, system-wide

**Force overwrite** (强制覆盖):
If a startup entry with the same name already exists, creation is refused by default. Only with explicit `--force` does the tool uninstall then reinstall.
_Avoid_: update, upsert (unless force is meant)
