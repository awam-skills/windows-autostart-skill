#Requires -Version 5.1
# Restart pipeline: respect desiredEnabled, cooldown + exponential backoff.

Set-StrictMode -Version 2.0

function Test-EntryDesiredEnabled {
    param([string]$ManagerRoot, [string]$Name)
    $slice = Get-ManagerEntryState -ManagerRoot $ManagerRoot -Name $Name
    if ($null -eq $slice) { return $true }  # no intent recorded → allow (match CLI null)
    if ($slice.ContainsKey('desiredEnabled') -and $null -ne $slice['desiredEnabled']) {
        return [bool]$slice['desiredEnabled']
    }
    return $true
}

function Test-IsControlPlaneSelfEntry {
    <#
      判断该启动项是否就是当前控制面进程（命令行指向本机 Manager 脚本）。
      用于避免 stop/restart 自杀后无法再 run。
    #>
    param([string]$Name, [string]$PackagesRoot)

    if (-not $Name -or -not $PackagesRoot) { return $false }

    $mgrScript = $null
    $v = Get-Variable -Name ManagerScriptPath -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $v -and $v.Value) { $mgrScript = [string]$v.Value }
    if (-not $mgrScript) { return $false }

    $manifestPath = Join-Path (Join-Path $PackagesRoot $Name) ($Name + '.json')
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $false }

    $cmd = $null
    try {
        $doc = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($doc -and ($doc.PSObject.Properties.Name -contains 'command')) {
            $cmd = [string]$doc.command
        }
    }
    catch { return $false }
    if (-not $cmd) { return $false }

    $normScript = $mgrScript.Replace('/', '\').Trim().ToLowerInvariant()
    $normCmd = $cmd.Replace('/', '\').ToLowerInvariant()
    if (-not $normScript) { return $false }
    return ($normCmd.IndexOf($normScript, [StringComparison]::Ordinal) -ge 0)
}

function Request-ManagerGracefulStop {
    <# 写入 STOP 标志，让 serve 循环在响应完当前请求后自行退出并释放端口。 #>
    param([string]$ManagerRoot)
    $dir = Get-ManagerDir -ManagerRoot $ManagerRoot
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    $stopFile = Join-Path $dir 'STOP'
    Set-Content -LiteralPath $stopFile -Value ((Get-Date).ToString('o')) -Encoding UTF8
    return $stopFile
}

function Start-DeferredEntryRun {
    <#
      在独立进程中延迟执行 CLI run，使当前控制面可先优雅退出并释放端口。
      延迟期间轮询监听端口，端口空闲后再启动。
    #>
    param(
        [string]$CliPath,
        [string]$Name,
        [string]$PackagesRoot,
        [string]$ManagerRoot,
        [int]$DelaySec = 1,
        [int]$WaitPortSec = 30
    )

    if ($script:DeferredRunHook -is [scriptblock]) {
        $null = & $script:DeferredRunHook -CliPath $CliPath -Name $Name -PackagesRoot $PackagesRoot -ManagerRoot $ManagerRoot -DelaySec $DelaySec -WaitPortSec $WaitPortSec
        return
    }

    $exe = Get-PowerShellHostExe
    $port = 18765
    try {
        $cfg = Read-ManagerConfig -ManagerRoot $ManagerRoot
        if ($cfg -and $cfg.ContainsKey('port') -and $null -ne $cfg['port']) {
            $port = [int]$cfg['port']
        }
    }
    catch { }

    $exeQ = $exe.Replace("'", "''")
    $cliQ = $CliPath.Replace("'", "''")
    $nameQ = $Name.Replace("'", "''")
    $rootLine = ''
    if ($PackagesRoot) {
        $rootQ = $PackagesRoot.Replace("'", "''")
        $rootLine = " `$argList += @('-Root', '$rootQ')"
    }

    $scriptBody = @"
Start-Sleep -Seconds $DelaySec
`$deadline = (Get-Date).AddSeconds($WaitPortSec)
while ((Get-Date) -lt `$deadline) {
  `$busy = `$false
  try {
    `$c = New-Object System.Net.Sockets.TcpClient
    `$iar = `$c.BeginConnect('127.0.0.1', $port, `$null, `$null)
    if (`$iar.AsyncWaitHandle.WaitOne(200, `$false)) {
      try { `$c.EndConnect(`$iar); `$busy = `$true } catch { `$busy = `$false }
    }
    try { `$c.Close() } catch { }
  } catch { `$busy = `$false }
  if (-not `$busy) { break }
  Start-Sleep -Milliseconds 250
}
`$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', '$cliQ', 'run', '-Name', '$nameQ')
$rootLine
& '$exeQ' @argList | Out-Null
"@

    # 用 -EncodedCommand 避免引号/路径空格踩坑；独立进程，父进程退出后仍继续
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($scriptBody)
    $encoded = [Convert]::ToBase64String($bytes)
    Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -WindowStyle Hidden | Out-Null
}

function Get-RestartCooldownSec {
    param($Cfg, [int]$BackoffLevel)
    $base = [int]$Cfg['restartCooldownSec']
    if ($base -lt 1) { $base = 30 }
    $max = [int]$Cfg['restartBackoffMaxSec']
    if ($max -lt $base) { $max = $base }
    $level = [Math]::Max(0, $BackoffLevel)
    # cooldown * 2^level, capped
    $factor = [Math]::Pow(2, [Math]::Min($level, 16))
    $sec = [int][Math]::Min([double]$max, [double]$base * $factor)
    return $sec
}

function Write-DryRunRestartIntent {
    param([string]$ManagerRoot, [string]$Name, [string]$Reason)
    $dir = Get-ManagerDir -ManagerRoot $ManagerRoot
    $path = Join-Path $dir 'test-restarts.jsonl'
    $rec = [ordered]@{
        at     = (Get-Date).ToString('o')
        name   = $Name
        reason = $Reason
    }
    $line = ($rec | ConvertTo-Json -Compress -Depth 4)
    Add-Content -Path $path -Value $line -Encoding UTF8
}

function Restart-Entry {
    <#
      Restart pipeline:
        1. desiredEnabled -eq $false → skip
        2. cooldown (lastRestartAt + backoff) → skip
        3. DryRun → record intent; else CLI stop then run
        4. Update lastRestartAt; bump backoff on rapid failure path
    #>
    param(
        [string]$ManagerRoot,
        [string]$CliPath,
        [string]$PackagesRoot,
        [string]$Name,
        [string]$Reason = 'manual',
        [switch]$DryRun,
        $Cfg
    )

    if (-not $Cfg) { $Cfg = Read-ManagerConfig -ManagerRoot $ManagerRoot }

    # 触发来源分流：自动触发（health / watch:*）受 desiredEnabled 与冷却退避约束，
    # 用于压制无人值守的重启风暴；用户显式触发（api / manual 等）代表操作者意图，
    # 绕过两道闸门并复位退避与失败计数。
    $isAutoReason = ($Reason -eq 'health' -or $Reason -like 'health:*' -or $Reason -like 'watch:*')

    if ($isAutoReason -and -not (Test-EntryDesiredEnabled -ManagerRoot $ManagerRoot -Name $Name)) {
        Write-ManagerLog -ManagerRoot $ManagerRoot -Level 'INFO' -Message ("Restart skip '{0}': desiredEnabled=false (reason={1})" -f $Name, $Reason)
        return [ordered]@{
            ok     = $false
            skipped = $true
            reason = 'desiredEnabled=false'
            name   = $Name
        }
    }

    $slice = Get-ManagerEntryState -ManagerRoot $ManagerRoot -Name $Name
    if ($null -eq $slice) { $slice = @{} }
    $backoff = 0
    if ($slice.ContainsKey('restartBackoffLevel') -and $null -ne $slice['restartBackoffLevel']) {
        $backoff = [int]$slice['restartBackoffLevel']
    }
    $cooldownSec = Get-RestartCooldownSec -Cfg $Cfg -BackoffLevel $backoff

    if ($isAutoReason -and $slice.ContainsKey('lastRestartAt') -and $slice['lastRestartAt']) {
        try {
            $last = [datetime]::Parse([string]$slice['lastRestartAt'], $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $elapsed = ((Get-Date) - $last).TotalSeconds
            if ($elapsed -lt $cooldownSec) {
                $msg = ("Restart skip '{0}': cooldown {1}s not elapsed (elapsed={2:N1}, backoff={3}, reason={4})" -f $Name, $cooldownSec, $elapsed, $backoff, $Reason)
                Write-ManagerLog -ManagerRoot $ManagerRoot -Level 'INFO' -Message $msg
                return [ordered]@{
                    ok      = $false
                    skipped = $true
                    reason  = 'cooldown'
                    name    = $Name
                    cooldownSec = $cooldownSec
                    elapsedSec  = [Math]::Round($elapsed, 1)
                }
            }
        }
        catch { }
    }

    $dryVar = Get-Variable -Name ManagerDryRun -Scope Script -ErrorAction SilentlyContinue
    $useDry = [bool]$DryRun -or ($null -ne $dryVar -and [bool]$dryVar.Value) -or ($env:WIN_AUTOSTART_MANAGER_DRYRUN -eq '1')
    $nowIso = (Get-Date).ToString('o')

    # 控制面自身优先于普通 dry-run / stop+run：避免自杀后无法再拉起
    if (Test-IsControlPlaneSelfEntry -Name $Name -PackagesRoot $PackagesRoot) {
        if ($useDry) {
            Write-DryRunRestartIntent -ManagerRoot $ManagerRoot -Name $Name -Reason $Reason
            Write-ManagerLog -ManagerRoot $ManagerRoot -Level 'INFO' -Message ("Restart self DRYRUN '{0}' reason={1}" -f $Name, $Reason)
            $null = Update-ManagerEntryState -ManagerRoot $ManagerRoot -Name $Name -Fields @{
                lastRestartAt       = $nowIso
                restartBackoffLevel = $backoff + 1
                lastRestartReason   = $Reason
                lastRestartDryRun   = $true
                selfRestartDeferred = $true
            }
            return [ordered]@{
                ok          = $true
                skipped     = $false
                dryRun      = $true
                deferred    = $true
                selfRestart = $true
                name        = $Name
                reason      = $Reason
            }
        }

        Write-ManagerLog -ManagerRoot $ManagerRoot -Level 'INFO' -Message ("Restart self '{0}' deferred (reason={1})" -f $Name, $Reason)
        $null = Start-DeferredEntryRun -CliPath $CliPath -Name $Name -PackagesRoot $PackagesRoot -ManagerRoot $ManagerRoot
        $null = Request-ManagerGracefulStop -ManagerRoot $ManagerRoot
        $null = Update-ManagerEntryState -ManagerRoot $ManagerRoot -Name $Name -Fields @{
            lastRestartAt             = $nowIso
            restartBackoffLevel       = $backoff + 1
            lastRestartReason         = $Reason
            lastRestartDryRun         = $false
            lastRestartOk             = $true
            lastStopResult            = 'graceful-stop'
            lastRunResult             = 'deferred'
            consecutiveHealthFailures = 0
            selfRestartDeferred       = $true
        }
        return [ordered]@{
            ok          = $true
            skipped     = $false
            dryRun      = $false
            deferred    = $true
            selfRestart = $true
            name        = $Name
            reason      = $Reason
            stop        = @{ result = 'graceful-stop'; error = $null }
            run         = @{ result = 'deferred'; error = $null }
        }
    }

    if ($useDry) {
        Write-DryRunRestartIntent -ManagerRoot $ManagerRoot -Name $Name -Reason $Reason
        Write-ManagerLog -ManagerRoot $ManagerRoot -Level 'INFO' -Message ("Restart DRYRUN '{0}' reason={1}" -f $Name, $Reason)
        $newBackoff = if ($isAutoReason) { $backoff + 1 } else { 0 }
        $null = Update-ManagerEntryState -ManagerRoot $ManagerRoot -Name $Name -Fields @{
            lastRestartAt         = $nowIso
            restartBackoffLevel   = $newBackoff
            lastRestartReason     = $Reason
            lastRestartDryRun     = $true
        }
        return [ordered]@{
            ok      = $true
            skipped = $false
            dryRun  = $true
            name    = $Name
            reason  = $Reason
        }
    }

    Write-ManagerLog -ManagerRoot $ManagerRoot -Level 'INFO' -Message ("Restart begin '{0}' reason={1}" -f $Name, $Reason)
    $stopR = Invoke-CliStop -CliPath $CliPath -Name $Name -PackagesRoot $PackagesRoot
    $runR = Invoke-CliRun -CliPath $CliPath -Name $Name -PackagesRoot $PackagesRoot

    $ok = ($runR.result -eq 'ok' -or $runR.result -eq 'partial')
    # 自动重启递增退避（压制风暴，直到健康恢复才复位）；
    # 用户显式重启复位退避，并清零失败计数（配合 health tick 的重启宽限期）
    $newBackoff = if ($isAutoReason) { $backoff + 1 } else { 0 }
    $null = Update-ManagerEntryState -ManagerRoot $ManagerRoot -Name $Name -Fields @{
        lastRestartAt             = $nowIso
        restartBackoffLevel       = $newBackoff
        lastRestartReason         = $Reason
        lastRestartDryRun         = $false
        lastRestartOk             = $ok
        lastStopResult            = $stopR.result
        lastRunResult             = $runR.result
        consecutiveHealthFailures = 0
        desiredEnabled            = $true
    }

    if (-not $ok) {
        Write-ManagerLog -ManagerRoot $ManagerRoot -Level 'WARN' -Message ("Restart '{0}' run result={1} error={2}" -f $Name, $runR.result, $runR.error)
    }

    return [ordered]@{
        ok      = $ok
        skipped = $false
        dryRun  = $false
        name    = $Name
        reason  = $Reason
        stop    = @{ result = $stopR.result; error = $stopR.error }
        run     = @{ result = $runR.result; error = $runR.error }
    }
}

function Reset-EntryBackoffOnHealthOk {
    param([string]$ManagerRoot, [string]$Name)
    $null = Update-ManagerEntryState -ManagerRoot $ManagerRoot -Name $Name -Fields @{
        consecutiveHealthFailures = 0
        restartBackoffLevel       = 0
        lastHealthOkAt            = (Get-Date).ToString('o')
    }
}
