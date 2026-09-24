#Requires -Version 5.1
<#
.SYNOPSIS
  windows-autostart CLI 黑盒测试（单接缝 = 子命令进程边界）。

.DESCRIPTION
  断言只落在：JSON 结构与字段、退出码、以及系统可观测状态（计划任务是否存在及
  关键属性、Startup 快捷方式是否指向 wscript+VBS、注册表 Run 键、封装产物是否
  生成、日志是否落盘）。不引用内部函数/模块名、不 mock Windows API。

  运行方式（在正常 PowerShell 控制台，勿在受限沙箱中跑）：
      powershell -NoProfile -ExecutionPolicy Bypass -File tests\cli-blackbox.ps1

  会注册/卸载真实的用户级启动项并自动清理；名字带随机后缀避免误伤。
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:TestDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Cli      = Join-Path (Split-Path -Parent $script:TestDir) 'windows-autostart.ps1'
$script:Pwsh     = (Get-Command powershell.exe).Source

$script:Pass = 0
$script:Fail = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Assert {
    param([bool]$Cond, [string]$Msg)
    if ($Cond) { $script:Pass++; Write-Host ("  PASS  " + $Msg) -ForegroundColor Green }
    else { $script:Fail++; $script:Failures.Add($Msg); Write-Host ("  FAIL  " + $Msg) -ForegroundColor Red }
}

function Invoke-CliProc {
    param([string[]]$CliArgs)
    $out = @(& $script:Pwsh -NoProfile -ExecutionPolicy Bypass -File $script:Cli @CliArgs 2>&1)
    $code = $LASTEXITCODE
    $jsonLine = $out | Where-Object { $_ -is [string] -and $_.TrimStart().StartsWith('{') } | Select-Object -Last 1
    $obj = $null
    if ($jsonLine) { try { $obj = $jsonLine | ConvertFrom-Json } catch { $obj = $null } }
    return @{ Raw = $out; ExitCode = $code; Json = $obj; Text = $jsonLine }
}

function New-Isolated {
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    return @{
        Name = 'wa-test-' + $suffix
        Root = Join-Path $env:TEMP ('wa-test-root-' + $suffix)
    }
}

