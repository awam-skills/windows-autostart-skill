# windows-autostart

当前用户作用域的 Windows **启动项**工具：用 PowerShell CLI 注册登录自启 / 定时执行，可选控制面（Manager）做健康探针与热重载，可选托盘 + 本机 Web 面板管理。

不覆盖：Windows 服务、登录前开机、全机（HKLM / Public Startup）场景。

## 环境要求

| 组件 | 要求 |
|------|------|
| 系统 | Windows 10 / 11 |
| 脚本运行时 | Windows PowerShell **5.1**（自带即可） |
| 可选：托盘编译 | [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) |
| 可选：Agent Skill | 将 `skills/windows-autostart` 装到你的 Agent 技能目录 |

**无安装步骤**：把本仓库目录完整拷到任意路径即可用，不依赖固定盘符。运行时数据写在用户目录，与仓库位置无关。

## 放到别处后怎么启动

假设仓库已放到 `D:\tools\windows-starup-skill`（任意路径均可）。在 **PowerShell** 里先进入该目录：

```powershell
cd D:\tools\windows-starup-skill
```

以下命令均在仓库根目录执行；路径换掉即可，布局不要拆散（`manager\`、`tray\www\` 需与根脚本同仓相对位置）。

### 1. 只注册 / 管理业务启动项（注册面 CLI）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows-autostart.ps1 recommend -Mode logon

powershell -NoProfile -ExecutionPolicy Bypass -File .\windows-autostart.ps1 add `
  -Name my-app `
  -Command '"C:\Path\To\app.exe" --flag' `
  -Mode logon

powershell -NoProfile -ExecutionPolicy Bypass -File .\windows-autostart.ps1 list
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows-autostart.ps1 status -Name my-app
```

stdout 为单个 JSON 信封（`result` = `ok` | `partial` | `error`）。

常用子命令：`recommend` | `add` | `run` | `status` | `uninstall` | `list` | `enable` | `disable` | `stop`。

### 2. 启动控制面（Manager，本机 HTTP）

健康探针、热重载、Web 面板依赖 Manager 常驻：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\win-autostart-manager.ps1 init
powershell -NoProfile -ExecutionPolicy Bypass -File .\win-autostart-manager.ps1 serve
```

浏览器打开：**http://127.0.0.1:18765/**  
（仅绑定本机回环；面板静态文件来自同仓 `tray\www\`。）

停止：在控制台 `Ctrl+C`，或向 `%USERPROFILE%\.win-autostart\_manager\STOP` 写入停止信号。

### 3. 登录后自动拉起 Manager（推荐）

仍在仓库根目录执行（脚本会按**当前仓库绝对路径**写进计划任务，因此换盘后请重新注册）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\register-manager.ps1
# 已存在同名项时：
powershell -NoProfile -ExecutionPolicy Bypass -File .\register-manager.ps1 -Force
```

默认落点为当前用户计划任务；失败时**不会**静默改写 Startup，需按脚本提示确认后改用 `-Landing startup`。

### 4. 可选：托盘宿主

不编译也能用面板（见上文 `serve`）。若要系统托盘：

```powershell
cd tray\WinAutostartTray
dotnet publish -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true `
  -p:IncludeNativeLibrariesForSelfExtract=true `
  -o ..\publish
```

启动（仓库根可任意，建议显式传 `--root`）：

```powershell
.\tray\publish\WinAutostartTray.exe --root "D:\tools\windows-starup-skill"
```

托盘会拉起 `win-autostart-manager.ps1 serve`（或复用已健康的实例），双击打开面板。细节见 [`tray/README.md`](tray/README.md)。

## 数据落在哪里（与仓库路径无关）

| 内容 | 默认路径 |
|------|----------|
| 各启动项封装根 | `%USERPROFILE%\.win-autostart\<name>\` |
| Manager 状态 / 热重载 / 暂停 | `%USERPROFILE%\.win-autostart\_manager\` |

换机器或换仓库路径后：业务包与 Manager 配置仍在用户目录；**计划任务里记录的脚本绝对路径**需用 `register-manager.ps1 -Force` 或对业务项 `add -Force` 重新写一遍。

## Agent Skill

技能说明与编排约定：[`skills/windows-autostart/SKILL.md`](skills/windows-autostart/SKILL.md)。  
领域词汇：[`CONTEXT.md`](CONTEXT.md)。

## 自检（可选）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests-manager.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests-tray-contract.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows-autostart.ps1 list
```

## 版本

见 [`CHANGELOG.md`](CHANGELOG.md)（当前控制面能力对应 **0.5.0**）。
