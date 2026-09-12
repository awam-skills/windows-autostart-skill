# 时机模式：登录与定时互斥；定时仅计划任务

登录自启与定时执行语义不同，且 Startup/Run 无法表达任意时间表。决定一条启动项只选一种时机模式（`logon` | `schedule`）；`schedule` 强制落点为计划任务。首版定时只支持每天某时（DAILY）与每隔 N 分钟（MINUTE）；更复杂的日历规则留到后续。不做登录前 Windows Service / AtStartup，除非未来另开 ADR。