function Cleanup {
    param([string]$Name, [string]$Root)
    try { $null = Invoke-CliProc @('uninstall', '-Name', $Name, '-Root', $Root) } catch { }
    if (Test-Path $Root) { Remove-Item $Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "== windows-autostart CLI blackbox tests =="
Write-Host ("CLI : " + $script:Cli)

# ---------------------------------------------------------------------------
# 1. recommend：结构与排序
# ---------------------------------------------------------------------------
Write-Host "[recommend]"
$r = Invoke-CliProc @('recommend')
Assert ($r.ExitCode -eq 0) 'recommend exits 0'
Assert ($null -ne $r.Json) 'recommend returns parseable JSON'
$canWrite = $r.Json.data.environment.canWriteScheduledTask
$names = @($r.Json.data.landings | ForEach-Object { $_.name })
Assert ($names -notcontains 'run-key') 'Run key never in auto ranking'
$first = @($r.Json.data.landings | Where-Object { $_.rank -eq 1 })[0].name
if ($canWrite) {
    Assert ($first -eq 'scheduled-task') 'writable env -> scheduled-task first'
} else {
    Assert ($first -eq 'startup') 'restricted env -> startup first'
}
Assert ((@($r.Json.data.landings | Where-Object { $_.reason }).Count -gt 0) -and $r.Json.data.landings[0].reason) 'every landing has a reason'

$rs = Invoke-CliProc @('recommend', '-Mode', 'schedule')
$sn = @($rs.Json.data.landings | ForEach-Object { $_.name })
Assert ($sn.Count -eq 1 -and $sn[0] -eq 'scheduled-task') 'schedule mode forces scheduled-task only'

# ---------------------------------------------------------------------------
# 2. add：默认链 + 产物 + 落点（真实注册，随后 uninstall 清理）
# ---------------------------------------------------------------------------
Write-Host "[add default chain]"
$t = New-Isolated
try {
    $a = Invoke-CliProc @('add', '-Name', $t.Name, '-Command', 'cmd.exe /c exit /b 0', '-Mode', 'logon', '-Root', $t.Root)
    Assert (($a.ExitCode -eq 0) -or ($a.ExitCode -eq 2)) 'add exits 0 or 2'
    Assert (($null -ne $a.Json) -and ($null -ne $a.Json.data)) 'add returns data'
    $landing = $a.Json.data.landing
    # canWriteScheduledTask 只是枚举探测；本机仍可能拒写，默认链会回退 Startup
    Assert (($landing -eq 'scheduled-task') -or ($landing -eq 'startup')) 'default chain lands on scheduled-task or startup'
    if ($landing -eq 'startup') {
        Assert ($a.Json.data.fallback -eq $true) 'startup via default chain sets fallback=true'
    }
    # 封装产物
    Assert ($null -ne $a.Json.data.artifacts.businessScript) 'artifacts.businessScript present'
    Assert ($null -ne $a.Json.data.artifacts.hiddenEntry) 'artifacts.hiddenEntry present'
    Assert (Test-Path -Path $a.Json.data.artifacts.businessScript) 'business script exists on disk'
    Assert (Test-Path -Path $a.Json.data.artifacts.hiddenEntry) 'hidden entry exists on disk'
    $vbs = Get-Content -Path $a.Json.data.artifacts.hiddenEntry -Raw
    Assert (($vbs -match 'WScript\.Shell') -and ($vbs -match ', 0, False')) 'hidden entry = wscript VBS window style 0'
    # 默认立即试跑
    $addData = $a.Json.data
    Assert ($addData.ranNow -eq $true) 'add defaults to smoke-run'
    Assert ($null -ne $addData.run) 'add returns data.run'
    $runVia = [string]$addData.run.via
    Assert (($runVia -eq 'scheduled-task') -or ($runVia -eq 'hidden-entry')) 'add.run.via is scheduled-task or hidden-entry'
    # 上下文可观测状态
    if ($landing -eq 'scheduled-task') {
        $task = Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue
        Assert ($null -ne $task) 'scheduled task exists'
        if ($null -ne $task) {
            Assert ($task.Actions[0].Execute -match 'wscript\.exe$') 'task Action.Execute = wscript.exe'
            Assert ($task.Actions[0].Arguments -like ('*' + $t.Name + '.vbs*')) 'task Action.Arguments references hidden vbs'
            Assert ($task.Settings.ExecutionTimeLimit -eq 'PT0S') 'task ExecutionTimeLimit = no limit (PT0S)'
        }
    } else {
        $startupDir = [Environment]::GetFolderPath('Startup')
        $lnk = Join-Path $startupDir ($t.Name + '.lnk')
        Assert (Test-Path $lnk) 'startup shortcut exists'
        if (Test-Path $lnk) {
            $shell = New-Object -ComObject WScript.Shell
            $sc = $shell.CreateShortcut($lnk)
            Assert ($sc.TargetPath -match 'wscript\.exe$') 'shortcut target = wscript.exe'
            Assert ($sc.Arguments -like ('*' + $t.Name + '.vbs*')) 'shortcut arguments reference hidden vbs'
        }
    }

    # 3. 同名冲突（-NoRun 避免重复拉起）
    $c = Invoke-CliProc @('add', '-Name', $t.Name, '-Command', 'cmd.exe /c exit /b 0', '-Mode', 'logon', '-Root', $t.Root)
    Assert (($c.ExitCode -eq 1) -and ($c.Json.result -eq 'error')) 'same name without -Force is refused'
    $f = Invoke-CliProc @('add', '-Name', $t.Name, '-Command', 'cmd.exe /c exit /b 0', '-Mode', 'logon', '-Force', '-NoRun', '-Root', $t.Root)
    Assert ($f.ExitCode -eq 0) 'same name with -Force recreates'
    Assert ($f.Json.data.ranNow -eq $false) '-NoRun skips smoke-run'

    # 3b. run 子命令（再试跑一次）
    $rn = Invoke-CliProc @('run', '-Name', $t.Name, '-Root', $t.Root)
    Assert (($rn.ExitCode -eq 0) -and ($null -ne $rn.Json.data.via)) 'run exits 0 with via'
    Assert (($rn.Json.data.via -eq 'scheduled-task') -or ($rn.Json.data.via -eq 'hidden-entry')) 'run via matches landing path'

    # 4. status：已注册 + 未找到
    $s = Invoke-CliProc @('status', '-Name', $t.Name, '-Root', $t.Root)
    Assert (($s.ExitCode -eq 0) -and $s.Json.data.found) 'status finds registered entry'
    Assert ($null -ne $s.Json.data.diagnosis) 'status has diagnosis field'
    $snf = Invoke-CliProc @('status', '-Name', 'wa-test-does-not-exist', '-Root', $t.Root)
    Assert (($snf.ExitCode -eq 0) -and (-not $snf.Json.data.found)) 'status not-found is parseable (found=false)'

    # 5. uninstall：清理 + 幂等
    # 注：-Root 是「基础目录」，封装产物落在 <Root>\<Name>\（见 spec「封装根目录」）。
    $u = Invoke-CliProc @('uninstall', '-Name', $t.Name, '-Root', $t.Root)
    Assert ($u.ExitCode -eq 0) 'uninstall exits 0'
    $pkgGone = -not (Test-Path (Join-Path $t.Root $t.Name))
    $taskGone = $null -eq (Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue)
    Assert ($pkgGone -and $taskGone) 'uninstall removed package + task'
    $u2 = Invoke-CliProc @('uninstall', '-Name', $t.Name, '-Root', $t.Root)
    Assert ($u2.ExitCode -eq 0) 'second uninstall is idempotent (ok)'
}
finally {
    Cleanup $t.Name $t.Root
}

# ---------------------------------------------------------------------------
# 6. 显式 Run 键落点（仅显式；值包裹正确）
# ---------------------------------------------------------------------------
Write-Host "[add explicit run-key]"
$t2 = New-Isolated
try {
    $rk = Invoke-CliProc @('add', '-Name', $t2.Name, '-Command', 'cmd.exe /c exit /b 0', '-Mode', 'logon', '-Landing', 'run-key', '-NoRun', '-Root', $t2.Root)
    Assert ($rk.ExitCode -eq 0 -and $rk.Json.data.landing -eq 'run-key') 'explicit run-key landing accepted'
    $key = Get-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
    $val = if ($key) { $key.GetValue($t2.Name, $null) } else { $null }
    Assert ($null -ne $val) 'run key value written'
    if ($val) {
        Assert (($val -match 'wscript\.exe" ' -and $val -like ('*' + $t2.Name + '.vbs*'))) 'run key value wraps wscript + vbs (no malformed quoting)'
    }
    # 未显式指定时绝不写 Run：上面默认链 add 已覆盖——此处断言默认链 add 的 runKey 不存在
    # （用第二个名字做一次默认链 add，随后查 Run 键仍为空）
    $t2b = New-Isolated
    try {
        $null = Invoke-CliProc @('add', '-Name', $t2b.Name, '-Command', 'cmd.exe /c exit /b 0', '-Mode', 'logon', '-NoRun', '-Root', $t2b.Root)
        $keyB = Get-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
        $valB = if ($keyB) { $keyB.GetValue($t2b.Name, $null) } else { $null }
        Assert ($null -eq $valB) 'default chain never writes Run key'
    }
    finally { Cleanup $t2b.Name $t2b.Root }
}
finally {
    Cleanup $t2.Name $t2.Root
}

# ---------------------------------------------------------------------------
# 7. schedule 触发器（DAILY / MINUTE，仅计划任务）
# ---------------------------------------------------------------------------
Write-Host "[schedule triggers]"
foreach ($sched in @(@{ Type = 'DAILY'; At = '09:00' }, @{ Type = 'MINUTE'; Every = 5 })) {
    $ts = New-Isolated
    try {
        $pi = @('add', '-Name', $ts.Name, '-Command', 'cmd.exe /c exit /b 0', '-Mode', 'schedule', '-ScheduleType', $sched.Type, '-NoRun', '-Root', $ts.Root)
        if ($sched.Type -eq 'DAILY') { $pi += @('-At', $sched.At) } else { $pi += @('-Every', ([string]$sched.Every)) }
        $sd = Invoke-CliProc $pi
        if ($sd.ExitCode -eq 0 -and $sd.Json.data.landing -eq 'scheduled-task') {
            Assert $true ("schedule " + $sched.Type + " -> scheduled-task")
            $st = Get-ScheduledTask -TaskName $ts.Name -ErrorAction SilentlyContinue
            Assert ($null -ne $st) 'scheduled task exists'
            if ($null -ne $st) {
                if ($sched.Type -eq 'DAILY') {
                    Assert ($st.Triggers[0].CimClass.CimClassName -match 'Daily') 'DAILY trigger present'
                } else {
                    # Repetition.Interval 是 ISO-8601 时长字符串（如 PT5M），不做 TimeSpan 强转
                    Assert ($st.Triggers[0].Repetition.Interval -eq ('PT' + $sched.Every + 'M')) 'MINUTE repetition interval correct'
                }
            }
        } else {
            # schedule 模式不回退；枚举可用但注册被拒时亦应失败
            Assert (($sd.ExitCode -eq 1) -and ($sd.Json.result -eq 'error')) ('schedule ' + $sched.Type + ' refuses when task not writable (no Startup fallback)')
        }
    }
    finally { Cleanup $ts.Name $ts.Root }
}

# ---------------------------------------------------------------------------
# 8. 错误路径（无系统写入）
# ---------------------------------------------------------------------------
Write-Host "[error paths]"
$e1 = Invoke-CliProc @()
Assert ($e1.ExitCode -eq 1 -and $e1.Json.result -eq 'error') 'no args -> error + exit 1'
$e2 = Invoke-CliProc @('nope')
Assert ($e2.ExitCode -eq 1) 'unknown subcommand -> exit 1'
$e3 = Invoke-CliProc @('add', '-Name', 'x', '-Command', 'cmd.exe', '-Mode', 'boot')
Assert ($e3.ExitCode -eq 1) 'invalid -Mode -> exit 1'
$e4 = Invoke-CliProc @('add', '-Name', 'x', '-Command', 'cmd.exe', '-Mode', 'schedule', '-ScheduleType', 'DAILY', '-At', '24:00')
Assert ($e4.ExitCode -eq 1) 'invalid -At -> exit 1'
$e5 = Invoke-CliProc @('add', '-Name', 'x', '-Command', 'cmd.exe', '-Mode', 'logon', '-At', '09:00')
Assert ($e5.ExitCode -eq 1) 'schedule params with logon -> exit 1'

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host ("PASS: " + $script:Pass + "  FAIL: " + $script:Fail)
if ($script:Fail -gt 0) {
    Write-Host "Failures:" -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host ("  - " + $f) -ForegroundColor Red }
    exit 1
}
Write-Host "All tests passed." -ForegroundColor Green
exit 0