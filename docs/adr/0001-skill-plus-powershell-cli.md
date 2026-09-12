# 交付形态：Harness 技能 + PowerShell CLI

要同时服务 Agent 编排与本机可重复执行，且避免每次由模型现场拼装 `schtasks`/引号/重定向。决定采用「Harness 技能负责检测、推荐与解释结果 + 本仓库单一 PowerShell CLI（JSON 输出，子命令 add/recommend/status/uninstall）作为唯一写入执行面」，而不是纯文档 Skill，也不是仅封装 StartupManager（其不建 Startup、无静默 VBS、非 JSON）。
