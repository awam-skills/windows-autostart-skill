#Requires -Version 5.1
# Watch loop: FileSystemWatcher + debounce → Restart-Entry for targets.
# Event handlers only enqueue raw events (safe across Register-ObjectEvent scopes);
# the serve loop drains into debounce via Invoke-WatchEventDrain.

Set-StrictMode -Version 2.0

if ($null -eq (Get-Variable -Name WatchPending -Scope Script -ErrorAction SilentlyContinue)) {
    $script:WatchPending = @{}
}
if ($null -eq (Get-Variable -Name Watchers -Scope Script -ErrorAction SilentlyContinue)) {
    $script:Watchers = New-Object System.Collections.Generic.List[object]
}
if ($null -eq (Get-Variable -Name WatchRawEvents -Scope Script -ErrorAction SilentlyContinue)) {
    $script:WatchRawEvents = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
}

function Clear-ManagerWatchers {
    # PS 5.1: @($List[object]) throws "parameter type mismatch" — iterate the list directly.
    if ($null -ne $script:Watchers) {
        foreach ($w in $script:Watchers) {
            if ($null -eq $w) { continue }
            try {
                if ($w.Subs) {
                    foreach ($s in $w.Subs) {
                        if ($null -eq $s) { continue }
                        try { Unregister-Event -SourceIdentifier $s.Name -ErrorAction SilentlyContinue } catch { }
                        try { Remove-Job -Id $s.Id -Force -ErrorAction SilentlyContinue } catch { }
                    }
                }
                if ($w.Watcher) {
                    $w.Watcher.EnableRaisingEvents = $false
                    $w.Watcher.Dispose()
                }
            }
            catch { }
        }
    }
    $script:Watchers = New-Object System.Collections.Generic.List[object]
    $script:WatchPending = @{}
    if ($null -ne $script:WatchRawEvents) { $script:WatchRawEvents.Clear() }
}

function Queue-WatchFire {
    param(
        [string]$WatchId,
        [string[]]$Targets,
        [int]$DebounceMs,
        [string]$PathHint
    )
    if ($DebounceMs -lt 0) { $DebounceMs = 0 }
    $script:WatchPending[$WatchId] = @{
        dueAt    = (Get-Date).AddMilliseconds($DebounceMs)
        targets  = @($Targets)
        pathHint = $PathHint
        firedAt  = Get-Date
    }
}

function Invoke-WatchEventDrain {
    <# Move raw FSW events into debounce pending map. #>
    param([int]$DebounceMs = 800)
    if ($null -eq $script:WatchRawEvents) { return 0 }
    $n = 0
    while ($script:WatchRawEvents.Count -gt 0) {
        $ev = $null
        try {
            $ev = $script:WatchRawEvents[0]
            $script:WatchRawEvents.RemoveAt(0)
        }
        catch { break }
        if ($null -eq $ev) { continue }
        $db = $DebounceMs
        if ($ev.ContainsKey('DebounceMs') -and $null -ne $ev['DebounceMs']) { $db = [int]$ev['DebounceMs'] }
        Queue-WatchFire -WatchId ([string]$ev['WatchId']) -Targets @($ev['Targets']) -DebounceMs $db -PathHint ([string]$ev['PathHint'])
        $n++
    }
    return $n
}

function Invoke-WatchDebounceFlush {
    <#
      Process due pending watch fires. Call from serve loop or -OnceWatch.
    #>
    param(
        [string]$ManagerRoot,
        [string]$CliPath,
        [string]$PackagesRoot,
        [switch]$DryRun,
        $Cfg,
        [switch]$ForceAll
    )
    if (-not $Cfg) { $Cfg = Read-ManagerConfig -ManagerRoot $ManagerRoot }
    $doc = Read-WatchesDoc -ManagerRoot $ManagerRoot
    $null = Invoke-WatchEventDrain -DebounceMs ([int]$doc['debounceMs'])

    $now = Get-Date
    $done = New-Object System.Collections.Generic.List[object]
    $keys = @($script:WatchPending.Keys)
    foreach ($id in $keys) {
        $pend = $script:WatchPending[$id]
        if (-not $ForceAll) {
            if ($pend.dueAt -gt $now) { continue }
        }
        [void]$script:WatchPending.Remove($id)
        foreach ($target in @($pend.targets)) {
            if (-not $target) { continue }
            if (-not (Test-EntryDesiredEnabled -ManagerRoot $ManagerRoot -Name $target)) {
                Write-ManagerLog -ManagerRoot $ManagerRoot -Level 'INFO' -Message ("Watch skip target '{0}' (watch={1}): desiredEnabled=false" -f $target, $id)
                $done.Add([ordered]@{ watchId = $id; target = $target; action = 'skip'; detail = 'desiredEnabled=false' })
                continue
            }
            $rr = Restart-Entry -ManagerRoot $ManagerRoot -CliPath $CliPath -PackagesRoot $PackagesRoot -Name $target -Reason ("watch:$id") -DryRun:$DryRun -Cfg $Cfg
            Update-ManagerEntryState -ManagerRoot $ManagerRoot -Name $target -Fields @{
                lastWatchFireAt = (Get-Date).ToString('o')
                lastWatchId     = $id
            }
            $done.Add([ordered]@{ watchId = $id; target = $target; action = 'restart'; detail = $rr })
        }
    }
    return @($done.ToArray())
}

