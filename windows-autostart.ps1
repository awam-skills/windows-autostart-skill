#Requires -Version 5.1
<#
.SYNOPSIS
  windows-autostart — Windows 用户态启动项 CLI（单一 PowerShell 入口）。

.DESCRIPTION
  子命令：recommend | add | run | status | uninstall | list | enable | disable | stop
  标准输出：单个 JSON 对象（信封契约，见下）。
  退出码：0 = 成功(ok)；1 = 失败(error)；2 = 部分失败(partial)。

  JSON 信封契约（所有子命令一致）：
    command  : 子命令名（无子命令时为 null）
    result   : "ok" | "partial" | "error"
    error    : result != "ok" 时的错误信息，否则 null
    data     : 子命令专有字段（对象）

  领域命名以 CONTEXT.md 词汇表为准（业务命令、落点、时机模式、隐藏入口、当前用户作用域…）。
  实现约束见 .scratch/windows-autostart/spec.md 与 docs/adr/0001–0004。

  注：Windows PowerShell 5.1 的 ConvertTo-Json 会把单元素数组塌缩为标量，
      消费方（Agent/Harness 技能）应把列表字段按「字符串或数组」容错处理。
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:SubCommands = @('recommend', 'add', 'run', 'status', 'uninstall', 'list', 'enable', 'disable', 'stop')

# --- 领域常量 ---------------------------------------------------------------
$script:ManifestSchema   = 'windows-autostart/2'
$script:ManifestSchemasAccepted = @('windows-autostart/1', 'windows-autostart/2')
# Keepalive baseline for scheduled-task landings (ADR-0005 / phase 1). Do not scatter magic numbers.
$script:TaskRestartCount = 999
$script:TaskRestartIntervalMinutes = 1
$script:WscriptPath      = Join-Path $env:SystemRoot 'System32\wscript.exe'
$script:PowerShellExe    = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:CmdExe           = Join-Path $env:SystemRoot 'System32\cmd.exe'
$script:RunKeyPath       = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

# 参数规格：名 -> 类型。类型：string | switch | int(正整数) | enum:v1|v2
# add 系列的完整契约见 spec「CLI 输入契约（add）」。status/uninstall/run 增加 Root
# 以对称支持自定义封装根目录（issue 09「与 add 对称」）。
# add smoke-runs by default after register; pass -NoRun to skip. run -Visible opens a visible console for diagnosis.
$script:ParamSpec = @{
    'recommend' = @{
        Mode = 'enum:logon|schedule'
    }
    'add' = @{
        Name         = 'string'
        Command      = 'string'
        WorkDir      = 'string'
        Mode         = 'enum:logon|schedule'
        ScheduleType = 'enum:DAILY|MINUTE'
        At           = 'string'
        Every        = 'int'
        Landing      = 'enum:scheduled-task|startup|run-key'
        Elevate      = 'switch'
        Force        = 'switch'
        NoRun        = 'switch'
        Root         = 'string'
    }
    'run' = @{
        Name    = 'string'
        Root    = 'string'
        Visible = 'switch'
    }
    'status' = @{
        Name = 'string'
        Root = 'string'
    }
    'uninstall' = @{
        Name  = 'string'
        Root  = 'string'
        Force = 'switch'
    }
    'list' = @{
        Root = 'string'
    }
    'enable' = @{
        Name = 'string'
        Root = 'string'
    }
    'disable' = @{
        Name = 'string'
        Root = 'string'
    }
    'stop' = @{
        Name = 'string'
        Root = 'string'
    }
}

# 必填参数（按子命令）。
$script:RequiredParams = @{
    'add'       = @('Name', 'Command', 'Mode')
    'run'       = @('Name')
    'status'    = @('Name')
    'uninstall' = @('Name')
    'enable'    = @('Name')
    'disable'   = @('Name')
    'stop'      = @('Name')
}

# =============================================================================
# 基础参数解析（承自 issue 01，保持已验证的实现不变）
# =============================================================================

function Test-PositiveInt {
    param([string]$Value)
    if ($Value -notmatch '^\d+$') { return $false }
    $n = [int]$Value
    return ($n -gt 0)
}

function ConvertFrom-CliArgs {
    param([string]$Sub, [string[]]$ArgList)

    $spec = $script:ParamSpec[$Sub]
    $parsed = @{}
    $i = 0
    while ($i -lt $ArgList.Count) {
        $tok = $ArgList[$i]
        if ($tok -notmatch '^-') {
            throw "unexpected positional argument '$tok' for subcommand '$Sub' (use named flags)"
        }
        $name = $tok.TrimStart('-')
        if (-not $spec.ContainsKey($name)) {
            $known = @($spec.Keys) -join '|'
            throw "unknown parameter '-$name' for subcommand '$Sub' (supported: $known)"
        }
        $type = $spec[$name]
        if ($type -eq 'switch') {
            $parsed[$name] = $true
            $i++
            continue
        }
        if ($i + 1 -ge $ArgList.Count) {
            throw "parameter '-$name' requires a value"
        }
        $val = $ArgList[$i + 1]
        if ($type -like 'enum:*') {
            $allowed = $type.Substring(5) -split '\|'
            if ($val -notin $allowed) {
                throw "invalid value '$val' for '-$name' (expected one of: $($allowed -join '|'))"
            }
        }
        elseif ($type -eq 'int') {
            if (-not (Test-PositiveInt $val)) {
                throw "invalid value '$val' for '-$name' (expected a positive integer)"
            }
            $val = [int]$val
        }
        $parsed[$name] = $val
        $i += 2
    }
    return $parsed
}

# =============================================================================
# 通用助手：路径 / 命令解析 / 引用
# =============================================================================

function Resolve-RootDir {
    <# 封装根目录：<RootOverride 或 %USERPROFILE%\.win-autostart>\<名称> #>
    param([string]$Name, [string]$RootOverride)
    if ($RootOverride) {
        return (Join-Path -Path $RootOverride -ChildPath $Name)
    }
    return (Join-Path -Path (Join-Path $env:USERPROFILE '.win-autostart') -ChildPath $Name)
}

function Get-ExeAndRest {
    <# 把「可执行 + 参数」拆成可执行（去外层引号）与原始参数串（保留内部引号）。 #>
    param([string]$Command)
    $cmd = $Command.Trim()
    $n = $cmd.Length
    $i = 0
    $inQuote = $false
    while ($i -lt $n) {
        $c = $cmd[$i]
        if ($c -eq '"') { $inQuote = -not $inQuote; $i++; continue }
        if ($c -eq ' ' -and -not $inQuote) { break }
        $i++
    }
    $exeRaw = $cmd.Substring(0, $i).Trim()
    $rest = ''
    if ($i -lt $n) { $rest = $cmd.Substring($i + 1).Trim() }
    return @{ Exe = $exeRaw.Trim('"'); Rest = $rest }
}

function Quote-Path {
    param([string]$P)
    return '"' + $P + '"'
}

function Quote-Exe {
    <# 只在含空格/元字符时加引号，裸命令名（如 dsh）保持裸写以免破坏 PATH 解析。 #>
    param([string]$E)
    if ($E -match '[\s&|()<>^"]') {
        return '"' + ($E -replace '"', '') + '"'
    }
    return $E
}

function Quote-Vbs {
    param([string]$P)
    return '"""' + $P + '"""'
}

