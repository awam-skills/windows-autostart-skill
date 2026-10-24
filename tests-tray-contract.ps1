#Requires -Version 5.1
<#
.SYNOPSIS
  Phase 4 tray/panel contract tests (no GUI automation).

.DESCRIPTION
  Asserts: static index exists; PAUSE honored by once-health / watch flush;
  keepalive routes listed; Resolve-ManagerWwwRoot finds tray/www.
  Keep this file ASCII-only so Windows PowerShell 5.1 parses it under any code page.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:TestRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ManagerPs1 = Join-Path $script:TestRoot 'win-autostart-manager.ps1'
$script:Pass = 0
$script:Fail = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        $script:Pass++
        Write-Host "PASS: $Name" -ForegroundColor Green
    }
    else {
        $script:Fail++
        Write-Host "FAIL: $Name" -ForegroundColor Red
    }
}

. $script:ManagerPs1 -LibraryOnly

$tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ('win-autostart-tray-test-' + [guid]::NewGuid().ToString('N'))
$mgrRoot = Join-Path $tempBase '_manager'
$pkgRoot = Join-Path $tempBase 'packages'
New-Item -Path $pkgRoot -ItemType Directory -Force | Out-Null
$script:ManagerRoot = $mgrRoot
$script:ManagerDryRun = $true
$env:WIN_AUTOSTART_MANAGER_DRYRUN = '1'

$script:CliInvokeHook = {
    param($CliPath, $Arguments, $PackagesRoot)
    return [ordered]@{
        ExitCode = 0; Raw = '{}'; Stderr = ''; command = $Arguments[0]
        result = 'ok'; error = $null; data = @{ entries = @() }; Envelope = $null
    }
}

