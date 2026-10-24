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

    # Direct Restart-Entry skip
    $rr = Restart-Entry -ManagerRoot $mgrRoot -CliPath 'stub' -PackagesRoot $pkgRoot -Name $entryName -Reason 'manual' -DryRun -Cfg $cfg
    Assert-True -Condition ([bool]$rr.skipped -and $rr.reason -eq 'desiredEnabled=false') -Name 'Restart-Entry skips desiredEnabled=false'

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