function Test-TimeString {
    param([string]$T)
    if ($T -notmatch '^\d{1,2}:\d{2}$') { return $false }
    $parts = $T -split ':'
    $h = [int]$parts[0]
    $m = [int]$parts[1]
    return (($h -ge 0 -and $h -le 23) -and ($m -ge 0 -and $m -le 59))
}

# =============================================================================
# 封装层（issue 03）：业务脚本 + 隐藏入口 + 清单
# =============================================================================

function Write-BusinessScript {
    param([string]$Name, [string]$Command, [string]$WorkDir, [string]$RootPath, [string]$OutLog, [string]$ErrLog)

    $res = Get-ExeAndRest $Command
    $exe = $res['Exe']
    $rest = $res['Rest']
    $ext = [System.IO.Path]::GetExtension($exe).ToLowerInvariant()

    $invoke = $null
    if ($ext -eq '.ps1') {
        # 脚本类命令：解释器包装（计划任务 CreateProcess 不走文件关联）
        $invoke = (Quote-Exe $script:PowerShellExe) + ' -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File ' + (Quote-Path $exe)
    }
    elseif ($ext -eq '.vbs') {
        $invoke = (Quote-Exe $script:WscriptPath) + ' //nologo ' + (Quote-Path $exe)
    }
    elseif ($ext -eq '.lnk') {
        $invoke = (Quote-Exe $script:CmdExe) + ' /c start "" ' + (Quote-Path $exe)
    }
    else {
        # .exe / .com / .cmd / .bat / 裸命令名：原样执行
        $invoke = Quote-Exe $exe
    }
    if ($rest) { $invoke += ' ' + $rest }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('@echo off')
    $lines.Add('rem windows-autostart business script for ' + $Name)
    if ($WorkDir) {
        $lines.Add('cd /d ' + (Quote-Path $WorkDir))
    }
    # 日志重定向写在业务脚本内部（避免落点 Arguments 内联 cmd /c 引号畸形）
    $lines.Add($invoke + ' >> ' + (Quote-Path $OutLog) + ' 2>> ' + (Quote-Path $ErrLog))
    $lines.Add('exit /b 0')

    $body = ($lines -join "`r`n") + "`r`n"
    $cmdPath = Join-Path $RootPath ($Name + '.cmd')
    Set-Content -Path $cmdPath -Value $body -Encoding ASCII
    return $cmdPath
}

function Write-HiddenEntry {
    param([string]$Name, [string]$CmdPath, [string]$RootPath)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("' windows-autostart hidden entry for $Name")
    $lines.Add("' Launches the business script with window style 0 (hidden) to avoid a console flash.")
    $lines.Add('Set sh = CreateObject("WScript.Shell")')
    $lines.Add('sh.Run ' + (Quote-Vbs $CmdPath) + ', 0, False')

    $body = ($lines -join "`r`n") + "`r`n"
    $vbsPath = Join-Path $RootPath ($Name + '.vbs')
    Set-Content -Path $vbsPath -Value $body -Encoding ASCII
    return $vbsPath
}

function Get-DefaultKeepalive {
    param([string]$Landing)
    $taskRestart = ($Landing -eq 'scheduled-task')
    return [ordered]@{
        taskRestart = $taskRestart
        process     = [ordered]@{
            enabled              = $false
            imageName            = $null
            commandLineContains  = $null
        }
        health      = [ordered]@{
            enabled           = $false
            intervalSec       = 30
            failureThreshold  = 3
            tcpPorts          = @()
            http              = $null
        }
    }
}

function Normalize-Manifest {
    param($Obj)
    if ($null -eq $Obj) { return $null }
    if (-not ($Obj.PSObject.Properties.Name -contains 'keepalive')) {
        $landing = [string]$Obj.landing
        $Obj | Add-Member -NotePropertyName keepalive -NotePropertyValue (Get-DefaultKeepalive -Landing $landing) -Force
    }
    return $Obj
}

function Read-Manifest {
    param([string]$Path)
    if (-not (Test-Path -Path $Path -PathType Leaf)) { return $null }
    try {
        $obj = Get-Content -Path $Path -Raw | ConvertFrom-Json
        if ($script:ManifestSchemasAccepted -notcontains [string]$obj.schema) { return $null }
        return (Normalize-Manifest $obj)
    }
    catch { return $null }
}

function Write-Manifest {
    param([string]$Name, [string]$Command, [string]$WorkDir, [string]$Mode,
          [string]$ScheduleType, [string]$At, [int]$Every, [string]$Landing,
          [bool]$Elevate, [string]$RootPath)

    $m = [ordered]@{
        schema       = $script:ManifestSchema
        name         = $Name
        command      = $Command
        workdir      = $WorkDir
        mode         = $Mode
        scheduleType = $ScheduleType
        at           = $At
        every        = $Every
        landing      = $Landing
        elevated     = $Elevate
        root         = $RootPath
        createdAt    = (Get-Date).ToString('o')
        keepalive    = (Get-DefaultKeepalive -Landing $Landing)
    }
    $manifestPath = Join-Path $RootPath ($Name + '.json')
    ($m | ConvertTo-Json -Depth 8) | Set-Content -Path $manifestPath -Encoding UTF8
    return $manifestPath
}

# =============================================================================
# 环境检测（issue 02）：只读，不写任何系统状态
# =============================================================================

function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-CanWriteScheduledTask {
    <# 只读探测：能否枚举计划任务（服务可用且可访问即视为可写用户级任务，尽力而为）。 #>
    try {
        $null = Get-ScheduledTask -ErrorAction Stop | Select-Object -First 1
        return $true
    }
    catch { return $false }
}

# =============================================================================
# 落点写入（issues 04/05/06）
# =============================================================================

function Get-CurrentPrincipalUser {
    if ($env:USERDOMAIN -and $env:USERNAME) {
        return "$env:USERDOMAIN\$env:USERNAME"
    }
    return $env:USERNAME
}