function New-ManagerFileSystemWatcher {
    param(
        [string]$WatchPath,
        [string]$Filter = '*',
        [bool]$IncludeSubdirectories = $false
    )
    $w = New-Object System.IO.FileSystemWatcher
    $w.Path = $WatchPath
    $w.Filter = $Filter
    $w.IncludeSubdirectories = $IncludeSubdirectories
    $w.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor `
        [System.IO.NotifyFilters]::FileName -bor `
        [System.IO.NotifyFilters]::DirectoryName -bor `
        [System.IO.NotifyFilters]::CreationTime
    return $w
}

function Start-ManagerWatchLoop {
    <#
      Load watches.json and attach FileSystemWatchers. Events enqueue to WatchRawEvents.
      Returns watcher count.
    #>
    param(
        [string]$ManagerRoot,
        [int]$DebounceMsOverride
    )

    Clear-ManagerWatchers
    $doc = Read-WatchesDoc -ManagerRoot $ManagerRoot
    $debounce = [int]$doc['debounceMs']
    if ($PSBoundParameters.ContainsKey('DebounceMsOverride') -and $null -ne $DebounceMsOverride) {
        $debounce = [int]$DebounceMsOverride
    }

    $count = 0
    foreach ($item in @($doc['items'])) {
        $m = ConvertTo-PlainMap $item
        $enabled = $true
        if ($m.ContainsKey('enabled') -and $null -ne $m['enabled']) { $enabled = [bool]$m['enabled'] }
        if (-not $enabled) { continue }

        $id = [string]$m['id']
        $targets = @()
        if ($m.ContainsKey('targets') -and $null -ne $m['targets']) {
            $t = $m['targets']
            if ($t -is [System.Array]) { $targets = @($t | ForEach-Object { [string]$_ }) }
            else { $targets = @([string]$t) }
        }
        $paths = @()
        if ($m.ContainsKey('paths') -and $null -ne $m['paths']) {
            $p = $m['paths']
            if ($p -is [System.Array]) { $paths = @($p | ForEach-Object { [string]$_ }) }
            else { $paths = @([string]$p) }
        }
        $glob = $null
        if ($m.ContainsKey('glob') -and $m['glob']) { $glob = [string]$m['glob'] }

        foreach ($path in $paths) {
            if (-not $path) { continue }
            $watchDir = $null
            $filter = '*'
            $isFile = $false
            if (Test-Path -Path $path -PathType Leaf) {
                $watchDir = Split-Path -Parent $path
                $filter = Split-Path -Leaf $path
                $isFile = $true
            }
            elseif (Test-Path -Path $path -PathType Container) {
                $watchDir = $path
                if ($glob) { $filter = $glob }
            }
            else {
                $parent = Split-Path -Parent $path
                if ($parent -and (Test-Path -Path $parent -PathType Container)) {
                    $watchDir = $parent
                    $filter = Split-Path -Leaf $path
                    $isFile = $true
                }
                else {
                    Write-ManagerLog -ManagerRoot $ManagerRoot -Level 'WARN' -Message ("Watch path missing: {0} (id={1})" -f $path, $id)
                    continue
                }
            }

            try {
                $fsw = New-ManagerFileSystemWatcher -WatchPath $watchDir -Filter $filter -IncludeSubdirectories:(-not $isFile -and [bool]$glob)
                $msg = @{
                    WatchId    = $id
                    Targets    = $targets
                    DebounceMs = $debounce
                    Bag        = $script:WatchRawEvents
                }
                # Handler must not call script-scope functions; only enqueue into synchronized bag.
                $handler = {
                    $bag = $Event.MessageData.Bag
                    if ($null -eq $bag) { return }
                    $hint = ''
                    try { $hint = [string]$Event.SourceEventArgs.FullPath } catch { $hint = '' }
                    [void]$bag.Add(@{
                        WatchId    = $Event.MessageData.WatchId
                        Targets    = $Event.MessageData.Targets
                        DebounceMs = $Event.MessageData.DebounceMs
                        PathHint   = $hint
                    })
                }

                $sub1 = Register-ObjectEvent -InputObject $fsw -EventName Changed -Action $handler -MessageData $msg
                $sub2 = Register-ObjectEvent -InputObject $fsw -EventName Created -Action $handler -MessageData $msg
                $sub3 = Register-ObjectEvent -InputObject $fsw -EventName Renamed -Action $handler -MessageData $msg
                $sub4 = Register-ObjectEvent -InputObject $fsw -EventName Deleted -Action $handler -MessageData $msg
                $fsw.EnableRaisingEvents = $true
                $script:Watchers.Add(@{
                    Watcher = $fsw
                    Subs    = @($sub1, $sub2, $sub3, $sub4)
                    Id      = $id
                    Path    = $path
                })
                $count++
            }
            catch {
                Write-ManagerLog -ManagerRoot $ManagerRoot -Level 'WARN' -Message ("Watch attach failed id={0} path={1}: {2}" -f $id, $path, $_.Exception.Message)
            }
        }
    }

    Write-ManagerLog -ManagerRoot $ManagerRoot -Level 'INFO' -Message ("Watch loop started: {0} watcher(s), debounceMs={1}" -f $count, $debounce)
    return $count
}

function Invoke-OnceWatchSimulation {
    <#
      Test helper: queue a watch fire as if FSW saw an event, then flush after debounce.
    #>
    param(
        [string]$ManagerRoot,
        [string]$CliPath,
        [string]$PackagesRoot,
        [string]$WatchId,
        [string[]]$Targets,
        [int]$DebounceMs = 0,
        [switch]$DryRun,
        [switch]$Immediate,
        $Cfg
    )
    Queue-WatchFire -WatchId $WatchId -Targets $Targets -DebounceMs $DebounceMs -PathHint 'simulated'
    if ($DebounceMs -gt 0 -and -not $Immediate) {
        Start-Sleep -Milliseconds ($DebounceMs + 20)
    }
    return (Invoke-WatchDebounceFlush -ManagerRoot $ManagerRoot -CliPath $CliPath -PackagesRoot $PackagesRoot -DryRun:$DryRun -Cfg $Cfg -ForceAll:$Immediate)
}
