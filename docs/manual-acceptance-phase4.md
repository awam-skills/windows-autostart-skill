# Phase 4 手工验收清单（托盘 + Web 面板）

> 环境：Windows 当前用户；Manager / 托盘仅绑定 `127.0.0.1`。  
> 日期栏可由验收人填写。

## 前置

- [ ] 仓库含 `win-autostart-manager.ps1`、`manager\`、`tray\www\`
- [ ] （可选）已用 .NET 8 SDK 发布 `tray\publish\WinAutostartTray.exe`
- [ ] 至少有一条业务启动项，或用 CLI `add` 建一条测试项

## A. 仅 Manager + 浏览器（无托盘也可验收面板）

| # | 步骤 | 期望 | 通过 |
|---|------|------|------|
| A1 | `powershell -NoProfile -ExecutionPolicy Bypass -File .\win-autostart-manager.ps1 serve` | 控制台打印 panel/API URL；无报错退出 | ☐ |
| A2 | 浏览器打开 `http://127.0.0.1:18765/` | 看到中文标题「控制面板」、清单页 | ☐ |
| A3 | `curl http://127.0.0.1:18765/api/v1/health` | JSON `ok:true`，含 `paused` | ☐ |
| A4 | 清单页显示条目；对测试项点「启动/停止/重启/启用/禁用」 | 按钮有响应；状态可刷新 | ☐ |
| A5 | 条目详情：加载 status JSON；修改 keepalive 保存 | PUT 成功；重开详情字段保留 | ☐ |
| A6 | 热重载页：新增一条 watch → 列表可见 → 删除 | CRUD 成功 | ☐ |
| A7 | 点「暂停探针与热重载」 | health 显示已暂停；`_manager\PAUSE` 存在 | ☐ |
| A8 | 点「恢复」 | PAUSE 消失；徽章恢复「运行中」 | ☐ |
| A9 | 故意占用 18765 后再 `serve` | 清晰报错（端口占用 / URLACL）；进程 exit 非 0 | ☐ |

## B. 托盘宿主

| # | 步骤 | 期望 | 通过 |
|---|------|------|------|
| B1 | 运行 `WinAutostartTray.exe`（或 `--root <仓库>`） | 托盘图标出现；气球「面板已就绪」或复用已有 Manager | ☐ |
| B2 | 菜单「打开面板」/ 双击 | 浏览器打开面板 | ☐ |
| B3 | 「暂停探针与热重载」 | 写入 PAUSE；面板徽章同步 | ☐ |
| B4 | 「恢复」 | 清除 PAUSE | ☐ |
| B5 | 「退出」 | 写入 STOP；托盘消失；Manager 子进程结束；**业务条目仍在** | ☐ |
| B6 | 端口已被占用时启动托盘 | 气球/对话框明确提示端口冲突 | ☐ |

## C. 契约测试（无 GUI）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests-manager.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests-tray-contract.ps1
```

- [ ] `tests-manager.ps1` 全部 PASS  
- [ ] `tests-tray-contract.ps1` 全部 PASS  

## 非目标（本阶段不验收）

- 非 localhost 访问、跨机器管理  
- GUI 自动化 / UI 像素级测试  
- 业务包迁移（属 Phase 5）

## 签字

| 角色 | 姓名 | 日期（Asia/Shanghai） |
|------|------|------------------------|
| 验收 |  |  |
