# 托盘宿主 + Web 面板（Phase 4）

架构：**托盘（.NET）启动 Manager Core（PowerShell）**；Manager 在 `127.0.0.1:18765` 提供 `/api/v1/*`，并托管静态面板 `tray/www/`。

## 依赖

| 组件 | 要求 |
|------|------|
| 运行时（日常） | Windows 10/11；Windows PowerShell 5.1（Manager） |
| 编译托盘 | [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)（Windows） |
| 面板 | 任意现代浏览器；无需 Node 构建 |

本仓库在 Linux CI/沙箱中**不能**编译 WinForms；请在 Windows 上 publish。

## 目录

```
tray/
  www/                 # 静态面板（由 Manager HttpApi 托管）
    index.html
    assets/app.css
    assets/app.js
  WinAutostartTray/    # .NET 8 WinForms NotifyIcon
  README.md
```

## 不编译托盘也能用面板

```powershell
cd <repo>
powershell -NoProfile -ExecutionPolicy Bypass -File .\win-autostart-manager.ps1 serve
# 浏览器打开 http://127.0.0.1:18765/
```

Manager 会自动发现 `tray/www`（与 `win-autostart-manager.ps1` 同级）。

## 编译与单文件发布

在 **Windows** 上：

```powershell
cd tray\WinAutostartTray
dotnet restore
dotnet build -c Release

# 单文件自包含（约数十 MB，免安装运行时）
dotnet publish -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true `
  -p:IncludeNativeLibrariesForSelfExtract=true `
  -o ..\publish
```

将 `publish\WinAutostartTray.exe` 与仓库脚本放在同一布局下使用，或启动时传参：

```powershell
.\WinAutostartTray.exe --root "G:\path\to\win-autostart-src"
```

托盘会：

1. 启动 `win-autostart-manager.ps1 serve` 子进程（若 health 已通则复用）
2. 等待 `GET /api/v1/health` 成功
3. 双击托盘 /「打开面板」→ 浏览器 `http://127.0.0.1:<port>/`
4. 「暂停探针与热重载」→ 写入 `%USERPROFILE%\.win-autostart\_manager\PAUSE`
5. 「恢复」→ 删除 `PAUSE`
6. 「退出」→ 写入 `STOP`，必要时结束子进程（**不**停止业务启动项）

端口冲突（绑定失败 exit 2）：气球提示 + 对话框说明占用。

## 面板功能

- **启动项清单**：start / stop / restart / enable / disable
- **条目详情**：status JSON；编辑 keepalive（GET/PUT `/api/v1/entries/{name}/keepalive`）
- **热重载**：list / add / delete watches
- 面板内也可暂停/恢复（`POST /api/v1/pause`、`/pause/resume`）

## 登录自启

仍用注册面把 Manager（或托盘 exe）登记为 `win-autostart-manager`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\register-manager.ps1
```

若改为托盘 exe 自启，将 `register-manager.ps1` 中的 `-Command` 换成发布后的 `WinAutostartTray.exe` 路径即可（勿静默回退 Startup — ADR-0003）。