function New-AutostartTaskSettings {
    <#
      Standard keepalive baseline for scheduled-task landings (phase 1 / ADR-0005).
      RestartCount / RestartInterval come from script constants — single source of truth.
    #>
    return (New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount $script:TaskRestartCount `
        -RestartInterval (New-TimeSpan -Minutes $script:TaskRestartIntervalMinutes) `
        -MultipleInstances IgnoreNew `
        -Hidden)
}

function Write-ScheduledTaskLanding {
    param([string]$Name, [string]$Mode, [string]$ScheduleType, [string]$At,
          [int]$Every, [bool]$Elevate, [string]$VbsPath)

    $action = New-ScheduledTaskAction -Execute $script:WscriptPath -Argument (Quote-Path $VbsPath)

    $trigger = $null
    if ($Mode -eq 'logon') {
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User (Get-CurrentPrincipalUser)
    }
    elseif ($ScheduleType -eq 'DAILY') {
        $trigger = New-ScheduledTaskTrigger -Daily -At $At
    }
    else {
        # MINUTE：每天 0 点后每 N 分钟重复一次，时长约 10 年（近似无限）
        $start = (Get-Date).Date
        $trigger = New-ScheduledTaskTrigger -Once -At $start `
            -RepetitionInterval (New-TimeSpan -Minutes $Every) `
            -RepetitionDuration (New-TimeSpan -Days 3650)
    }

    $settings = New-AutostartTaskSettings

    $runLevel = if ($Elevate) { 'Highest' } else { 'Limited' }
    $principal = New-ScheduledTaskPrincipal -UserId (Get-CurrentPrincipalUser) -LogonType Interactive -RunLevel $runLevel

    Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal `
        -Description ('windows-autostart entry: ' + $Name) -Force | Out-Null
}

function Write-StartupLanding {
    param([string]$Name, [string]$VbsPath, [string]$RootPath)

    $startupDir = [Environment]::GetFolderPath('Startup')
    $lnkPath = Join-Path $startupDir ($Name + '.lnk')

    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($lnkPath)
    $sc.TargetPath = $script:WscriptPath
    $sc.Arguments = Quote-Path $VbsPath
    $sc.WorkingDirectory = $RootPath
    $sc.Description = 'windows-autostart entry: ' + $Name
    $sc.Save()
    return $lnkPath
}

function Write-RunKeyLanding {
    param([string]$Name, [string]$VbsPath)

    # 严格引号：exe 与 vbs 各自成对引号包裹，值形如 "<wscript.exe>" "<x.vbs>"
    $value = (Quote-Path $script:WscriptPath) + ' ' + (Quote-Path $VbsPath)
    Set-ItemProperty -Path $script:RunKeyPath -Name $Name -Value $value
    return $value
}

# =============================================================================
# 落点读取（供 status / uninstall 归属判断）
# =============================================================================

function Get-ScheduledTaskSnap {
    param([string]$Name, [string]$VbsPath)
    $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if (-not $task) { return $null }

    $info = $null
    try { $info = Get-ScheduledTaskInfo -TaskName $Name -ErrorAction SilentlyContinue } catch { $info = $null }

    # 归属：Action.Execute 为 wscript.exe 且 Arguments 引用本启动项隐藏入口
    $owned = $false
    $firstExecute = $null
    $firstArgs = $null
    if ($task.Actions -and $task.Actions.Count -gt 0) {
        $firstExecute = $task.Actions[0].Execute
        $firstArgs = $task.Actions[0].Arguments
        foreach ($a in $task.Actions) {
            if ($a.Execute -match 'wscript\.exe$') {
                if ($a.Arguments -and ($a.Arguments -like ('*' + $VbsPath + '*'))) { $owned = $true }
            }
        }
    }

    return [ordered]@{
        exists       = $true
        taskName     = $Name
        state        = $task.State
        execute      = $firstExecute
        arguments    = $firstArgs
        lastRunTime  = if ($info) { $info.LastRunTime } else { $null }
        lastResult   = if ($info) { $info.LastTaskResult } else { $null }
        owned        = $owned
    }
}

function Get-StartupSnap {
    param([string]$Name, [string]$VbsPath)
    $startupDir = [Environment]::GetFolderPath('Startup')
    $lnkPath = Join-Path $startupDir ($Name + '.lnk')
    $disabledPath = $lnkPath + '.disabled'
    $active = $false
    $pathToRead = $null
    $enabled = $null
    if (Test-Path -Path $lnkPath -PathType Leaf) {
        $active = $true
        $pathToRead = $lnkPath
        $enabled = $true
    }
    elseif (Test-Path -Path $disabledPath -PathType Leaf) {
        $active = $true
        $pathToRead = $disabledPath
        $enabled = $false
    }
    if (-not $active) { return $null }

    $owned = $false
    $target = $null
    $argsVal = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut($pathToRead)
        $target = $sc.TargetPath
        $argsVal = $sc.Arguments
        if ($target -match 'wscript\.exe$' -and $argsVal -and ($argsVal -like ('*' + $VbsPath + '*'))) {
            $owned = $true
        }
    }
    catch { }

    return [ordered]@{
        exists       = $true
        enabled      = $enabled
        path         = $pathToRead
        disabledPath = $disabledPath
        target       = $target
        arguments    = $argsVal
        owned        = $owned
    }
}

function Get-RunKeySnap {
    param([string]$Name, [string]$VbsPath)
    $key = Get-Item -Path $script:RunKeyPath -ErrorAction SilentlyContinue
    if (-not $key) { return $null }
    $val = $key.GetValue($Name, $null)
    if ($null -eq $val) { return $null }

    $owned = ($val -like ('*' + $VbsPath + '*'))
    return [ordered]@{
        exists = $true
        value  = $val
        owned  = $owned
    }
}

# =============================================================================
# recommend（issue 02）
# =============================================================================

function Invoke-Recommend {
    param([string]$Mode)

    $canWrite = Test-CanWriteScheduledTask
    $isAdmin = Test-IsAdmin

    $svc = Get-Service -Name 'Schedule' -ErrorAction SilentlyContinue
    $svcState = if ($svc) { $svc.Status.ToString() } else { 'unknown' }

    $envBlock = [ordered]@{
        isAdmin                 = $isAdmin
        scheduledTaskService    = $svcState
        canWriteScheduledTask   = $canWrite
    }

    $landings = New-Object System.Collections.Generic.List[object]
    if ($Mode -eq 'schedule') {
        # 定时执行强制计划任务（ADR-0002）
        $landings.Add([ordered]@{
            name        = 'scheduled-task'
            rank        = 1
            recommended = $true
            reason      = '定时执行只能由计划任务表达（Startup/注册表 Run 键无时间表语义）。'
        })
    }
    elseif ($canWrite) {
        $landings.Add([ordered]@{
            name        = 'scheduled-task'
            rank        = 1
            recommended = $true
            reason      = '计划任务可写，优先：长驻型业务命令享受失败重启与不超时执行。'
        })
        $landings.Add([ordered]@{
            name        = 'startup'
            rank        = 2
            recommended = $false
            reason      = 'Startup 快捷方式作为计划任务写入失败时的回退（无原生失败重启）。'
        })
    }
    else {
        $landings.Add([ordered]@{
            name        = 'startup'
            rank        = 1
            recommended = $true
            reason      = '计划任务不可写（受限会话/服务不可用），回退为当前用户 Startup 快捷方式。'
        })
        $landings.Add([ordered]@{
            name        = 'scheduled-task'
            rank        = 2
            recommended = $false
            reason      = '计划任务当前不可写，仅列作参考，不推荐。'
        })
    }

    return @{
        Data = [ordered]@{
            mode        = $Mode
            environment = $envBlock
            landings    = $landings
        }
        Result = 'ok'
    }
}

# =============================================================================
# uninstall（issue 09）
# =============================================================================

