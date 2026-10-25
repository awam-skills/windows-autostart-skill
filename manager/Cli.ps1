#Requires -Version 5.1
# Invoke registration-plane CLI and parse JSON envelope.

Set-StrictMode -Version 2.0

# Short-TTL cache for CLI status results: panel refreshes hit the cache instead
# of spawning a fresh powershell.exe per request. Mutating actions call
# Clear-CliStatusCache so the next read sees fresh state.
$script:CliStatusCacheTtlSec = 4
$script:CliStatusCache = @{}

function Resolve-AutostartCliPath {
    param([string]$CliPath, [string]$ManagerScriptPath)
    if ($CliPath -and (Test-Path -Path $CliPath -PathType Leaf)) {
        return (Resolve-Path -Path $CliPath).Path
    }
    $sibling = Join-Path (Split-Path -Parent $ManagerScriptPath) 'windows-autostart.ps1'
    if (Test-Path -Path $sibling -PathType Leaf) {
        return (Resolve-Path -Path $sibling).Path
    }
    throw "windows-autostart.ps1 not found (sibling of manager or -CliPath). Looked at: $sibling"
}

function Get-PowerShellHostExe {
    # Prefer Windows PowerShell 5.1 for ScheduledTask / CIM parity with CLI.
    $sys = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -Path $sys -PathType Leaf) { return $sys }
    if (Get-Command -Name pwsh -ErrorAction SilentlyContinue) {
        return (Get-Command pwsh).Source
    }
    if (Get-Command -Name powershell -ErrorAction SilentlyContinue) {
        return (Get-Command powershell).Source
    }
    throw 'No powershell.exe / pwsh found to host the registration CLI.'
}

function Invoke-AutostartCli {
    <#
      Run: powershell -NoProfile -File <cli> <args>
      Returns parsed envelope hashtable: command/result/error/data (+ ExitCode, Raw).
      When $script:CliInvokeHook is set (tests), call that instead.
    #>
    param(
        [string]$CliPath,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [string]$PackagesRoot
    )

    if ($script:CliInvokeHook -is [scriptblock]) {
        return & $script:CliInvokeHook -CliPath $CliPath -Arguments $Arguments -PackagesRoot $PackagesRoot
    }

    $exe = Get-PowerShellHostExe
    $argList = New-Object System.Collections.Generic.List[string]
    $argList.Add('-NoProfile')
    $argList.Add('-ExecutionPolicy')
    $argList.Add('Bypass')
    $argList.Add('-File')
    $argList.Add($CliPath)
    foreach ($a in @($Arguments)) { $argList.Add([string]$a) }
    if ($PackagesRoot) {
        # Most mutating/list commands accept -Root as packages parent
        if ($Arguments -notcontains '-Root') {
            $argList.Add('-Root')
            $argList.Add($PackagesRoot)
        }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    # ProcessStartInfo.Arguments quoting: join with spaces; quote args with spaces
    $quoted = foreach ($a in $argList) {
        if ($a -match '[\s"]') {
            '"' + ($a -replace '"', '\"') + '"'
        }
        else { $a }
    }
    $psi.Arguments = ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    $envelope = $null
    $parseError = $null
    try {
        # CLI prints one JSON object; take last non-empty line if warnings precede it
        $text = $stdout.Trim()
        if ($text) {
            $envelope = $text | ConvertFrom-Json
        }
    }
    catch {
        $parseError = $_.Exception.Message
    }

    $data = $null
    if ($envelope -and ($envelope.PSObject.Properties.Name -contains 'data')) {
        $data = $envelope.data
    }

    return [ordered]@{
        ExitCode   = $p.ExitCode
        Raw        = $stdout
        Stderr     = $stderr
        command    = if ($envelope) { $envelope.command } else { $null }
        result     = if ($envelope) { [string]$envelope.result } else { 'error' }
        error      = if ($envelope -and $envelope.error) { [string]$envelope.error } elseif ($parseError) { $parseError } elseif ($stderr) { $stderr.Trim() } else { $null }
        data       = $data
        Envelope   = $envelope
    }
}

function Invoke-CliList {
    param([string]$CliPath, [string]$PackagesRoot)
    $r = Invoke-AutostartCli -CliPath $CliPath -Arguments @('list') -PackagesRoot $PackagesRoot
    $entries = @()
    if ($r.data -and ($r.data.PSObject.Properties.Name -contains 'entries') -and $null -ne $r.data.entries) {
        $raw = $r.data.entries
        if ($raw -is [System.Array]) { $entries = @($raw) }
        elseif ($raw) { $entries = @($raw) }
    }
    return @{ Result = $r; Entries = $entries }
}

function Invoke-CliStatus {
    <#
      status result with short-TTL cache (skipped when CliInvokeHook is set,
      e.g. tests, so stub invocations stay observable).
    #>
    param([string]$CliPath, [string]$Name, [string]$PackagesRoot)
    $useCache = -not ($script:CliInvokeHook -is [scriptblock])
    $key = [string]$Name
    if ($useCache) {
        if ($script:CliStatusCache.ContainsKey($key)) {
            $c = $script:CliStatusCache[$key]
            $age = (New-TimeSpan -Start $c['at'] -End (Get-Date)).TotalSeconds
            if ($age -lt $script:CliStatusCacheTtlSec) {
                return $c['result']
            }
        }
    }
    $r = Invoke-AutostartCli -CliPath $CliPath -Arguments @('status', '-Name', $Name) -PackagesRoot $PackagesRoot
    if ($useCache) {
        $script:CliStatusCache[$key] = @{ at = (Get-Date); result = $r }
    }
    return $r
}

function Clear-CliStatusCache {
    <# Drop cached CLI status results; no name = clear all. #>
    param([string]$Name)
    if (-not ($script:CliStatusCache -is [hashtable])) {
        $script:CliStatusCache = @{}
        return
    }
    if ($Name) {
        if ($script:CliStatusCache.ContainsKey([string]$Name)) {
            $script:CliStatusCache.Remove([string]$Name)
        }
        return
    }
    $script:CliStatusCache = @{}
}

function Invoke-CliRun {
    param([string]$CliPath, [string]$Name, [string]$PackagesRoot)
    return (Invoke-AutostartCli -CliPath $CliPath -Arguments @('run', '-Name', $Name) -PackagesRoot $PackagesRoot)
}

function Invoke-CliStop {
    param([string]$CliPath, [string]$Name, [string]$PackagesRoot)
    return (Invoke-AutostartCli -CliPath $CliPath -Arguments @('stop', '-Name', $Name) -PackagesRoot $PackagesRoot)
}

function Invoke-CliEnable {
    param([string]$CliPath, [string]$Name, [string]$PackagesRoot)
    return (Invoke-AutostartCli -CliPath $CliPath -Arguments @('enable', '-Name', $Name) -PackagesRoot $PackagesRoot)
}

function Invoke-CliDisable {
    param([string]$CliPath, [string]$Name, [string]$PackagesRoot)
    return (Invoke-AutostartCli -CliPath $CliPath -Arguments @('disable', '-Name', $Name) -PackagesRoot $PackagesRoot)
}
