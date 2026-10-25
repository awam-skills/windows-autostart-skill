#Requires -Version 5.1
<#
.SYNOPSIS
  Phase 3 Manager Core tests (self-contained; no Register-ScheduledTask required).

.DESCRIPTION
  Run on Windows PowerShell 5.1 / pwsh:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests-manager.ps1

  Uses -DryRun + TEMP manager/packages roots. Does not require a live HttpListener
  for core logic tests; contract tests assert route table and Restart pipeline symbols.
#>
[CmdletBinding()]
param(
    [switch]$SkipHttpContract
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:TestRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ManagerPs1 = Join-Path $script:TestRoot 'win-autostart-manager.ps1'
$script:Pass = 0
$script:Fail = 0
$script:Results = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        $script:Pass++
        $script:Results.Add("PASS: $Name")
        Write-Host "PASS: $Name" -ForegroundColor Green
    }
    else {
        $script:Fail++
        $script:Results.Add("FAIL: $Name")
        Write-Host "FAIL: $Name" -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    $ok = ($Expected -eq $Actual)
    if (-not $ok) {
        Write-Host ("  expected={0} actual={1}" -f $Expected, $Actual) -ForegroundColor Yellow
    }
    Assert-True -Condition $ok -Name $Name
}

# -----------------------------------------------------------------------------
# Load library
# -----------------------------------------------------------------------------
. $script:ManagerPs1 -LibraryOnly

$tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ('win-autostart-mgr-test-' + [guid]::NewGuid().ToString('N'))
$mgrRoot = Join-Path $tempBase '_manager'
$pkgRoot = Join-Path $tempBase 'packages'
New-Item -Path $pkgRoot -ItemType Directory -Force | Out-Null

$script:ManagerRoot = $mgrRoot
$script:ManagerDryRun = $true
$env:WIN_AUTOSTART_MANAGER_DRYRUN = '1'

# Stub CLI: count invocations; never touch real scheduler
$script:CliCalls = New-Object System.Collections.Generic.List[string]
$script:CliInvokeHook = {
    param($CliPath, $Arguments, $PackagesRoot)
    $joined = ($Arguments -join ' ')
    $script:CliCalls.Add($joined)
    $sub = $Arguments[0]
    $data = @{ name = 'stub' }
    if ($sub -eq 'list') {
        $data = @{ entries = @() }
    }
    return [ordered]@{
        ExitCode = 0
        Raw      = '{}'
        Stderr   = ''
        command  = $sub
        result   = 'ok'
        error    = $null
        data     = $data
        Envelope = $null
    }
}

