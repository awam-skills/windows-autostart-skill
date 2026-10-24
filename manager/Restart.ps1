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

    if (-not (Test-EntryDesiredEnabled -ManagerRoot $ManagerRoot -Name $Name)) {
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

    if ($slice.ContainsKey('lastRestartAt') -and $slice['lastRestartAt']) {
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

    if ($useDry) {
        Write-DryRunRestartIntent -ManagerRoot $ManagerRoot -Name $Name -Reason $Reason
        Write-ManagerLog -ManagerRoot $ManagerRoot -Level 'INFO' -Message ("Restart DRYRUN '{0}' reason={1}" -f $Name, $Reason)
        $newBackoff = $backoff + 1
        Update-ManagerEntryState -ManagerRoot $ManagerRoot -Name $Name -Fields @{
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
    $newBackoff = if ($ok) { $backoff + 1 } else { $backoff + 1 }  # bump until health ok resets
    Update-ManagerEntryState -ManagerRoot $ManagerRoot -Name $Name -Fields @{
        lastRestartAt       = $nowIso
        restartBackoffLevel = $newBackoff
        lastRestartReason   = $Reason
        lastRestartDryRun   = $false
        lastRestartOk       = $ok
        lastStopResult      = $stopR.result
        lastRunResult       = $runR.result
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
    Update-ManagerEntryState -ManagerRoot $ManagerRoot -Name $Name -Fields @{
        consecutiveHealthFailures = 0
        restartBackoffLevel       = 0
        lastHealthOkAt            = (Get-Date).ToString('o')
    }
}