function Invoke-Uninstall {
    param([string]$Name, [string]$RootOverride)

    $root = Resolve-RootDir $Name $RootOverride
    $vbsPath = Join-Path $root ($Name + '.vbs')

    $removed = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    $absent  = New-Object System.Collections.Generic.List[string]
    $failed  = New-Object System.Collections.Generic.List[string]

    # 计划任务
    try {
        $taskSnap = Get-ScheduledTaskSnap -Name $Name -VbsPath $vbsPath
        if ($taskSnap) {
            if ($taskSnap['owned']) {
                Unregister-ScheduledTask -TaskName $Name -Confirm:$false
                $removed.Add('scheduled-task')
            } else { $skipped.Add('scheduled-task') }
        } else { $absent.Add('scheduled-task') }
    }
    catch { $failed.Add('scheduled-task') }

    # Startup 快捷方式（含 .lnk.disabled）
    try {
        $startupDir = [Environment]::GetFolderPath('Startup')
        $lnkPath = Join-Path $startupDir ($Name + '.lnk')
        $disabledLnk = $lnkPath + '.disabled'
        $startupSnap = Get-StartupSnap -Name $Name -VbsPath $vbsPath
        if ($startupSnap) {
            if ($startupSnap['owned']) {
                if (Test-Path -Path $lnkPath -PathType Leaf) { Remove-Item -Path $lnkPath -Force }
                if (Test-Path -Path $disabledLnk -PathType Leaf) { Remove-Item -Path $disabledLnk -Force }
                $removed.Add('startup-shortcut')
            } else { $skipped.Add('startup-shortcut') }
        } else { $absent.Add('startup-shortcut') }
    }
    catch { $failed.Add('startup-shortcut') }

    # 注册表 Run 键（仅显式写入的、归属可识别的值）
    try {
        $rkSnap = Get-RunKeySnap -Name $Name -VbsPath $vbsPath
        if ($rkSnap) {
            if ($rkSnap['owned']) {
                Remove-ItemProperty -Path $script:RunKeyPath -Name $Name -ErrorAction Stop
                $removed.Add('run-key')
            } else { $skipped.Add('run-key') }
        } else { $absent.Add('run-key') }
    }
    catch { $failed.Add('run-key') }

    # 封装产物（归属：目录内含本启动项的清单或隐藏入口）
    try {
        if (Test-Path -Path $root -PathType Container) {
            $manifest = Read-Manifest (Join-Path $root ($Name + '.json'))
            $vbsExists = Test-Path -Path $vbsPath -PathType Leaf
            if ($manifest -or $vbsExists) {
                Remove-Item -Path $root -Recurse -Force
                $removed.Add('package')
            } else { $skipped.Add('package') }
        } else { $absent.Add('package') }
    }
    catch { $failed.Add('package') }

    $result = if ($failed.Count -gt 0) { 'partial' } else { 'ok' }
    return @{
        Data = [ordered]@{
            name    = $Name
            root    = $root
            removed = @($removed)
            skipped = @($skipped)
            absent  = @($absent)
            failed  = @($failed)
        }
        Result = $result
    }
}

# =============================================================================
# run：立即按落点/隐藏入口试跑；-Visible 开可见控制台辅助排查
# =============================================================================

function Invoke-Run {
    param([string]$Name, [string]$RootOverride, [bool]$Visible)

    $root = Resolve-RootDir $Name $RootOverride
    $vbsPath = Join-Path $root ($Name + '.vbs')
    $cmdPath = Join-Path $root ($Name + '.cmd')
    $outLog = Join-Path $root ($Name + '.out.log')
    $errLog = Join-Path $root ($Name + '.err.log')

    if (-not (Test-Path -Path $vbsPath -PathType Leaf) -and -not (Test-Path -Path $cmdPath -PathType Leaf)) {
        throw "entry '$Name' not found under '$root' (missing package artifacts; register with add first)"
    }

    $via = $null
    $detail = $null

    if ($Visible) {
        # 诊断模式：可见控制台跑业务脚本，窗口里的报错可直接用于排查
        if (-not (Test-Path -Path $cmdPath -PathType Leaf)) {
            throw "business script missing: $cmdPath"
        }
        Start-Process -FilePath $script:CmdExe -ArgumentList @('/k', (Quote-Path $cmdPath)) -WorkingDirectory $root | Out-Null
        $via = 'visible-console'
        $detail = '已在可见控制台启动业务脚本；窗口里的报错可直接用于排查。日志仍写入 out/err。'
    }
    else {
        # 与真实落点一致：归属本工具的计划任务优先 Start-ScheduledTask，否则 wscript 拉隐藏入口
        $taskSnap = Get-ScheduledTaskSnap -Name $Name -VbsPath $vbsPath
        if ($taskSnap -and $taskSnap['owned']) {
            Start-ScheduledTask -TaskName $Name
            $via = 'scheduled-task'
            $detail = '已通过计划任务立即运行（与登录/定时触发同一 Action）。'
        }
        elseif (Test-Path -Path $vbsPath -PathType Leaf) {
            Start-Process -FilePath $script:WscriptPath -ArgumentList @('//nologo', $vbsPath) -WorkingDirectory $root | Out-Null
            $via = 'hidden-entry'
            $detail = '已通过隐藏入口（wscript+VBS）立即运行，与 Startup/Run 落点一致。'
        }
        else {
            throw "cannot run: no owned scheduled task and no hidden entry at '$vbsPath'"
        }
    }

    return @{
        Data = [ordered]@{
            name    = $Name
            root    = $root
            via     = $via
            visible = [bool]$Visible
            detail  = $detail
            next    = [ordered]@{
                statusHint  = "随后调用 status -Name $Name 查看 diagnosis 与日志尾部"
                logs        = [ordered]@{ out = $outLog; err = $errLog }
                visibleHint = if (-not $Visible) { '若仍起不来，用 run -Visible 开可见控制台看实时报错' } else { $null }
            }
        }
        Result = 'ok'
    }
}

# =============================================================================
# status（issue 08）
# =============================================================================