try {
    # -------------------------------------------------------------------------
    # 1. init creates default jsons
    # -------------------------------------------------------------------------
    $paths = Initialize-ManagerConfig -ManagerRoot $mgrRoot
    Assert-True -Condition (Test-Path $paths.managerJson) -Name 'init creates manager.json'
    Assert-True -Condition (Test-Path $paths.watchesJson) -Name 'init creates watches.json'
    Assert-True -Condition (Test-Path $paths.stateJson) -Name 'init creates state.json'
    Assert-True -Condition (Test-Path $paths.managerLog) -Name 'init creates manager.log'

    $cfg = Read-ManagerConfig -ManagerRoot $mgrRoot
    Assert-Equal -Expected 'windows-autostart-manager/1' -Actual $cfg['schema'] -Name 'manager.json schema'
    Assert-equal -Expected '127.0.0.1' -Actual $cfg['listen'] -Name 'manager.json listen'
    Assert-equal -Expected 18765 -Actual ([int]$cfg['port']) -Name 'manager.json port'
    Assert-equal -Expected 30 -Actual ([int]$cfg['healthDefaultIntervalSec']) -Name 'manager.json healthDefaultIntervalSec'
    Assert-equal -Expected 30 -Actual ([int]$cfg['restartCooldownSec']) -Name 'manager.json restartCooldownSec'
    Assert-equal -Expected 300 -Actual ([int]$cfg['restartBackoffMaxSec']) -Name 'manager.json restartBackoffMaxSec'

    $watches = Read-WatchesDoc -ManagerRoot $mgrRoot
    Assert-Equal -Expected 'windows-autostart-watches/1' -Actual $watches['schema'] -Name 'watches.json schema'
    Assert-equal -Expected 800 -Actual ([int]$watches['debounceMs']) -Name 'watches.json debounceMs'

    # init is idempotent / does not wipe state
    $null = Update-ManagerEntryState -ManagerRoot $mgrRoot -Name 'keep-me' -Fields @{ desiredEnabled = $true; consecutiveHealthFailures = 2 }
    $null = Initialize-ManagerConfig -ManagerRoot $mgrRoot
    $kept = Get-ManagerEntryState -ManagerRoot $mgrRoot -Name 'keep-me'
    Assert-equal -Expected $true -Actual ([bool]$kept['desiredEnabled']) -Name 'init does not wipe desiredEnabled'
    Assert-equal -Expected 2 -Actual ([int]$kept['consecutiveHealthFailures']) -Name 'init does not wipe consecutiveHealthFailures'

    # -------------------------------------------------------------------------
    # 2. Contract: Restart pipeline + HttpListener routes
    # -------------------------------------------------------------------------
    Assert-True -Condition ($null -ne (Get-Command Restart-Entry -ErrorAction SilentlyContinue)) -Name 'Restart-Entry function exists'
    Assert-True -Condition ($null -ne (Get-Command Invoke-HealthTick -ErrorAction SilentlyContinue)) -Name 'Invoke-HealthTick function exists'
    Assert-True -Condition ($null -ne (Get-Command Invoke-WatchDebounceFlush -ErrorAction SilentlyContinue)) -Name 'Invoke-WatchDebounceFlush function exists'
    Assert-True -Condition ($null -ne (Get-Command Start-ManagerHttpListener -ErrorAction SilentlyContinue)) -Name 'Start-ManagerHttpListener function exists'

    $routes = Get-ManagerApiRouteTable
    $pathsNeeded = @(
        '/api/v1/health',
        '/api/v1/entries',
        '/api/v1/entries/{name}',
        '/api/v1/entries/{name}/start',
        '/api/v1/entries/{name}/stop',
        '/api/v1/entries/{name}/restart',
        '/api/v1/entries/{name}/enable',
        '/api/v1/entries/{name}/disable',
        '/api/v1/entries/{name}/keepalive',
        '/api/v1/watches'
    )
    $routePaths = @($routes | ForEach-Object { $_.Path })
    foreach ($need in $pathsNeeded) {
        Assert-True -Condition ($routePaths -contains $need) -Name ("API route listed: {0}" -f $need)
    }

    $src = Get-Content -Path $script:ManagerPs1 -Raw
    Assert-True -Condition ($src -match 'once-health') -Name 'manager.ps1 defines once-health'
    Assert-True -Condition ($src -match 'HttpListener|Start-ManagerHttpListener') -Name 'manager.ps1 wires HttpListener serve'

    $httpSrc = Get-Content -Path (Join-Path $script:TestRoot 'manager\HttpApi.ps1') -Raw
    Assert-True -Condition ($httpSrc -match 'System\.Net\.HttpListener') -Name 'HttpApi uses System.Net.HttpListener'
    Assert-True -Condition ($httpSrc -match 'X-Win-Autostart-Token') -Name 'HttpApi checks optional token header'

    # -------------------------------------------------------------------------
    # 3. Simulated health failure → consecutiveHealthFailures → restart at threshold
    # -------------------------------------------------------------------------
    $entryName = 'fake-health-entry'
    $entryDir = Join-Path $pkgRoot $entryName
    New-Item -Path $entryDir -ItemType Directory -Force | Out-Null
    # Use a port that should be closed (no listener). Pick high ephemeral-ish port.
    $closedPort = 59999
    $manifest = [ordered]@{
        schema    = 'windows-autostart/2'
        name      = $entryName
        command   = 'cmd.exe /c echo fake'
        workdir   = ''
        mode      = 'logon'
        landing   = 'startup'
        elevated  = $false
        root      = $entryDir
        createdAt = (Get-Date).ToString('o')
        keepalive = [ordered]@{
            taskRestart = $false
            process     = [ordered]@{
                enabled             = $false
                imageName           = $null
                commandLineContains = $null
            }
            health      = [ordered]@{
                enabled          = $true
                intervalSec      = 1
                failureThreshold = 3
                tcpPorts         = @($closedPort)
                http             = $null
            }
        }
    }
    ($manifest | ConvertTo-Json -Depth 8) | Set-Content -Path (Join-Path $entryDir ($entryName + '.json')) -Encoding UTF8

    $null = Update-ManagerEntryState -ManagerRoot $mgrRoot -Name $entryName -Fields @{
        desiredEnabled            = $true
        consecutiveHealthFailures = 0
        restartBackoffLevel       = 0
    }

    # Force TCP probe to always fail (portable; no dependency on OS port state)
    $script:TcpProbeHook = { param($HostName, $Port, $TimeoutMs) return $false }

    # Clear dry-run log
    $restartsLog = Join-Path $mgrRoot 'test-restarts.jsonl'
    if (Test-Path $restartsLog) { Remove-Item $restartsLog -Force }

    $cfg = Read-ManagerConfig -ManagerRoot $mgrRoot
    # Lower cooldown for test
    $cfg['restartCooldownSec'] = 1
    $cfg['restartBackoffMaxSec'] = 5

    $a1 = Invoke-HealthTick -ManagerRoot $mgrRoot -CliPath 'stub' -PackagesRoot $pkgRoot -DryRun -Cfg $cfg -ForceInterval
    $st1 = Get-ManagerEntryState -ManagerRoot $mgrRoot -Name $entryName
    Assert-equal -Expected 1 -Actual ([int]$st1['consecutiveHealthFailures']) -Name 'health tick 1 increments consecutiveHealthFailures'

    $a2 = Invoke-HealthTick -ManagerRoot $mgrRoot -CliPath 'stub' -PackagesRoot $pkgRoot -DryRun -Cfg $cfg -ForceInterval
    $st2 = Get-ManagerEntryState -ManagerRoot $mgrRoot -Name $entryName
    Assert-equal -Expected 2 -Actual ([int]$st2['consecutiveHealthFailures']) -Name 'health tick 2 increments consecutiveHealthFailures'

    $beforeRestartLines = 0
    if (Test-Path $restartsLog) {
        $beforeRestartLines = @(Get-Content $restartsLog).Count
    }

    $a3 = Invoke-HealthTick -ManagerRoot $mgrRoot -CliPath 'stub' -PackagesRoot $pkgRoot -DryRun -Cfg $cfg -ForceInterval
    $st3 = Get-ManagerEntryState -ManagerRoot $mgrRoot -Name $entryName
    Assert-equal -Expected 3 -Actual ([int]$st3['consecutiveHealthFailures']) -Name 'health tick 3 at threshold'
    Assert-True -Condition (Test-Path $restartsLog) -Name 'health threshold writes test-restarts.jsonl'
    $afterLines = @(Get-Content $restartsLog).Count
    Assert-True -Condition ($afterLines -gt $beforeRestartLines) -Name 'health threshold recorded dry-run restart'
    $lastLine = Get-Content $restartsLog -Tail 1
    Assert-True -Condition ($lastLine -match $entryName) -Name 'dry-run restart names the entry'
    Assert-True -Condition ($lastLine -match 'health') -Name 'dry-run restart reason is health'

    # Success resets
    $script:TcpProbeHook = { param($HostName, $Port, $TimeoutMs) return $true }
    $aOk = Invoke-HealthTick -ManagerRoot $mgrRoot -CliPath 'stub' -PackagesRoot $pkgRoot -DryRun -Cfg $cfg -ForceInterval
    $stOk = Get-ManagerEntryState -ManagerRoot $mgrRoot -Name $entryName
    Assert-equal -Expected 0 -Actual ([int]$stOk['consecutiveHealthFailures']) -Name 'health ok resets consecutiveHealthFailures'
    Assert-True -Condition ($null -ne $stOk['lastHealthOkAt']) -Name 'health ok sets lastHealthOkAt'

    # TCP/HTTP 通过时，process 失败不计入整体不健康（本机 CommandLine 常为空）
    $manifest.keepalive.process.enabled = $true
    $manifest.keepalive.process.imageName = 'python.exe'
    $manifest.keepalive.process.commandLineContains = 'never-match-this'
    ($manifest | ConvertTo-Json -Depth 8) | Set-Content -Path (Join-Path $entryDir ($entryName + '.json')) -Encoding UTF8
    $script:TcpProbeHook = { param($HostName, $Port, $TimeoutMs) return $true }
    $script:ProcessProbeHook = { param($ImageName, $CommandLineContains) return $false }
    $null = Update-ManagerEntryState -ManagerRoot $mgrRoot -Name $entryName -Fields @{
        consecutiveHealthFailures = 5
    }
    $aNet = Invoke-HealthTick -ManagerRoot $mgrRoot -CliPath 'stub' -PackagesRoot $pkgRoot -DryRun -Cfg $cfg -ForceInterval
    $stNet = Get-ManagerEntryState -ManagerRoot $mgrRoot -Name $entryName
    Assert-equal -Expected 0 -Actual ([int]$stNet['consecutiveHealthFailures']) -Name 'network ok overrides process fail'
    Assert-True -Condition ([string]$stNet['lastHealthDetail'] -match 'soft:process') -Name 'soft process recorded in detail'
    $script:ProcessProbeHook = $null
    $manifest.keepalive.process.enabled = $false
    ($manifest | ConvertTo-Json -Depth 8) | Set-Content -Path (Join-Path $entryDir ($entryName + '.json')) -Encoding UTF8

    # -------------------------------------------------------------------------
    # 4. Watch debounce → restart requested
    # -------------------------------------------------------------------------
    if (Test-Path $restartsLog) { Remove-Item $restartsLog -Force }
    $null = Update-ManagerEntryState -ManagerRoot $mgrRoot -Name $entryName -Fields @{
        desiredEnabled      = $true
        lastRestartAt       = $null
        restartBackoffLevel = 0
    }
    # Clear lastRestartAt properly
    $state = Read-ManagerStateDoc -ManagerRoot $mgrRoot
    if ($state.Entries.ContainsKey($entryName)) {
        $e = ConvertTo-PlainMap $state.Entries[$entryName]
        $e.Remove('lastRestartAt')
        $e['desiredEnabled'] = $true
        $e['restartBackoffLevel'] = 0
        $state.Entries[$entryName] = $e
        Save-ManagerStateDoc -ManagerRoot $mgrRoot -State $state
    }

    $wActions = Invoke-OnceWatchSimulation -ManagerRoot $mgrRoot -CliPath 'stub' -PackagesRoot $pkgRoot `
        -WatchId 'test-watch' -Targets @($entryName) -DebounceMs 50 -DryRun -Cfg $cfg
    Assert-True -Condition (Test-Path $restartsLog) -Name 'watch fire writes test-restarts.jsonl'
    $wLine = Get-Content $restartsLog -Tail 1
    Assert-True -Condition ($wLine -match $entryName) -Name 'watch restart targets entry'
    Assert-True -Condition ($wLine -match 'watch:test-watch') -Name 'watch restart reason includes watch id'
    $stW = Get-ManagerEntryState -ManagerRoot $mgrRoot -Name $entryName
    Assert-True -Condition ($null -ne $stW['lastWatchFireAt']) -Name 'watch sets lastWatchFireAt'

    # -------------------------------------------------------------------------
    # 5. desiredEnabled=false → health/watch skip restart
    # -------------------------------------------------------------------------
    if (Test-Path $restartsLog) { Remove-Item $restartsLog -Force }
    $null = Update-ManagerEntryState -ManagerRoot $mgrRoot -Name $entryName -Fields @{
        desiredEnabled            = $false
        consecutiveHealthFailures = 0
        restartBackoffLevel       = 0
    }
    $state = Read-ManagerStateDoc -ManagerRoot $mgrRoot
    $e = ConvertTo-PlainMap $state.Entries[$entryName]
    $e.Remove('lastRestartAt')
    $state.Entries[$entryName] = $e
    Save-ManagerStateDoc -ManagerRoot $mgrRoot -State $state

    $script:TcpProbeHook = { param($HostName, $Port, $TimeoutMs) return $false }
    $skipHealth = Invoke-HealthTick -ManagerRoot $mgrRoot -CliPath 'stub' -PackagesRoot $pkgRoot -DryRun -Cfg $cfg -ForceInterval
    $skipRow = @($skipHealth | Where-Object { $_.name -eq $entryName }) | Select-Object -First 1
    Assert-True -Condition ($null -ne $skipRow -and $skipRow.action -eq 'skip') -Name 'health skips when desiredEnabled=false'
    Assert-True -Condition (-not (Test-Path $restartsLog)) -Name 'health skip does not write restarts log'

    $skipWatch = Invoke-OnceWatchSimulation -ManagerRoot $mgrRoot -CliPath 'stub' -PackagesRoot $pkgRoot `
        -WatchId 'test-watch-disabled' -Targets @($entryName) -DebounceMs 0 -DryRun -Immediate -Cfg $cfg
    $sw = @($skipWatch | Where-Object { $_.target -eq $entryName }) | Select-Object -First 1
    Assert-True -Condition ($null -ne $sw -and $sw.action -eq 'skip') -Name 'watch skips when desiredEnabled=false'
    Assert-True -Condition (-not (Test-Path $restartsLog)) -Name 'watch skip does not write restarts log'

    # Direct Restart-Entry skip（自动触发才受 desiredEnabled 约束）
    $rr = Restart-Entry -ManagerRoot $mgrRoot -CliPath 'stub' -PackagesRoot $pkgRoot -Name $entryName -Reason 'health' -DryRun -Cfg $cfg
    Assert-True -Condition ([bool]$rr.skipped -and $rr.reason -eq 'desiredEnabled=false') -Name 'Restart-Entry skips desiredEnabled=false'

    # -------------------------------------------------------------------------
    # 6. Control-plane self-entry detection + deferred restart (no in-process stop)
    # -------------------------------------------------------------------------
    Assert-True -Condition ($null -ne (Get-Command Test-IsControlPlaneSelfEntry -ErrorAction SilentlyContinue)) -Name 'Test-IsControlPlaneSelfEntry exists'
    Assert-True -Condition ($null -ne (Get-Command Request-ManagerGracefulStop -ErrorAction SilentlyContinue)) -Name 'Request-ManagerGracefulStop exists'
    Assert-True -Condition ($null -ne (Get-Command Start-DeferredEntryRun -ErrorAction SilentlyContinue)) -Name 'Start-DeferredEntryRun exists'

    $selfName = 'win-autostart-manager-selftest'
    $selfDir = Join-Path $pkgRoot $selfName
    New-Item -Path $selfDir -ItemType Directory -Force | Out-Null
    $selfManifest = [ordered]@{
        schema  = 'windows-autostart/2'
        name    = $selfName
        command = ('"{0}" -NoProfile -File "{1}" serve' -f (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'), $script:ManagerPs1)
        landing = 'scheduled-task'
    }
    ($selfManifest | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $selfDir ($selfName + '.json')) -Encoding UTF8

    $prevMgrScript = $script:ManagerScriptPath
    $script:ManagerScriptPath = $script:ManagerPs1
    try {
        Assert-True -Condition (Test-IsControlPlaneSelfEntry -Name $selfName -PackagesRoot $pkgRoot) -Name 'self entry detected when command points at ManagerScriptPath'
        Assert-True -Condition (-not (Test-IsControlPlaneSelfEntry -Name $entryName -PackagesRoot $pkgRoot)) -Name 'normal entry is not self'

        $cliCalls = New-Object System.Collections.Generic.List[object]
        $deferredCalls = New-Object System.Collections.Generic.List[object]
        $script:CliInvokeHook = {
            param($CliPath, $Arguments, $PackagesRoot)
            $cliCalls.Add([ordered]@{ args = @($Arguments) })
            return [ordered]@{ result = 'ok'; error = $null; ExitCode = 0 }
        }
        $script:DeferredRunHook = {
            param($CliPath, $Name, $PackagesRoot, $ManagerRoot, $DelaySec, $WaitPortSec)
            $deferredCalls.Add([ordered]@{ name = $Name; cli = $CliPath })
        }
        $null = Update-ManagerEntryState -ManagerRoot $mgrRoot -Name $selfName -Fields @{
            desiredEnabled          = $true
            restartBackoffLevel     = 0
            consecutiveHealthFailures = 0
        }
        # clear lastRestartAt so cooldown does not skip
        $stSelf = Read-ManagerStateDoc -ManagerRoot $mgrRoot
        $eSelf = ConvertTo-PlainMap $stSelf.Entries[$selfName]
        $eSelf.Remove('lastRestartAt')
        $stSelf.Entries[$selfName] = $eSelf
        Save-ManagerStateDoc -ManagerRoot $mgrRoot -State $stSelf

        # 文件级 ManagerDryRun=1：自重启应走 deferred dry-run，不写 STOP、不调 CLI
        $rrSelfDry = Restart-Entry -ManagerRoot $mgrRoot -CliPath 'stub-cli.ps1' -PackagesRoot $pkgRoot -Name $selfName -Reason 'api' -Cfg $cfg
        Assert-True -Condition ([bool]$rrSelfDry['ok'] -and [bool]$rrSelfDry['deferred'] -and [bool]$rrSelfDry['selfRestart'] -and [bool]$rrSelfDry['dryRun']) -Name 'self restart dry-run returns deferred ok'
        Assert-True -Condition ($cliCalls.Count -eq 0) -Name 'self dry-run does not call in-process CLI'
        Assert-True -Condition ($deferredCalls.Count -eq 0) -Name 'self dry-run does not spawn deferred run'
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $mgrRoot 'STOP'))) -Name 'self dry-run does not write STOP'

        # 关闭 dry-run 后应调度延迟 run 并写 STOP
        $prevDry = $script:ManagerDryRun
        $script:ManagerDryRun = $false
        Remove-Item Env:WIN_AUTOSTART_MANAGER_DRYRUN -ErrorAction SilentlyContinue
        $stSelf2 = Read-ManagerStateDoc -ManagerRoot $mgrRoot
        $eSelf2 = ConvertTo-PlainMap $stSelf2.Entries[$selfName]
        $eSelf2.Remove('lastRestartAt')
        $eSelf2['restartBackoffLevel'] = 0
        $stSelf2.Entries[$selfName] = $eSelf2
        Save-ManagerStateDoc -ManagerRoot $mgrRoot -State $stSelf2

        $rrSelf = Restart-Entry -ManagerRoot $mgrRoot -CliPath 'stub-cli.ps1' -PackagesRoot $pkgRoot -Name $selfName -Reason 'api' -Cfg $cfg
        Assert-True -Condition ([bool]$rrSelf['ok'] -and [bool]$rrSelf['deferred'] -and [bool]$rrSelf['selfRestart'] -and -not [bool]$rrSelf['dryRun']) -Name 'self restart returns deferred ok'
        Assert-True -Condition ($cliCalls.Count -eq 0) -Name 'self restart does not call in-process CLI stop/run'
        Assert-True -Condition ($deferredCalls.Count -eq 1) -Name 'self restart schedules deferred run'
        $stopFile = Join-Path $mgrRoot 'STOP'
        Assert-True -Condition (Test-Path -LiteralPath $stopFile -PathType Leaf) -Name 'self restart writes STOP for graceful exit'
        Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
        $script:ManagerDryRun = $prevDry
        $env:WIN_AUTOSTART_MANAGER_DRYRUN = '1'
    }
    finally {
        $script:ManagerScriptPath = $prevMgrScript
        $script:CliInvokeHook = $null
        $script:DeferredRunHook = $null
    }

    # -------------------------------------------------------------------------
    # 7. 意图协议：显式(api)重启绕过 desiredEnabled/cooldown 闸门并复位退避；
    #    自动(health)重启仍受限；重启宽限期内健康失败不计数、不触发重启
    # -------------------------------------------------------------------------
    # 7a. api 重启在 desiredEnabled=false 时不被跳过（操作者显式意图）
    $rrApi = Restart-Entry -ManagerRoot $mgrRoot -CliPath 'stub' -PackagesRoot $pkgRoot -Name $entryName -Reason 'api' -DryRun -Cfg $cfg
    Assert-True -Condition (-not [bool]$rrApi.skipped) -Name 'api restart bypasses desiredEnabled=false skip'

    # 7b. api 重启在冷却窗口内不被拦截，且复位退避
    $null = Update-ManagerEntryState -ManagerRoot $mgrRoot -Name $entryName -Fields @{
        desiredEnabled      = $true
        lastRestartAt       = (Get-Date).ToString('o')
        restartBackoffLevel = 3
    }
    $rrApi2 = Restart-Entry -ManagerRoot $mgrRoot -CliPath 'stub' -PackagesRoot $pkgRoot -Name $entryName -Reason 'api' -DryRun -Cfg $cfg
    Assert-True -Condition (-not [bool]$rrApi2.skipped) -Name 'api restart bypasses cooldown'
    $stApi2 = Get-ManagerEntryState -ManagerRoot $mgrRoot -Name $entryName
    Assert-equal -Expected 0 -Actual ([int]$stApi2['restartBackoffLevel']) -Name 'api restart resets backoff'

    # 7c. health 自动重启在冷却窗口内仍被拦截（退避 3 → 冷却 8s）
    $null = Update-ManagerEntryState -ManagerRoot $mgrRoot -Name $entryName -Fields @{
        lastRestartAt       = (Get-Date).ToString('o')
        restartBackoffLevel = 3
    }
    $rrHealth = Restart-Entry -ManagerRoot $mgrRoot -CliPath 'stub' -PackagesRoot $pkgRoot -Name $entryName -Reason 'health' -DryRun -Cfg $cfg
    Assert-True -Condition ([bool]$rrHealth.skipped -and $rrHealth.reason -eq 'cooldown') -Name 'health restart still honors cooldown'

    # 7d. 重启宽限期：启动窗口内探针失败 → action=grace，失败计数保持 0，不写重启日志
    $script:TcpProbeHook = { param($HostName, $Port, $TimeoutMs) return $false }
    $null = Update-ManagerEntryState -ManagerRoot $mgrRoot -Name $entryName -Fields @{
        desiredEnabled            = $true
        consecutiveHealthFailures = 0
        lastRestartAt             = (Get-Date).ToString('o')
    }
    if (Test-Path $restartsLog) { Remove-Item $restartsLog -Force }
    $gActions = Invoke-HealthTick -ManagerRoot $mgrRoot -CliPath 'stub' -PackagesRoot $pkgRoot -DryRun -Cfg $cfg -ForceInterval
    $gRow = @($gActions | Where-Object { $_.name -eq $entryName }) | Select-Object -First 1
    Assert-True -Condition ($null -ne $gRow -and $gRow.action -eq 'grace') -Name 'health tick returns grace after restart'
    $stGrace = Get-ManagerEntryState -ManagerRoot $mgrRoot -Name $entryName
    Assert-equal -Expected 0 -Actual ([int]$stGrace['consecutiveHealthFailures']) -Name 'grace does not count failures'
    Assert-True -Condition (-not (Test-Path $restartsLog)) -Name 'grace does not write restarts log'

    # 7e. 宽限期过后恢复正常失败计数（把 lastRestartAt 拨回 60s 前）
    $null = Update-ManagerEntryState -ManagerRoot $mgrRoot -Name $entryName -Fields @{
        lastRestartAt             = (Get-Date).AddSeconds(-60).ToString('o')
        consecutiveHealthFailures = 0
    }
    $postGrace = Invoke-HealthTick -ManagerRoot $mgrRoot -CliPath 'stub' -PackagesRoot $pkgRoot -DryRun -Cfg $cfg -ForceInterval
    $pgRow = @($postGrace | Where-Object { $_.name -eq $entryName }) | Select-Object -First 1
    $stPg = Get-ManagerEntryState -ManagerRoot $mgrRoot -Name $entryName
    Assert-True -Condition ($null -ne $pgRow -and $pgRow.action -eq 'fail') -Name 'post-grace tick counts failure again'
    Assert-equal -Expected 1 -Actual ([int]$stPg['consecutiveHealthFailures']) -Name 'post-grace failure increments'
    $script:TcpProbeHook = $null

    # -------------------------------------------------------------------------
    # Bonus: register-manager.ps1 exists and mentions ADR-0003 / no silent fallback
    # -------------------------------------------------------------------------
    $regPath = Join-Path $script:TestRoot 'register-manager.ps1'
    Assert-True -Condition (Test-Path $regPath) -Name 'register-manager.ps1 exists'
    $regSrc = Get-Content -Path $regPath -Raw
    Assert-True -Condition ($regSrc -match 'ADR-0003' -or $regSrc -match 'silent') -Name 'register-manager documents no silent fallback'
    Assert-True -Condition ($regSrc -match 'scheduled-task') -Name 'register-manager uses scheduled-task landing'
    Assert-True -Condition ($regSrc -match 'win-autostart-manager') -Name 'register-manager names win-autostart-manager'
}
finally {
    $script:CliInvokeHook = $null
    $script:TcpProbeHook = $null
    $script:HttpProbeHook = $null
    $script:ProcessProbeHook = $null
    Remove-Item -Path $tempBase -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:WIN_AUTOSTART_MANAGER_DRYRUN -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("Manager tests: {0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) {
    exit 1
}
exit 0
