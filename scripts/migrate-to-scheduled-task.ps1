#Requires -Version 5.1
<#
.SYNOPSIS
  Migrate .win-autostart packages to Scheduled Task landing + Manager keepalive.

.DESCRIPTION
  Phase 5 control-plane migration helper (replaces the old "create task + leave
  package watchdogs" guidance).

  For each package under %USERPROFILE%\.win-autostart\<name>\<name>.json:
    1. Ensure Scheduled Task landing with standard RestartCount=999 / Interval=1min
       (prefer windows-autostart.ps1 enable/add helpers when available; otherwise
       Register-ScheduledTask with the same settings as New-AutostartTaskSettings).
    2. Set manifest schema windows-autostart/2, landing=scheduled-task,
       keepalive.taskRestart=true (process/health left for Manager / operator).
    3. Remove per-package *-watchdog.vbs and matching Startup shortcuts.
    4. Do NOT create new package-local watchdogs — keepalive belongs to Manager
       (process/health probes + watches.json).

.NOTES
  Prefer elevated PowerShell when registering/updating tasks.
  Live packages are runtime state; this script does not commit them to git.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$PackagesRoot = $(Join-Path $env:USERPROFILE '.win-autostart'),
    [string]$CliPath = '',
    [switch]$ForceTaskReregister
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Get-NewAutostartTaskSettings {
    # Mirror CLI New-AutostartTaskSettings / ADR-0005 baseline.
    return (New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew)
}

function Get-DefaultKeepalive([string]$Landing) {
    return [ordered]@{
        taskRestart = ($Landing -eq 'scheduled-task')
        process     = [ordered]@{
            enabled             = $false
            imageName           = $null
            commandLineContains = $null
        }
        health      = [ordered]@{
            enabled          = $false
            intervalSec      = 30
            failureThreshold = 3
            tcpPorts         = @()
            http             = $null
        }
    }
}

function Write-Utf8Json([string]$Path, $Doc) {
    $json = $Doc | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($Path, $json + "`r`n", (New-Object System.Text.UTF8Encoding $false))
}

function Update-ManifestForControlPlane {
    param([string]$JsonPath, [string]$Landing = 'scheduled-task')
    $raw = Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $map = [ordered]@{}
    foreach ($p in $raw.PSObject.Properties) { $map[$p.Name] = $p.Value }
    $map['schema'] = 'windows-autostart/2'
    $map['landing'] = $Landing
    if (-not $map.Contains('keepalive') -or $null -eq $map['keepalive']) {
        $map['keepalive'] = Get-DefaultKeepalive -Landing $Landing
    } else {
        $ka = @{}
        foreach ($p in $map['keepalive'].PSObject.Properties) { $ka[$p.Name] = $p.Value }
        $ka['taskRestart'] = ($Landing -eq 'scheduled-task')
        $map['keepalive'] = $ka
    }
    Write-Utf8Json -Path $JsonPath -Doc $map
}

$startupDir  = [Environment]::GetFolderPath('Startup')
$currentUser = "$env:USERDOMAIN\$env:USERNAME"

Write-Host "=== win-autostart Phase 5 migration (Scheduled Task + Manager) ===" -ForegroundColor Cyan
Write-Host "PackagesRoot: $PackagesRoot"
Write-Host "Startup:      $startupDir"
Write-Host "User:         $currentUser"
Write-Host ""

if (-not $CliPath) {
    $here = $PSScriptRoot
    $candidates = @(
        (Join-Path (Split-Path $here -Parent) 'windows-autostart.ps1'),
        (Join-Path $here 'windows-autostart.ps1'),
        (Join-Path (Split-Path $here -Parent) 'skills\windows-autostart\windows-autostart.ps1')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { $CliPath = $c; break }
    }
}

$services = @()
Get-ChildItem -LiteralPath $PackagesRoot -Directory -ErrorAction Stop |
    Where-Object { $_.Name -ne '_manager' } |
    ForEach-Object {
        $jsonPath = Join-Path $_.FullName ($_.Name + '.json')
        if (Test-Path -LiteralPath $jsonPath) {
            $services += [pscustomobject]@{
                Name     = $_.Name
                Dir      = $_.FullName
                JsonPath = $jsonPath
                VbsPath  = Join-Path $_.FullName ($_.Name + '.vbs')
                Watchdog = Join-Path $_.FullName ($_.Name + '-watchdog.vbs')
            }
        }
    }

Write-Host "Found $($services.Count) package(s): $($services.Name -join ', ')"
Write-Host ""

foreach ($svc in $services) {
    Write-Host "--- $($svc.Name) ---" -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $svc.VbsPath)) {
        Write-Warning "  VBS missing: $($svc.VbsPath) — skip task rewrite; still update manifest/watchdog cleanup"
    } else {
        $existing = Get-ScheduledTask -TaskName $svc.Name -ErrorAction SilentlyContinue
        $needRegister = $ForceTaskReregister -or ($null -eq $existing)
        if ($needRegister -and $PSCmdlet.ShouldProcess($svc.Name, 'Register-ScheduledTask')) {
            $action    = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $svc.VbsPath)
            $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
            $settings  = Get-NewAutostartTaskSettings
            $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
            Register-ScheduledTask `
                -TaskName $svc.Name `
                -Action $action `
                -Trigger $trigger `
                -Settings $settings `
                -Principal $principal `
                -Description ("win-autostart: {0} (auto-start + crash-restart)" -f $svc.Name) `
                -Force | Out-Null
            Write-Host "  [OK] Scheduled task registered/refreshed" -ForegroundColor Green
        } elseif ($null -ne $existing) {
            # Ensure restart settings without full recreate when possible
            try {
                $existing.Settings.RestartCount = 999
                $existing.Settings.RestartInterval = 'PT1M'
                $existing.Settings.ExecutionTimeLimit = 'PT0S'
                Set-ScheduledTask -InputObject $existing | Out-Null
                Write-Host "  [OK] Ensured RestartCount=999 / PT1M on existing task" -ForegroundColor Green
            } catch {
                Write-Warning "  Could not patch task settings: $($_.Exception.Message). Re-run with -ForceTaskReregister."
            }
        }
    }

    if ($PSCmdlet.ShouldProcess($svc.JsonPath, 'Update manifest landing/keepalive')) {
        Update-ManifestForControlPlane -JsonPath $svc.JsonPath -Landing 'scheduled-task'
        Write-Host "  [OK] Manifest -> schema v2, landing=scheduled-task, taskRestart=true" -ForegroundColor Green
    }

    # Remove Startup shortcut for the package
    $lnk = Join-Path $startupDir ($svc.Name + '.lnk')
    if (Test-Path -LiteralPath $lnk) {
        if ($PSCmdlet.ShouldProcess($lnk, 'Remove Startup shortcut')) {
            Remove-Item -LiteralPath $lnk -Force
            Write-Host "  [OK] Removed Startup shortcut" -ForegroundColor Yellow
        }
    }

    # Remove package-local watchdog + Startup variants
    $watchdogCandidates = @(
        $svc.Watchdog,
        (Join-Path $svc.Dir ($svc.Name + '-watchdog.vbs')),
        (Join-Path $svc.Dir 'litellm-watchdog.vbs')
    ) | Select-Object -Unique

    foreach ($w in $watchdogCandidates) {
        if (Test-Path -LiteralPath $w) {
            Get-CimInstance Win32_Process -Filter "Name='wscript.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and $_.CommandLine -like ('*{0}*' -f [IO.Path]::GetFileName($w)) } |
                ForEach-Object {
                    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                    Write-Host "  [OK] Stopped watchdog PID=$($_.ProcessId)" -ForegroundColor Yellow
                }
            if ($PSCmdlet.ShouldProcess($w, 'Delete package watchdog')) {
                Remove-Item -LiteralPath $w -Force
                Write-Host "  [OK] Deleted $($w)" -ForegroundColor Yellow
            }
        }
    }

    Get-ChildItem -LiteralPath $startupDir -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like ("*{0}*watchdog*" -f $svc.Name) -or $_.Name -like '*watchdog*' } |
        ForEach-Object {
            if ($_.Name -match [regex]::Escape($svc.Name) -or $_.Name -match 'watchdog') {
                if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove Startup watchdog remnant')) {
                    Remove-Item -LiteralPath $_.FullName -Force
                    Write-Host "  [OK] Removed Startup remnant $($_.Name)" -ForegroundColor Yellow
                }
            }
        }

    Write-Host "  [NOTE] Configure Manager process/health + watches via panel/API — do not add new *-watchdog.vbs" -ForegroundColor DarkGray
    Write-Host ""
}

Write-Host "=== Verification ===" -ForegroundColor Cyan
Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName -in $services.Name } |
    Select-Object TaskName, State, @{n='RestartCount';e={$_.Settings.RestartCount}} |
    Format-Table -AutoSize

Write-Host ""
Write-Host "Done. Prefer Manager health/process over package-external keepalive tasks." -ForegroundColor Green
if ($CliPath) {
    Write-Host "CLI: powershell -NoProfile -ExecutionPolicy Bypass -File `"$CliPath`" list" -ForegroundColor Gray
}
