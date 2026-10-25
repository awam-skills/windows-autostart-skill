#Requires -Version 5.1
<#
.SYNOPSIS
  windows-autostart Manager Core — health loop, file watches, localhost HTTP API + optional static Web panel.

.DESCRIPTION
  Subcommands:
    serve        (default) HttpListener + health tick + watch debounce until Ctrl+C or stop file
    init         Ensure ~\.win-autostart\_manager\ + default json files
    once-health  Single health tick (for tests)
    once-watch   Flush pending watch debounce / optional simulation (for tests)

  Dry-run: -DryRun or env WIN_AUTOSTART_MANAGER_DRYRUN=1 records restart intents to
  _manager/test-restarts.jsonl instead of calling CLI stop/run.

  Pause: create _manager/PAUSE to skip health restarts and watch restarts (tray menu).
  Library mode: -LibraryOnly (or dot-source) loads functions without running a subcommand.

.NOTES
  PowerShell 5.1 compatible. Binds HTTP only to 127.0.0.1.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('serve', 'init', 'once-health', 'once-watch')]
    [string]$Action = 'serve',

    [string]$CliPath,
    [string]$ManagerRoot,
    [string]$PackagesRoot,
    [string]$WwwRoot,
    [switch]$DryRun,
    [switch]$LibraryOnly,
    [switch]$VerboseLog,

    # once-watch simulation helpers
    [string]$WatchId,
    [string[]]$WatchTargets,
    [int]$DebounceMs = 0,
    [switch]$ForceInterval
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-UserProfileDir {
    if ($env:USERPROFILE) { return $env:USERPROFILE }
    if ($env:HOME) { return $env:HOME }
    try {
        $p = [Environment]::GetFolderPath('UserProfile')
        if ($p) { return $p }
    } catch { }
    return (Get-Location).Path
}

$script:ManagerScriptPath = $MyInvocation.MyCommand.Path
if (-not $script:ManagerScriptPath) {
    # Dot-sourced / some hosts leave Path empty — fall back to PSCommandPath or ScriptName
    if ($PSCommandPath) { $script:ManagerScriptPath = $PSCommandPath }
    elseif ($MyInvocation.MyCommand.ScriptName) { $script:ManagerScriptPath = $MyInvocation.MyCommand.ScriptName }
    elseif ($MyInvocation.PSCommandPath) { $script:ManagerScriptPath = $MyInvocation.PSCommandPath }
}
if (-not $script:ManagerScriptPath) {
    $candidate = Join-Path (Get-Location) 'win-autostart-manager.ps1'
    if (Test-Path -Path $candidate -PathType Leaf) { $script:ManagerScriptPath = $candidate }
}
if (-not $script:ManagerScriptPath) {
    throw 'Cannot resolve win-autostart-manager.ps1 path (MyInvocation.MyCommand.Path empty).'
}

$script:ManagerModuleDir = Join-Path (Split-Path -Parent $script:ManagerScriptPath) 'manager'

# Pre-declare script vars so StrictMode-safe module load / optional hooks work.
$script:ManagerDryRun = [bool]$DryRun
$script:ManagerVerbose = [bool]$VerboseLog
$script:CliInvokeHook = $null
$script:DeferredRunHook = $null
$script:TcpProbeHook = $null
$script:HttpProbeHook = $null
$script:ProcessProbeHook = $null
$script:PortListenProbeHook = $null
$script:WatchPending = @{}
$script:Watchers = New-Object System.Collections.Generic.List[object]
$script:WatchRawEvents = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
if ($ManagerRoot) {
    $script:ManagerRoot = $ManagerRoot
}
else {
    $script:ManagerRoot = Join-Path (Join-Path (Get-UserProfileDir) '.win-autostart') '_manager'
}
if (-not $PackagesRoot) {
    $PackagesRoot = Join-Path (Get-UserProfileDir) '.win-autostart'
}
$script:PackagesRoot = $PackagesRoot

foreach ($mod in @('Config.ps1', 'Cli.ps1', 'Restart.ps1', 'Health.ps1', 'Watch.ps1', 'HttpApi.ps1')) {
    $mp = Join-Path $script:ManagerModuleDir $mod
    if (-not (Test-Path -Path $mp -PathType Leaf)) {
        throw "Missing manager module: $mp"
    }
    . $mp
}