function Invoke-Status {
    param([string]$Name, [string]$RootOverride)

    $root = Resolve-RootDir $Name $RootOverride
    $vbsPath = Join-Path $root ($Name + '.vbs')
    $outLog = Join-Path $root ($Name + '.out.log')
    $errLog = Join-Path $root ($Name + '.err.log')

    $manifest = Read-Manifest (Join-Path $root ($Name + '.json'))

    $task = Get-ScheduledTaskSnap -Name $Name -VbsPath $vbsPath
    $startup = Get-StartupSnap -Name $Name -VbsPath $vbsPath
    $runKey = Get-RunKeySnap -Name $Name -VbsPath $vbsPath

    $outExists = Test-Path -Path $outLog -PathType Leaf
    $errExists = Test-Path -Path $errLog -PathType Leaf
    $outTail = if ($outExists) { (Get-Content -Path $outLog -Tail 30 -ErrorAction SilentlyContinue) -join "`n" } else { $null }
    $errTail = if ($errExists) { (Get-Content -Path $errLog -Tail 30 -ErrorAction SilentlyContinue) -join "`n" } else { $null }

    $hasLogContent = ($outExists -and $outTail) -or ($errExists -and $errTail)

    # 诊断归因（spec「诊断归因」）
    $runState = $null
    if ($task) {
        $lr = $task['lastResult']
        if ($null -eq $task['lastRunTime']) { $runState = 'never_run' }
        elseif ($lr -eq 267009) { $runState = 'never_run' }
        elseif ($lr -eq 267011) { $runState = 'running' }
        elseif ($lr -eq 0) { $runState = 'succeeded' }
        else { $runState = 'failed' }
    }

    $found = ($null -ne $manifest) -or ($null -ne $task) -or ($null -ne $startup) -or ($null -ne $runKey)

    $diagnosis = 'not_found'
    $detail = $null
    if ($found) {
        if ($hasLogContent) {
            $diagnosis = 'started'
            if ($errExists -and $errTail) { $diagnosis = 'started_with_stderr'; $detail = '业务已起且输出日志，err 日志含应用内告警（非失败）。' }
            else { $detail = '业务已起（日志有内容）；内容若含告警属应用内非致命提示，非解析失败。' }
        }
        elseif ($runState -eq 'failed') {
            $diagnosis = 'failed_to_start'
            $detail = '无日志且任务最近结果码非 0：命令解析/启动失败（不是应用内告警）。'
        }
        elseif ($runState -eq 'running') {
            $diagnosis = 'running'
            $detail = '任务最近结果码显示仍在运行；日志尚缺为正常现象。'
        }
        elseif ($runState -eq 'succeeded') {
            $diagnosis = 'started'
            $detail = '任务最近结果成功但日志为空，可能重定向未落盘。'
        }
        else {
            $diagnosis = 'not_started'
            $detail = '落点存在但尚未观测到运行（任务从未运行或尚无进程）。'
        }
    }

    # 进程线索：清单中的可执行若为 .exe，探测同名进程
    $process = $null
    if ($manifest -and $manifest.command) {
        $res = Get-ExeAndRest ([string]$manifest.command)
        $exe = $res['Exe']
        if ([System.IO.Path]::GetExtension($exe).ToLowerInvariant() -eq '.exe') {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($exe)
            try {
                $procs = @(Get-Process -Name $base -ErrorAction SilentlyContinue)
                $process = [ordered]@{
                    probe        = $base
                    runningCount = $procs.Count
                    pids         = @($procs | Select-Object -First 5 -ExpandProperty Id)
                }
            }
            catch { $process = $null }
        }
    }

    $landing = Resolve-EntryLanding -Name $Name -Root $root -Manifest $manifest -VbsPath $vbsPath
    $enabled = Get-EntryEnabled -Name $Name -Landing $landing -VbsPath $vbsPath

    $managerSlice = Get-ManagerEntrySlice -Name $Name
    $desiredEnabled = $null
    if ($null -ne $managerSlice -and ($managerSlice.Keys -contains 'desiredEnabled')) {
        $desiredEnabled = [bool]$managerSlice['desiredEnabled']
    }
    # manager: attach state entry when present (control-plane snapshot); else null
    $manager = $managerSlice

    return @{
        Data = [ordered]@{
            name           = $Name
            found          = $found
            root           = $root
            landing        = $landing
            enabled        = $enabled
            desiredEnabled = $desiredEnabled
            manager        = $manager
            diagnosis      = $diagnosis
            detail         = $detail
            landings       = [ordered]@{
                scheduledTask   = if ($task) { $task } else { [ordered]@{ exists = $false } }
                startupShortcut = if ($startup) { $startup } else { [ordered]@{ exists = $false } }
                runKey          = if ($runKey) { $runKey } else { [ordered]@{ exists = $false } }
            }
            task           = [ordered]@{
                runState = $runState
                lastRunTime = if ($task) { $task['lastRunTime'] } else { $null }
                lastResult  = if ($task) { $task['lastResult'] } else { $null }
            }
            process        = $process
            log            = [ordered]@{
                outExists = $outExists
                errExists = $errExists
                outTail   = $outTail
                errTail   = $errTail
            }
        }
        Result = 'ok'
    }
}

# =============================================================================
# add 编排（issues 03–07）
# =============================================================================

function Assert-AddParams {
    param([hashtable]$P)

    if ($P['Mode'] -eq 'schedule') {
        if (-not $P.ContainsKey('ScheduleType')) {
            throw "schedule mode requires -ScheduleType (DAILY|MINUTE)"
        }
        if ($P['ScheduleType'] -eq 'DAILY') {
            if (-not $P.ContainsKey('At')) { throw "-ScheduleType DAILY requires -At (HH:mm)" }
            if (-not (Test-TimeString $P['At'])) { throw "invalid -At '$($P['At'])' (expected HH:mm)" }
        }
        elseif ($P['ScheduleType'] -eq 'MINUTE') {
            if (-not $P.ContainsKey('Every')) { throw "-ScheduleType MINUTE requires -Every (minutes)" }
        }
    }
    else {
        # Mode = logon
        if ($P.ContainsKey('ScheduleType') -or $P.ContainsKey('At') -or $P.ContainsKey('Every')) {
            throw "-ScheduleType/-At/-Every are only valid with -Mode schedule"
        }
    }

    if ($P.ContainsKey('Landing')) {
        if ($P['Mode'] -eq 'schedule' -and $P['Landing'] -ne 'scheduled-task') {
            throw "schedule mode requires landing 'scheduled-task' (got '$($P['Landing'])')"
        }
    }
}

function Test-EntryExists {
    param([string]$Name, [string]$RootOverride)
    $root = Resolve-RootDir $Name $RootOverride
    $manifest = Read-Manifest (Join-Path $root ($Name + '.json'))
    $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    $startupDir = [Environment]::GetFolderPath('Startup')
    $lnk = Join-Path $startupDir ($Name + '.lnk')
    $lnkDisabled = $lnk + '.disabled'
    $key = Get-Item -Path $script:RunKeyPath -ErrorAction SilentlyContinue
    $rkVal = if ($key) { $key.GetValue($Name, $null) } else { $null }
    $hasStartup = (Test-Path -Path $lnk) -or (Test-Path -Path $lnkDisabled)
    return ($null -ne $manifest -or $null -ne $task -or $hasStartup -or ($null -ne $rkVal))
}

