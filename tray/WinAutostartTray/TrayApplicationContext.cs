using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace WinAutostartTray;

/// <summary>
/// NotifyIcon host: starts win-autostart-manager.ps1 serve, opens panel, pause/resume via PAUSE flag, exit via STOP.
/// </summary>
internal sealed class TrayApplicationContext : ApplicationContext
{
    private readonly NotifyIcon _tray;
    private readonly string _repoRoot;
    private readonly string _managerScript;
    private readonly string _managerRoot;
    private readonly int _port;
    private readonly string _listenHost = "127.0.0.1";
    private Process? _managerProcess;
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(3) };
    private bool _exiting;

    public TrayApplicationContext(string[] args)
    {
        _repoRoot = ResolveRepoRoot(args);
        _managerScript = Path.Combine(_repoRoot, "win-autostart-manager.ps1");
        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        _managerRoot = Path.Combine(userProfile, ".win-autostart", "_manager");
        _port = ReadPortOrDefault(_managerRoot, 18765);

        _tray = new NotifyIcon
        {
            Text = "windows-autostart 控制面",
            Icon = SystemIcons.Application,
            Visible = true,
            ContextMenuStrip = BuildMenu()
        };
        _tray.DoubleClick += (_, _) => OpenPanel();

        if (!File.Exists(_managerScript))
        {
            Balloon("找不到 Manager 脚本", _managerScript);
            MessageBox.Show(
                $"未找到 win-autostart-manager.ps1：\n{_managerScript}\n\n请将托盘程序放在仓库根旁，或用 --root 指定仓库目录。",
                "windows-autostart",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            ExitThread();
            return;
        }

        _ = Task.Run(StartManagerAndWaitAsync);
    }

    private ContextMenuStrip BuildMenu()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("打开面板", null, (_, _) => OpenPanel());
        menu.Items.Add("暂停探针与热重载", null, (_, _) => SetPaused(true));
        menu.Items.Add("恢复", null, (_, _) => SetPaused(false));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => RequestExit());
        return menu;
    }

    private static string ResolveRepoRoot(string[] args)
    {
        for (var i = 0; i < args.Length - 1; i++)
        {
            if (args[i] is "--root" or "-Root")
                return Path.GetFullPath(args[i + 1]);
        }

        // Prefer: exe next to published copy that still has sibling scripts,
        // else walk up from AppContext.BaseDirectory looking for manager script,
        // else parent of tray/WinAutostartTray (dev layout).
        var baseDir = AppContext.BaseDirectory;
        var candidates = new[]
        {
            baseDir,
            Path.GetFullPath(Path.Combine(baseDir, "..")),
            Path.GetFullPath(Path.Combine(baseDir, "..", "..", "..", "..")),
            Path.GetFullPath(Path.Combine(baseDir, "..", "..", "..", "..", "..")),
        };
        foreach (var c in candidates)
        {
            var script = Path.Combine(c, "win-autostart-manager.ps1");
            if (File.Exists(script)) return c;
        }
        return Path.GetFullPath(Path.Combine(baseDir, "..", "..", "..", ".."));
    }

    private static int ReadPortOrDefault(string managerRoot, int fallback)
    {
        try
        {
            var path = Path.Combine(managerRoot, "manager.json");
            if (!File.Exists(path)) return fallback;
            var json = File.ReadAllText(path, Encoding.UTF8);
            // Minimal parse without System.Text.Json dependency quirks on older tooling
            var key = "\"port\"";
            var idx = json.IndexOf(key, StringComparison.OrdinalIgnoreCase);
            if (idx < 0) return fallback;
            var colon = json.IndexOf(':', idx + key.Length);
            if (colon < 0) return fallback;
            var end = colon + 1;
            while (end < json.Length && (char.IsWhiteSpace(json[end]) || json[end] == '"')) end++;
            var start = end;
            while (end < json.Length && char.IsDigit(json[end])) end++;
            if (int.TryParse(json.AsSpan(start, end - start), out var port) && port > 0 && port < 65536)
                return port;
        }
        catch { /* ignore */ }
        return fallback;
    }

    private async Task StartManagerAndWaitAsync()
    {
        try
        {
            Directory.CreateDirectory(_managerRoot);
            // Clear stale STOP so serve can run
            var stopFile = Path.Combine(_managerRoot, "STOP");
            if (File.Exists(stopFile))
            {
                try { File.Delete(stopFile); } catch { /* ignore */ }
            }

            if (await HealthOkAsync().ConfigureAwait(false))
            {
                Balloon("面板已就绪", $"Manager 已在运行 http://{_listenHost}:{_port}/");
                return;
            }

            var psi = new ProcessStartInfo
            {
                FileName = FindPowerShell(),
                Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{_managerScript}\" serve",
                WorkingDirectory = _repoRoot,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            _managerProcess = new Process { StartInfo = psi, EnableRaisingEvents = true };
            _managerProcess.Exited += (_, _) =>
            {
                if (!_exiting)
                    Balloon("Manager 已退出", "子进程结束；可从托盘菜单重新打开面板前重启托盘。");
            };
            if (!_managerProcess.Start())
            {
                Balloon("启动失败", "无法启动 PowerShell 子进程");
                return;
            }

            // Wait until health OK or timeout / port conflict
            var deadline = DateTime.UtcNow.AddSeconds(25);
            while (DateTime.UtcNow < deadline && !_exiting)
            {
                if (_managerProcess.HasExited)
                {
                    var code = _managerProcess.ExitCode;
                    var msg = code == 2
                        ? $"端口 {_port} 可能被占用，无法绑定 127.0.0.1:{_port}。请检查 manager.json 或结束占用进程后重试。"
                        : $"Manager 进程异常退出（exit={code}）。请查看 {_managerRoot}\\manager.log";
                    Balloon("端口冲突或启动失败", msg);
                    try
                    {
                        _tray.ShowBalloonTip(8000, "windows-autostart", msg, ToolTipIcon.Error);
                    }
                    catch { /* ignore */ }
                    MessageBox.Show(msg, "windows-autostart 端口冲突", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }

                if (await HealthOkAsync().ConfigureAwait(false))
                {
                    Balloon("面板已就绪", $"http://{_listenHost}:{_port}/");
                    return;
                }
                await Task.Delay(400).ConfigureAwait(false);
            }

            Balloon("等待超时", $"未能在时限内连通 /api/v1/health（端口 {_port}）");
        }
        catch (Exception ex)
        {
            Balloon("启动异常", ex.Message);
            MessageBox.Show(ex.Message, "windows-autostart", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private static string FindPowerShell()
    {
        var sys = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell", "v1.0", "powershell.exe");
        if (File.Exists(sys)) return sys;
        return "powershell.exe";
    }

    private async Task<bool> HealthOkAsync()
    {
        try
        {
            using var resp = await _http.GetAsync($"http://{_listenHost}:{_port}/api/v1/health").ConfigureAwait(false);
            return resp.IsSuccessStatusCode;
        }
        catch
        {
            return false;
        }
    }

    private void OpenPanel()
    {
        var url = $"http://{_listenHost}:{_port}/";
        try
        {
            Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Balloon("无法打开浏览器", ex.Message);
        }
    }

    private void SetPaused(bool paused)
    {
        try
        {
            Directory.CreateDirectory(_managerRoot);
            var pauseFile = Path.Combine(_managerRoot, "PAUSE");
            if (paused)
            {
                File.WriteAllText(pauseFile, DateTime.Now.ToString("o"), Encoding.UTF8);
                Balloon("已暂停", "探针与热重载已暂停（_manager/PAUSE）");
            }
            else
            {
                if (File.Exists(pauseFile)) File.Delete(pauseFile);
                Balloon("已恢复", "探针与热重载已恢复");
            }
        }
        catch (Exception ex)
        {
            Balloon("暂停/恢复失败", ex.Message);
        }
    }

    private void RequestExit()
    {
        if (_exiting) return;
        _exiting = true;
        try
        {
            Directory.CreateDirectory(_managerRoot);
            File.WriteAllText(Path.Combine(_managerRoot, "STOP"), DateTime.Now.ToString("o"), Encoding.UTF8);
        }
        catch { /* ignore */ }

        try
        {
            if (_managerProcess is { HasExited: false })
            {
                // Give serve loop a moment to see STOP
                if (!_managerProcess.WaitForExit(3000))
                {
                    try { _managerProcess.Kill(entireProcessTree: true); } catch { try { _managerProcess.Kill(); } catch { } }
                }
            }
        }
        catch { /* ignore */ }

        _tray.Visible = false;
        _tray.Dispose();
        _http.Dispose();
        ExitThread();
    }

    private void Balloon(string title, string text)
    {
        try
        {
            _tray.BalloonTipTitle = title;
            _tray.BalloonTipText = text;
            _tray.ShowBalloonTip(4000);
        }
        catch { /* ignore */ }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _tray.Dispose();
            _http.Dispose();
            _managerProcess?.Dispose();
        }
        base.Dispose(disposing);
    }
}