function Resolve-ManagerCli {
    param([string]$Override)
    return (Resolve-AutostartCliPath -CliPath $Override -ManagerScriptPath $script:ManagerScriptPath)
}

function Get-ManagerStopFilePath {
    param([string]$Root)
    return (Join-Path (Get-ManagerDir -ManagerRoot $Root) 'STOP')
}

function Invoke-ManagerInit {
    param([string]$Root)
    $paths = Initialize-ManagerConfig -ManagerRoot $Root
    Write-ManagerLog -ManagerRoot $Root -Level 'INFO' -Message 'init: manager config ensured'
    return $paths
}

function Start-ManagerServe {
    param(
        [string]$Root,
        [string]$Cli,
        [string]$PkgRoot,
        [string]$Www,
        [switch]$Dry
    )

    $null = Invoke-ManagerInit -Root $Root
    $cfg = Read-ManagerConfig -ManagerRoot $Root
    $startedAt = Get-Date
    $script:ManagerStartedAt = $startedAt

    $listen = [string]$cfg['listen']
    if ($listen -ne '127.0.0.1') {
        Write-ManagerLog -ManagerRoot $Root -Level 'WARN' -Message ("Overriding listen '{0}' → 127.0.0.1 (localhost only)" -f $listen)
        $listen = '127.0.0.1'
    }
    $port = [int]$cfg['port']

    if (-not $Www) {
        $Www = Resolve-ManagerWwwRoot -ManagerScriptPath $script:ManagerScriptPath -Override $null
    }
    $script:ManagerWwwRoot = $Www
    if ($Www) {
        Write-ManagerLog -ManagerRoot $Root -Level 'INFO' -Message ("Serving static panel from {0}" -f $Www)
    }

    $listener = $null
    try {
        $listener = Start-ManagerHttpListener -ListenHost $listen -Port $port `
            -ManagerRoot $Root -CliPath $Cli -PackagesRoot $PkgRoot `
            -StartedAt $startedAt -DryRun:$Dry -Cfg $cfg
    }
    catch {
        Write-Error $_.Exception.Message
        exit 2
    }

    $watchCount = 0
    try {
        $watchCount = Start-ManagerWatchLoop -ManagerRoot $Root
    }
    catch {
        Write-ManagerLog -ManagerRoot $Root -Level 'WARN' -Message ("Watch loop start failed: {0}" -f $_.Exception.Message)
    }

    $stopFile = Get-ManagerStopFilePath -Root $Root
    if (Test-Path -Path $stopFile -PathType Leaf) {
        Remove-Item -Path $stopFile -Force -ErrorAction SilentlyContinue
    }

    Write-ManagerLog -ManagerRoot $Root -Level 'INFO' -Message ("serve started cli={0} dryRun={1} watches={2} www={3}" -f $Cli, [bool]$Dry, $watchCount, $Www)
    if ($Www) {
        Write-Host ("win-autostart-manager panel http://{0}:{1}/  API http://{0}:{1}/api/v1/health  (Ctrl+C or create {2} to stop)" -f $listen, $port, $stopFile)
    }
    else {
        Write-Host ("win-autostart-manager listening http://{0}:{1}/api/v1/health  (Ctrl+C or create {2} to stop)" -f $listen, $port, $stopFile)
    }

    $lastHealthTick = Get-Date
    $healthTickSec = 5

    try {
        while ($true) {
            if (Test-Path -Path $stopFile -PathType Leaf) {
                Write-ManagerLog -ManagerRoot $Root -Level 'INFO' -Message 'STOP file detected; shutting down'
                break
            }

            # Drain pending HTTP requests
            $drain = 0
            try {
                while ((Process-ManagerHttpRequest -Listener $listener -ManagerRoot $Root -CliPath $Cli `
                            -PackagesRoot $PkgRoot -StartedAt $startedAt -DryRun:$Dry -Cfg $cfg -WwwRoot $Www) -and ($drain -lt 32)) {
                    $drain++
                }
            }
            catch {
                Write-ManagerLog -ManagerRoot $Root -Level 'ERROR' -Message ("HTTP drain error: {0}" -f $_.Exception.Message)
            }

            # Health tick ~5s
            if (((Get-Date) - $lastHealthTick).TotalSeconds -ge $healthTickSec) {
                $lastHealthTick = Get-Date
                try {
                    $null = Invoke-HealthTick -ManagerRoot $Root -CliPath $Cli -PackagesRoot $PkgRoot -DryRun:$Dry -Cfg $cfg
                }
                catch {
                    Write-ManagerLog -ManagerRoot $Root -Level 'ERROR' -Message ("Health tick error: {0}" -f $_.Exception.Message)
                }
                # Reload config lightly (port change requires restart)
                $cfg = Read-ManagerConfig -ManagerRoot $Root
            }

            # Watch debounce flush
            try {
                $null = Invoke-WatchDebounceFlush -ManagerRoot $Root -CliPath $Cli -PackagesRoot $PkgRoot -DryRun:$Dry -Cfg $cfg
            }
            catch {
                Write-ManagerLog -ManagerRoot $Root -Level 'ERROR' -Message ("Watch flush error: {0}" -f $_.Exception.Message)
            }

            Start-Sleep -Milliseconds 100
        }
    }
    finally {
        Clear-ManagerWatchers
        $script:HttpAsyncResult = $null
        if ($listener) {
            try { $listener.Stop() } catch { }
            try { $listener.Close() } catch { }
        }
        Write-ManagerLog -ManagerRoot $Root -Level 'INFO' -Message 'serve stopped'
    }
}

# --- entry ---
$isDotSourced = ($MyInvocation.InvocationName -eq '.')
if ($LibraryOnly -or $isDotSourced) {
    return
}

try {
    switch ($Action) {
        'init' {
            $paths = Invoke-ManagerInit -Root $script:ManagerRoot
            $out = [ordered]@{
                ok         = $true
                action     = 'init'
                managerDir = $paths.managerDir
                files      = @{
                    managerJson = $paths.managerJson
                    watchesJson = $paths.watchesJson
                    stateJson   = $paths.stateJson
                    managerLog  = $paths.managerLog
                }
            }
            Write-Output ($out | ConvertTo-Json -Depth 6 -Compress)
            exit 0
        }
        'once-health' {
            $null = Invoke-ManagerInit -Root $script:ManagerRoot
            $cli = Resolve-ManagerCli -Override $CliPath
            $cfg = Read-ManagerConfig -ManagerRoot $script:ManagerRoot
            $actions = Invoke-HealthTick -ManagerRoot $script:ManagerRoot -CliPath $cli `
                -PackagesRoot $script:PackagesRoot -DryRun:$DryRun -Cfg $cfg -ForceInterval:$ForceInterval
            $out = [ordered]@{
                ok      = $true
                action  = 'once-health'
                actions = @($actions)
            }
            Write-Output ($out | ConvertTo-Json -Depth 10 -Compress)
            exit 0
        }
        'once-watch' {
            $null = Invoke-ManagerInit -Root $script:ManagerRoot
            $cli = Resolve-ManagerCli -Override $CliPath
            $cfg = Read-ManagerConfig -ManagerRoot $script:ManagerRoot
            if ($WatchId -and $WatchTargets) {
                $actions = Invoke-OnceWatchSimulation -ManagerRoot $script:ManagerRoot -CliPath $cli `
                    -PackagesRoot $script:PackagesRoot -WatchId $WatchId -Targets $WatchTargets `
                    -DebounceMs $DebounceMs -DryRun:$DryRun -Cfg $cfg -Immediate:($DebounceMs -le 0)
            }
            else {
                $actions = Invoke-WatchDebounceFlush -ManagerRoot $script:ManagerRoot -CliPath $cli `
                    -PackagesRoot $script:PackagesRoot -DryRun:$DryRun -Cfg $cfg
            }
            $out = [ordered]@{
                ok      = $true
                action  = 'once-watch'
                actions = @($actions)
            }
            Write-Output ($out | ConvertTo-Json -Depth 10 -Compress)
            exit 0
        }
        default {
            # serve
            $null = Invoke-ManagerInit -Root $script:ManagerRoot
            $cli = Resolve-ManagerCli -Override $CliPath
            Start-ManagerServe -Root $script:ManagerRoot -Cli $cli -PkgRoot $script:PackagesRoot -Www $WwwRoot -Dry:$DryRun
            exit 0
        }
    }
}
catch {
    $err = [ordered]@{
        ok     = $false
        action = $Action
        error  = $_.Exception.Message
    }
    Write-Output ($err | ConvertTo-Json -Depth 4 -Compress)
    Write-Error $_.Exception.Message
    exit 1
}