function Invoke-Add {
    param([hashtable]$P)

    Assert-AddParams $P

    $Name = $P['Name']
    $Command = $P['Command']
    $WorkDir = if ($P.ContainsKey('WorkDir')) { $P['WorkDir'] } else { $null }
    $Mode = $P['Mode']
    $ScheduleType = if ($P.ContainsKey('ScheduleType')) { $P['ScheduleType'] } else { $null }
    $At = if ($P.ContainsKey('At')) { $P['At'] } else { $null }
    $Every = if ($P.ContainsKey('Every')) { $P['Every'] } else { 0 }
    $Landing = if ($P.ContainsKey('Landing')) { $P['Landing'] } else { $null }
    $Elevate = [bool]$P['Elevate']
    $Force = [bool]$P['Force']
    $RootOverride = if ($P.ContainsKey('Root')) { $P['Root'] } else { $null }

    $root = Resolve-RootDir $Name $RootOverride

    # 同名冲突：默认拒绝，force 先卸载再安装（spec「强制覆盖」）
    if (-not $Force -and (Test-EntryExists $Name $RootOverride)) {
        throw "entry '$Name' already exists (use -Force to uninstall and recreate)"
    }
    if ($Force) {
        $null = Invoke-Uninstall -Name $Name -RootOverride $RootOverride
    }

    # 封装产物
    if (-not (Test-Path -Path $root -PathType Container)) {
        New-Item -Path $root -ItemType Directory | Out-Null
    }
    $outLog = Join-Path $root ($Name + '.out.log')
    $errLog = Join-Path $root ($Name + '.err.log')
    $cmdPath = Write-BusinessScript -Name $Name -Command $Command -WorkDir $WorkDir -RootPath $root -OutLog $outLog -ErrLog $errLog
    $vbsPath = Write-HiddenEntry -Name $Name -CmdPath $cmdPath -RootPath $root

    # 落点选择
    $finalLanding = $null
    $fallback = $false
    $fallbackFrom = $null
    $fallbackReason = $null
    $extraArtifacts = @{}

    if ($Mode -eq 'schedule') {
        # 定时执行：强制计划任务，绝不回退
        try {
            Write-ScheduledTaskLanding -Name $Name -Mode $Mode -ScheduleType $ScheduleType -At $At -Every $Every -Elevate $Elevate -VbsPath $vbsPath
            $finalLanding = 'scheduled-task'
        }
        catch {
            # 回滚封装产物，避免孤儿状态
            if (Test-Path -Path $root) { Remove-Item -Path $root -Recurse -Force }
            throw "failed to register scheduled task: $($_.Exception.Message)"
        }
    }
    elseif ($Landing) {
        # 显式落点：失败不回退（用户已明确指定）
        try {
            switch ($Landing) {
                'scheduled-task' {
                    Write-ScheduledTaskLanding -Name $Name -Mode $Mode -ScheduleType $ScheduleType -At $At -Every $Every -Elevate $Elevate -VbsPath $vbsPath
                    $extraArtifacts['scheduledTaskName'] = $Name
                }
                'startup' {
                    $lnkPath = Write-StartupLanding -Name $Name -VbsPath $vbsPath -RootPath $root
                    $extraArtifacts['startupShortcut'] = $lnkPath
                }
                'run-key' {
                    $val = Write-RunKeyLanding -Name $Name -VbsPath $vbsPath
                    $extraArtifacts['runKeyValue'] = $val
                }
            }
            $finalLanding = $Landing
        }
        catch {
            if (Test-Path -Path $root) { Remove-Item -Path $root -Recurse -Force }
            throw "failed to write landing '$Landing': $($_.Exception.Message)"
        }
    }
    else {
        # 默认链（ADR-0003）：计划任务优先；失败不自动回退，抛错让用户确认降级。
        # 降级到 Startup 的影响：进程崩溃后不会自动重启，仅在重新登录时拉起。
        try {
            Write-ScheduledTaskLanding -Name $Name -Mode $Mode -ScheduleType $ScheduleType -At $At -Every $Every -Elevate $Elevate -VbsPath $vbsPath
            $finalLanding = 'scheduled-task'
        }
        catch {
            # 清理封装产物，避免孤儿状态
            if (Test-Path -Path $root) { Remove-Item -Path $root -Recurse -Force }
            throw ("scheduled-task registration failed: " + $_.Exception.Message +
                   "`nFallback to Startup shortcut is NOT automatic. " +
                   "If you want to degrade to Startup (no crash auto-restart; only relaunched on next logon), " +
                   "retry with -Landing startup.")
        }
    }

    $manifestPath = Write-Manifest -Name $Name -Command $Command -WorkDir $WorkDir -Mode $Mode `
        -ScheduleType $ScheduleType -At $At -Every $Every -Landing $finalLanding `
        -Elevate $Elevate -RootPath $root

    $extraArtifacts['businessScript'] = $cmdPath
    $extraArtifacts['hiddenEntry'] = $vbsPath
    $extraArtifacts['outLog'] = $outLog
    $extraArtifacts['errLog'] = $errLog
    $extraArtifacts['manifest'] = $manifestPath
    if ($finalLanding -eq 'scheduled-task') {
        $extraArtifacts['scheduledTaskName'] = $Name
    }

    # 默认立即试跑一次（与真实落点一致），便于当场发现命令/路径问题；-NoRun 可跳过
    $ranNow = -not [bool]$P['NoRun']
    $runData = $null
    $result = 'ok'
    if ($ranNow) {
        try {
            $runResult = Invoke-Run -Name $Name -RootOverride $RootOverride -Visible $false
            $runData = $runResult['Data']
        }
        catch {
            $result = 'partial'
            $runData = [ordered]@{
                attempted = $true
                error     = $_.Exception.Message
                detail    = '注册成功但立即试跑失败；请用 run / status 继续排查。'
                next      = [ordered]@{
                    statusHint  = "随后调用 status -Name $Name 查看 diagnosis 与日志尾部"
                    logs        = [ordered]@{ out = $outLog; err = $errLog }
                    visibleHint = '用 run -Visible 开可见控制台看实时报错'
                }
            }
        }
    }

    return @{
        Data = [ordered]@{
            name           = $Name
            mode           = $Mode
            landing        = $finalLanding
            fallback       = $fallback
            fallbackFrom   = $fallbackFrom
            fallbackReason = $fallbackReason
            root           = $root
            artifacts      = $extraArtifacts
            ranNow         = $ranNow
            run            = $runData
        }
        Result = $result
    }
}

# =============================================================================
# 控制面状态（~\.win-autostart\_manager\state.json）与启用探测
# =============================================================================

function Get-PackagesParentDir {
    <# Parent that holds package child dirs. Default: %USERPROFILE%\.win-autostart #>
    param([string]$RootOverride)
    if ($RootOverride) { return $RootOverride }
    return (Join-Path $env:USERPROFILE '.win-autostart')
}

function Get-ManagerStatePath {
    return (Join-Path (Join-Path (Join-Path $env:USERPROFILE '.win-autostart') '_manager') 'state.json')
}

function ConvertTo-PlainEntryMap {
    param($EntryObj)
    $map = @{}
    if ($null -eq $EntryObj) { return $map }
    if ($EntryObj -is [hashtable] -or $EntryObj -is [System.Collections.Specialized.OrderedDictionary]) {
        foreach ($k in @($EntryObj.Keys)) { $map[[string]$k] = $EntryObj[$k] }
        return $map
    }
    foreach ($p in $EntryObj.PSObject.Properties) {
        $map[[string]$p.Name] = $p.Value
    }
    return $map
}

function Read-ManagerState {
    $path = Get-ManagerStatePath
    $entries = @{}
    $schema = 'windows-autostart-state/1'
    if (-not (Test-Path -Path $path -PathType Leaf)) {
        return @{ Schema = $schema; Entries = $entries }
    }
    try {
        $obj = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($obj.schema) { $schema = [string]$obj.schema }
        if ($obj.entries) {
            foreach ($p in $obj.entries.PSObject.Properties) {
                $entries[$p.Name] = (ConvertTo-PlainEntryMap $p.Value)
            }
        }
    }
    catch { }
    return @{ Schema = $schema; Entries = $entries }
}

function Save-ManagerState {
    param($State)
    $path = Get-ManagerStatePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -Path $dir -PathType Container)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    $orderedEntries = [ordered]@{}
    foreach ($k in @($State.Entries.Keys | Sort-Object)) {
        $raw = ConvertTo-PlainEntryMap $State.Entries[$k]
        $oe = [ordered]@{}
        foreach ($fk in @($raw.Keys | Sort-Object)) { $oe[$fk] = $raw[$fk] }
        $orderedEntries[$k] = $oe
    }
    $doc = [ordered]@{
        schema  = $State.Schema
        entries = $orderedEntries
    }
    ($doc | ConvertTo-Json -Depth 8) | Set-Content -Path $path -Encoding UTF8
}

function Update-ManagerEntry {
    param([string]$Name, [hashtable]$Fields)
    $state = Read-ManagerState
    $cur = @{}
    if ($state.Entries.ContainsKey($Name)) {
        $cur = ConvertTo-PlainEntryMap $state.Entries[$Name]
    }
    foreach ($k in @($Fields.Keys)) { $cur[$k] = $Fields[$k] }
    $state.Entries[$Name] = $cur
    Save-ManagerState $state
    return $cur
}