try {
    $null = Initialize-ManagerConfig -ManagerRoot $mgrRoot

    # --- static www ---
    $index = Join-Path $script:TestRoot 'tray\www\index.html'
    if (-not (Test-Path $index)) { $index = Join-Path $script:TestRoot 'tray/www/index.html' }
    Assert-True -Condition (Test-Path -Path $index -PathType Leaf) -Name 'tray/www/index.html exists'
    # Read as UTF-8 bytes so content checks work regardless of console code page
    $indexBytes = [System.IO.File]::ReadAllBytes($index)
    $indexSrc = [System.Text.Encoding]::UTF8.GetString($indexBytes)
    Assert-True -Condition ($indexSrc -match 'lang="zh-CN"' -and $indexSrc -match 'keepalive' -and $indexSrc -match 'entriesTable') -Name 'index.html has panel markup (zh-CN + keepalive)'

    $www = Resolve-ManagerWwwRoot -ManagerScriptPath $script:ManagerPs1 -Override $null
    Assert-True -Condition ([bool]$www) -Name 'Resolve-ManagerWwwRoot finds tray/www'
    if ($www) {
        Assert-True -Condition (Test-Path (Join-Path $www 'index.html')) -Name 'resolved WwwRoot contains index.html'
    }

    # --- path segments: unary-comma return must not be re-wrapped with @() ---
    $segsHealth = Get-ApiPathSegments -AbsolutePath '/api/v1/health'
    Assert-True -Condition ($segsHealth -is [string[]] -and $segsHealth.Count -eq 3 -and $segsHealth[0] -eq 'api' -and $segsHealth[2] -eq 'health') -Name 'Get-ApiPathSegments /api/v1/health -> 3 parts'
    $segsRoot = Get-ApiPathSegments -AbsolutePath '/'
    Assert-True -Condition ($segsRoot -is [string[]] -and $segsRoot.Count -eq 0) -Name 'Get-ApiPathSegments / -> empty string[]'

    # --- route symbols ---
    $routes = Get-ManagerApiRouteTable
    $paths = @($routes | ForEach-Object { $_.Path })
    Assert-True -Condition ($paths -contains '/api/v1/entries/{name}/keepalive') -Name 'API route keepalive GET/PUT listed'
    Assert-True -Condition ($paths -contains '/api/v1/pause') -Name 'API route pause listed'
    $httpSrc = Get-Content -Path (Join-Path $script:TestRoot 'manager/HttpApi.ps1') -Raw -Encoding UTF8
    Assert-True -Condition ($httpSrc -match 'Invoke-KeepaliveApi|Write-EntryKeepalive') -Name 'HttpApi defines keepalive helpers'
    Assert-True -Condition ($httpSrc -match 'Send-StaticWwwFile') -Name 'HttpApi serves static www'

    # --- keepalive read/write on fake manifest ---
    $entryName = 'ka-entry'
    $entryDir = Join-Path $pkgRoot $entryName
    New-Item -Path $entryDir -ItemType Directory -Force | Out-Null
    $mf = [ordered]@{
        schema   = 'windows-autostart/2'
        name     = $entryName
        command  = 'cmd.exe /c echo x'
        landing  = 'startup'
        keepalive = [ordered]@{
            taskRestart = $false
            process = [ordered]@{ enabled = $false; imageName = $null; commandLineContains = $null }
            health  = [ordered]@{ enabled = $false; intervalSec = 30; failureThreshold = 3; tcpPorts = @(); http = $null }
        }
    }
    ($mf | ConvertTo-Json -Depth 8) | Set-Content -Path (Join-Path $entryDir ($entryName + '.json')) -Encoding UTF8

    $r = Read-EntryKeepalive -PackagesRoot $pkgRoot -Name $entryName
    Assert-True -Condition ([bool]$r.ok) -Name 'Read-EntryKeepalive ok'
    $w = Write-EntryKeepalive -PackagesRoot $pkgRoot -Name $entryName -KeepaliveBody @{
        process = @{ enabled = $true; imageName = 'python.exe'; commandLineContains = 'demo' }
        health  = @{ enabled = $true; intervalSec = 15; failureThreshold = 2; tcpPorts = @(4010); http = @{ url = 'http://127.0.0.1:4010/h'; expectStatus = @(200) } }
    }
    Assert-True -Condition ([bool]$w.ok) -Name 'Write-EntryKeepalive ok'
    $r2 = Read-EntryKeepalive -PackagesRoot $pkgRoot -Name $entryName
    $proc = ConvertTo-PlainMap $r2.keepalive.process
    Assert-True -Condition ([bool]$proc['enabled'] -eq $true) -Name 'keepalive process.enabled persisted'
    $health = ConvertTo-PlainMap $r2.keepalive.health
    Assert-True -Condition ([int]$health['intervalSec'] -eq 15) -Name 'keepalive health.intervalSec persisted'

    # --- PAUSE skips health restarts ---
    $null = Update-ManagerEntryState -ManagerRoot $mgrRoot -Name $entryName -Fields @{
        desiredEnabled = $true
        consecutiveHealthFailures = 0
        restartBackoffLevel = 0
    }
    $null = Write-EntryKeepalive -PackagesRoot $pkgRoot -Name $entryName -KeepaliveBody @{
        health = @{ enabled = $true; intervalSec = 1; failureThreshold = 1; tcpPorts = @(59998); http = $null }
        process = @{ enabled = $false }
    }
    $script:TcpProbeHook = { param($HostName, $Port, $TimeoutMs) return $false }
    $cfg = Read-ManagerConfig -ManagerRoot $mgrRoot
    $cfg['restartCooldownSec'] = 1

    Set-ManagerPaused -ManagerRoot $mgrRoot -Paused $true
    Assert-True -Condition (Test-ManagerPaused -ManagerRoot $mgrRoot) -Name 'PAUSE file present after Set-ManagerPaused'

    $restartsLog = Join-Path $mgrRoot 'test-restarts.jsonl'
    if (Test-Path $restartsLog) { Remove-Item $restartsLog -Force }

    $pausedActions = Invoke-HealthTick -ManagerRoot $mgrRoot -CliPath 'stub' -PackagesRoot $pkgRoot -DryRun -Cfg $cfg -ForceInterval
    $pauseRow = @($pausedActions | Where-Object { $_.detail -eq 'paused' -or $_.action -eq 'skip' }) | Select-Object -First 1
    Assert-True -Condition ($null -ne $pauseRow) -Name 'once-health skips when PAUSE present'
    Assert-True -Condition (-not (Test-Path $restartsLog)) -Name 'PAUSE does not write test-restarts.jsonl'

    $wPaused = Invoke-OnceWatchSimulation -ManagerRoot $mgrRoot -CliPath 'stub' -PackagesRoot $pkgRoot `
        -WatchId 'p1' -Targets @($entryName) -DebounceMs 0 -DryRun -Immediate -Cfg $cfg
    $wp = @($wPaused | Where-Object { $_.detail -eq 'paused' }) | Select-Object -First 1
    Assert-True -Condition ($null -ne $wp) -Name 'watch flush skips when PAUSE present'

    Set-ManagerPaused -ManagerRoot $mgrRoot -Paused $false
    Assert-True -Condition (-not (Test-ManagerPaused -ManagerRoot $mgrRoot)) -Name 'PAUSE cleared on resume'

    if (Test-Path $restartsLog) { Remove-Item $restartsLog -Force }
    $state = Read-ManagerStateDoc -ManagerRoot $mgrRoot
    if ($state.Entries.ContainsKey($entryName)) {
        $e = ConvertTo-PlainMap $state.Entries[$entryName]
        $e.Remove('lastRestartAt')
        $e['consecutiveHealthFailures'] = 0
        $e['desiredEnabled'] = $true
        $state.Entries[$entryName] = $e
        Save-ManagerStateDoc -ManagerRoot $mgrRoot -State $state
    }
    $null = Invoke-HealthTick -ManagerRoot $mgrRoot -CliPath 'stub' -PackagesRoot $pkgRoot -DryRun -Cfg $cfg -ForceInterval
    Assert-True -Condition (Test-Path $restartsLog) -Name 'after resume, health threshold can restart'

    # --- tray project files ---
    $csproj = Join-Path $script:TestRoot 'tray/WinAutostartTray/WinAutostartTray.csproj'
    Assert-True -Condition (Test-Path $csproj) -Name 'WinAutostartTray.csproj exists'
    $csprojSrc = Get-Content $csproj -Raw -Encoding UTF8
    Assert-True -Condition ($csprojSrc -match 'net8.0-windows') -Name 'tray targets net8.0-windows'
    $trayCs = Join-Path $script:TestRoot 'tray/WinAutostartTray/TrayApplicationContext.cs'
    Assert-True -Condition (Test-Path $trayCs) -Name 'TrayApplicationContext.cs exists'
    $trayBytes = [System.IO.File]::ReadAllBytes($trayCs)
    $traySrc = [System.Text.Encoding]::UTF8.GetString($trayBytes)
    # U+6253 U+5F00 U+9762 U+677F = open panel (Chinese menu label)
    $openPanel = [string]::new(@([char]0x6253, [char]0x5F00, [char]0x9762, [char]0x677F))
    Assert-True -Condition ($traySrc.Contains($openPanel) -and $traySrc -match 'PAUSE' -and $traySrc -match 'STOP') -Name 'tray menu open-panel + PAUSE/STOP'
    Assert-True -Condition (Test-Path (Join-Path $script:TestRoot 'tray/README.md')) -Name 'tray/README.md exists'
    Assert-True -Condition (Test-Path (Join-Path $script:TestRoot 'docs/manual-acceptance-phase4.md')) -Name 'manual acceptance doc exists'
}
catch {
    Write-Host ("FAIL: tray contract exception: " + $_.Exception.Message) -ForegroundColor Red
    $script:Fail++
}
finally {
    $script:CliInvokeHook = $null
    $script:TcpProbeHook = $null
    Remove-Item -Path $tempBase -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:WIN_AUTOSTART_MANAGER_DRYRUN -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("Tray contract tests: {0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