function Get-ManagerEntrySlice {
    param([string]$Name)
    $state = Read-ManagerState
    if (-not $state.Entries.ContainsKey($Name)) { return $null }
    $map = ConvertTo-PlainEntryMap $state.Entries[$Name]
    $ordered = [ordered]@{}
    foreach ($k in @($map.Keys | Sort-Object)) { $ordered[$k] = $map[$k] }
    return $ordered
}

function Resolve-EntryLanding {
    param([string]$Name, [string]$Root, $Manifest, [string]$VbsPath)
    if ($Manifest -and $Manifest.landing) { return [string]$Manifest.landing }
    $task = Get-ScheduledTaskSnap -Name $Name -VbsPath $VbsPath
    if ($task) { return 'scheduled-task' }
    $startup = Get-StartupSnap -Name $Name -VbsPath $VbsPath
    if ($startup) { return 'startup' }
    $rk = Get-RunKeySnap -Name $Name -VbsPath $VbsPath
    if ($rk) { return 'run-key' }
    return $null
}

function Get-EntryEnabled {
    <#
      enabled 线索：scheduled-task 看 State；startup 看 .lnk vs .lnk.disabled；
      run-key 看值是否存在。无法判断时返回 $null。
    #>
    param([string]$Name, [string]$Landing, [string]$VbsPath)

    if (-not $Landing) { return $null }

    if ($Landing -eq 'scheduled-task') {
        $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
        if (-not $task) { return $null }
        $st = [string]$task.State
        if ($st -eq 'Disabled') { return $false }
        # Ready / Running / other non-Disabled → treated as enabled
        return $true
    }
    if ($Landing -eq 'startup') {
        $startupDir = [Environment]::GetFolderPath('Startup')
        $lnkPath = Join-Path $startupDir ($Name + '.lnk')
        $disabledPath = $lnkPath + '.disabled'
        if (Test-Path -Path $lnkPath -PathType Leaf) { return $true }
        if (Test-Path -Path $disabledPath -PathType Leaf) { return $false }
        return $null
    }
    if ($Landing -eq 'run-key') {
        $key = Get-Item -Path $script:RunKeyPath -ErrorAction SilentlyContinue
        if (-not $key) { return $false }
        $val = $key.GetValue($Name, $null)
        return ($null -ne $val)
    }
    return $null
}

function Get-ProcessProbeNames {
    param($Manifest)
    $names = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Manifest) { return @() }

    $img = $null
    if ($Manifest.PSObject.Properties.Name -contains 'keepalive' -and $Manifest.keepalive) {
        $proc = $Manifest.keepalive.process
        if ($proc -and ($proc.PSObject.Properties.Name -contains 'imageName') -and $proc.imageName) {
            $img = [string]$proc.imageName
        }
    }
    if ($img) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($img)
        if ($base) { $names.Add($base) }
    }
    elseif ($Manifest.command) {
        $res = Get-ExeAndRest ([string]$Manifest.command)
        $exe = $res['Exe']
        if ($exe -and ([System.IO.Path]::GetExtension($exe).ToLowerInvariant() -eq '.exe')) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($exe)
            if ($base) { $names.Add($base) }
        }
    }
    return @($names)
}

# =============================================================================
# list / enable / disable / stop（phase 2）
# =============================================================================

function Invoke-List {
    param([string]$RootOverride)

    $parent = Get-PackagesParentDir -RootOverride $RootOverride
    $entries = New-Object System.Collections.Generic.List[object]

    if (Test-Path -Path $parent -PathType Container) {
        $dirs = Get-ChildItem -Path $parent -Directory -ErrorAction SilentlyContinue
        foreach ($d in @($dirs)) {
            $name = $d.Name
            if ($name -eq '_manager') { continue }

            $root = $d.FullName
            $manifestPath = Join-Path $root ($name + '.json')
            $manifest = Read-Manifest $manifestPath
            $vbsPath = Join-Path $root ($name + '.vbs')
            $cmdPath = Join-Path $root ($name + '.cmd')
            $hasArtifacts = (Test-Path -Path $vbsPath -PathType Leaf) -or (Test-Path -Path $cmdPath -PathType Leaf)

            if (-not $manifest -and -not $hasArtifacts) { continue }

            $landing = Resolve-EntryLanding -Name $name -Root $root -Manifest $manifest -VbsPath $vbsPath
            $enabled = Get-EntryEnabled -Name $name -Landing $landing -VbsPath $vbsPath
            $schema = if ($manifest) { [string]$manifest.schema } else { $null }
            $mode = if ($manifest -and $manifest.mode) { [string]$manifest.mode } else { $null }

            $entries.Add([ordered]@{
                name    = $name
                landing = $landing
                mode    = $mode
                enabled = $enabled
                schema  = $schema
                root    = $root
            })
        }
    }

    # PS 5.1: @($genericList) does NOT unwrap — ConvertTo-Json then type-mismatches.
    $entryArr = @($entries.ToArray())
    return @{
        Data = [ordered]@{
            parent  = $parent
            entries = $entryArr
        }
        Result = 'ok'
    }
}

function Invoke-Enable {
    param([string]$Name, [string]$RootOverride)

    $root = Resolve-RootDir $Name $RootOverride
    $vbsPath = Join-Path $root ($Name + '.vbs')
    $manifest = Read-Manifest (Join-Path $root ($Name + '.json'))
    $landing = Resolve-EntryLanding -Name $Name -Root $root -Manifest $manifest -VbsPath $vbsPath
    if (-not $landing) {
        throw "entry '$Name' not found under '$root' (no manifest/landing)"
    }

    if ($landing -eq 'scheduled-task') {
        $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
        if (-not $task) { throw "scheduled task '$Name' not found" }
        try {
            Enable-ScheduledTask -TaskName $Name -ErrorAction Stop | Out-Null
        }
        catch {
            throw ("failed to enable scheduled task '$Name': " + $_.Exception.Message)
        }
    }
    elseif ($landing -eq 'startup') {
        $startupDir = [Environment]::GetFolderPath('Startup')
        $lnkPath = Join-Path $startupDir ($Name + '.lnk')
        $disabledPath = $lnkPath + '.disabled'
        if (Test-Path -Path $lnkPath -PathType Leaf) {
            # already enabled
        }
        elseif (Test-Path -Path $disabledPath -PathType Leaf) {
            Rename-Item -Path $disabledPath -NewName (Split-Path -Leaf $lnkPath) -Force
        }
        else {
            throw "startup shortcut for '$Name' not found (neither .lnk nor .lnk.disabled)"
        }
    }
    elseif ($landing -eq 'run-key') {
        if (-not (Test-Path -Path $vbsPath -PathType Leaf)) {
            throw "cannot enable run-key for '$Name': hidden entry missing at '$vbsPath'"
        }
        $null = Write-RunKeyLanding -Name $Name -VbsPath $vbsPath
    }
    else {
        throw "unsupported landing '$landing' for enable"
    }

    $updatedAt = (Get-Date).ToString('o')
    $null = Update-ManagerEntry -Name $Name -Fields @{
        desiredEnabled = $true
        updatedAt      = $updatedAt
    }

    $enabled = Get-EntryEnabled -Name $Name -Landing $landing -VbsPath $vbsPath
    return @{
        Data = [ordered]@{
            name           = $Name
            landing        = $landing
            enabled        = $enabled
            desiredEnabled = $true
            root           = $root
        }
        Result = 'ok'
    }
}

function Invoke-Disable {
    param([string]$Name, [string]$RootOverride)

    $root = Resolve-RootDir $Name $RootOverride
    $vbsPath = Join-Path $root ($Name + '.vbs')
    $manifest = Read-Manifest (Join-Path $root ($Name + '.json'))
    $landing = Resolve-EntryLanding -Name $Name -Root $root -Manifest $manifest -VbsPath $vbsPath
    if (-not $landing) {
        throw "entry '$Name' not found under '$root' (no manifest/landing)"
    }

    if ($landing -eq 'scheduled-task') {
        $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
        if (-not $task) { throw "scheduled task '$Name' not found" }
        try {
            Disable-ScheduledTask -TaskName $Name -ErrorAction Stop | Out-Null
        }
        catch {
            throw ("failed to disable scheduled task '$Name': " + $_.Exception.Message)
        }
    }
    elseif ($landing -eq 'startup') {
        $startupDir = [Environment]::GetFolderPath('Startup')
        $lnkPath = Join-Path $startupDir ($Name + '.lnk')
        $disabledPath = $lnkPath + '.disabled'
        if (Test-Path -Path $disabledPath -PathType Leaf) {
            # already disabled
        }
        elseif (Test-Path -Path $lnkPath -PathType Leaf) {
            Rename-Item -Path $lnkPath -NewName ((Split-Path -Leaf $lnkPath) + '.disabled') -Force
        }
        else {
            throw "startup shortcut for '$Name' not found (neither .lnk nor .lnk.disabled)"
        }
    }
    elseif ($landing -eq 'run-key') {
        $key = Get-Item -Path $script:RunKeyPath -ErrorAction SilentlyContinue
        $val = if ($key) { $key.GetValue($Name, $null) } else { $null }
        if ($null -ne $val) {
            Remove-ItemProperty -Path $script:RunKeyPath -Name $Name -ErrorAction Stop
        }
        # value already absent: still record desiredEnabled=false
    }
    else {
        throw "unsupported landing '$landing' for disable"
    }

    $updatedAt = (Get-Date).ToString('o')
    $null = Update-ManagerEntry -Name $Name -Fields @{
        desiredEnabled = $false
        updatedAt      = $updatedAt
    }

    $enabled = Get-EntryEnabled -Name $Name -Landing $landing -VbsPath $vbsPath
    return @{
        Data = [ordered]@{
            name           = $Name
            landing        = $landing
            enabled        = $enabled
            desiredEnabled = $false
            root           = $root
        }
        Result = 'ok'
    }
}

function Invoke-Stop {
    param([string]$Name, [string]$RootOverride)

    $root = Resolve-RootDir $Name $RootOverride
    $vbsPath = Join-Path $root ($Name + '.vbs')
    $manifest = Read-Manifest (Join-Path $root ($Name + '.json'))
    if (-not $manifest -and -not (Test-Path -Path $vbsPath -PathType Leaf)) {
        throw "entry '$Name' not found under '$root'"
    }

    $probeNames = Get-ProcessProbeNames -Manifest $manifest
    $stoppedPids = New-Object System.Collections.Generic.List[int]
    foreach ($probe in $probeNames) {
        try {
            $procs = @(Get-Process -Name $probe -ErrorAction SilentlyContinue)
            foreach ($p in $procs) {
                try {
                    Stop-Process -Id $p.Id -Force -ErrorAction Stop
                    $stoppedPids.Add([int]$p.Id)
                }
                catch { }
            }
        }
        catch { }
    }

    $taskStopped = $false
    $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if ($task) {
        try {
            Stop-ScheduledTask -TaskName $Name -ErrorAction Stop
            $taskStopped = $true
        }
        catch {
            # task may already be idle; do not fail the whole stop
            $taskStopped = $false
        }
    }

    $stopAt = (Get-Date).ToString('o')
    $null = Update-ManagerEntry -Name $Name -Fields @{
        lastStopAt = $stopAt
        updatedAt  = $stopAt
    }

    $pidArr = @($stoppedPids.ToArray())
    $probeArr = @($probeNames)
    return @{
        Data = [ordered]@{
            name        = $Name
            root        = $root
            stoppedPids = $pidArr
            taskStopped = $taskStopped
            probes      = $probeArr
        }
        Result = 'ok'
    }
}

# =============================================================================
# 分发
# =============================================================================

function Invoke-CommandHandler {
    param([string]$Sub, [hashtable]$Params)

    switch ($Sub) {
        'recommend' {
            return Invoke-Recommend -Mode $Params['Mode']
        }
        'add' {
            return Invoke-Add -P $Params
        }
        'run' {
            return Invoke-Run -Name $Params['Name'] -RootOverride $Params['Root'] -Visible ([bool]$Params['Visible'])
        }
        'status' {
            return Invoke-Status -Name $Params['Name'] -RootOverride $Params['Root']
        }
        'uninstall' {
            return Invoke-Uninstall -Name $Params['Name'] -RootOverride $Params['Root']
        }
        'list' {
            return Invoke-List -RootOverride $Params['Root']
        }
        'enable' {
            return Invoke-Enable -Name $Params['Name'] -RootOverride $Params['Root']
        }
        'disable' {
            return Invoke-Disable -Name $Params['Name'] -RootOverride $Params['Root']
        }
        'stop' {
            return Invoke-Stop -Name $Params['Name'] -RootOverride $Params['Root']
        }
        default {
            throw "unhandled subcommand '$Sub'"
        }
    }
}

function Invoke-Cli {
    param([string[]]$ArgList)

    $sub = $null
    $rest = @()
    if ($ArgList.Count -gt 0) {
        $sub = $ArgList[0]
        if ($ArgList.Count -gt 1) {
            $rest = $ArgList[1..($ArgList.Count - 1)]
        }
    }
    if (-not $sub) {
        throw "missing subcommand (expected one of: $($script:SubCommands -join '|'))"
    }
    if ($sub -notin $script:SubCommands) {
        throw "unknown subcommand '$sub' (expected one of: $($script:SubCommands -join '|'))"
    }

    $parsed = ConvertFrom-CliArgs -Sub $sub -ArgList $rest
    $required = $script:RequiredParams[$sub]
    if ($null -ne $required) {
        foreach ($req in $required) {
            if (-not $parsed.ContainsKey($req)) {
                throw "missing required parameter '-$req' for subcommand '$sub'"
            }
        }
    }

    $handler = Invoke-CommandHandler -Sub $sub -Params $parsed
    $data = $handler['Data']
    $result = $handler['Result']
    return [ordered]@{
        command = $sub
        result  = $result
        error   = $null
        data    = $data
    }
}

$rawArgs = @($args)
$firstToken = if ($rawArgs.Count -gt 0) { $rawArgs[0] } else { $null }

$result = $null
try {
    $result = Invoke-Cli -ArgList $rawArgs
}
catch {
    $result = [ordered]@{
        command = $firstToken
        result  = 'error'
        error   = $_.Exception.Message
        data    = @{}
    }
}

Write-Output ($result | ConvertTo-Json -Depth 8 -Compress)

switch ($result['result']) {
    'ok'      { exit 0 }
    'partial' { exit 2 }
    default   { exit 1 }
}
