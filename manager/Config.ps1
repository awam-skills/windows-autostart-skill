#Requires -Version 5.1
# Manager config contracts: manager.json / watches.json defaults under _manager.

Set-StrictMode -Version 2.0

function Get-ManagerDir {
    param([string]$ManagerRoot)
    if ($ManagerRoot) { return $ManagerRoot }
    $existing = Get-Variable -Name ManagerRoot -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $existing -and $existing.Value) { return [string]$existing.Value }
    return (Join-Path (Join-Path $(if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { (Get-Location).Path }) '.win-autostart') '_manager')
}

function Get-DefaultManagerConfig {
    return [ordered]@{
        schema                   = 'windows-autostart-manager/1'
        listen                   = '127.0.0.1'
        port                     = 18765
        healthDefaultIntervalSec = 30
        restartCooldownSec       = 30
        restartBackoffMaxSec     = 300
        token                    = $null
    }
}

function Get-DefaultWatchesDoc {
    return [ordered]@{
        schema     = 'windows-autostart-watches/1'
        debounceMs = 800
        items      = @()
    }
}

function Get-DefaultStateDoc {
    return [ordered]@{
        schema  = 'windows-autostart-state/1'
        entries = [ordered]@{}
    }
}

function ConvertTo-PlainMap {
    param($Obj)
    $map = @{}
    if ($null -eq $Obj) { return $map }
    if ($Obj -is [hashtable] -or $Obj -is [System.Collections.Specialized.OrderedDictionary]) {
        foreach ($k in @($Obj.Keys)) { $map[[string]$k] = $Obj[$k] }
        return $map
    }
    foreach ($p in $Obj.PSObject.Properties) {
        $map[[string]$p.Name] = $p.Value
    }
    return $map
}

function Write-JsonFile {
    param([string]$Path, $Doc, [int]$Depth = 10)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -Path $dir -PathType Container)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    ($Doc | ConvertTo-Json -Depth $Depth) | Set-Content -Path $Path -Encoding UTF8
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -Path $Path -PathType Leaf)) { return $null }
    try {
        return (Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Initialize-ManagerConfig {
    <#
      Ensure _manager dir + default manager.json / watches.json / state.json.
      Never wipe existing desiredEnabled or other state fields.
    #>
    param([string]$ManagerRoot)

    $dir = Get-ManagerDir -ManagerRoot $ManagerRoot
    if (-not (Test-Path -Path $dir -PathType Container)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $mgrPath = Join-Path $dir 'manager.json'
    if (-not (Test-Path -Path $mgrPath -PathType Leaf)) {
        Write-JsonFile -Path $mgrPath -Doc (Get-DefaultManagerConfig)
    }

    $watchesPath = Join-Path $dir 'watches.json'
    if (-not (Test-Path -Path $watchesPath -PathType Leaf)) {
        Write-JsonFile -Path $watchesPath -Doc (Get-DefaultWatchesDoc)
    }

    $statePath = Join-Path $dir 'state.json'
    if (-not (Test-Path -Path $statePath -PathType Leaf)) {
        Write-JsonFile -Path $statePath -Doc (Get-DefaultStateDoc)
    }

    # Touch log file
    $logPath = Join-Path $dir 'manager.log'
    if (-not (Test-Path -Path $logPath -PathType Leaf)) {
        New-Item -Path $logPath -ItemType File -Force | Out-Null
    }

    return [ordered]@{
        managerDir   = $dir
        managerJson  = $mgrPath
        watchesJson  = $watchesPath
        stateJson    = $statePath
        managerLog   = $logPath
    }
}

function Read-ManagerConfig {
    param([string]$ManagerRoot)
    $dir = Get-ManagerDir -ManagerRoot $ManagerRoot
    $path = Join-Path $dir 'manager.json'
    $obj = Read-JsonFile -Path $path
    $defaults = Get-DefaultManagerConfig
    if ($null -eq $obj) { return $defaults }

    $map = ConvertTo-PlainMap $obj
    $cfg = [ordered]@{}
    foreach ($k in @($defaults.Keys)) {
        if ($map.ContainsKey($k) -and $null -ne $map[$k]) {
            $cfg[$k] = $map[$k]
        }
        else {
            $cfg[$k] = $defaults[$k]
        }
    }
    # Preserve unknown keys lightly
    foreach ($k in @($map.Keys)) {
        if (-not $cfg.Contains($k)) { $cfg[$k] = $map[$k] }
    }
    # Normalize types
    $cfg['port'] = [int]$cfg['port']
    $cfg['healthDefaultIntervalSec'] = [int]$cfg['healthDefaultIntervalSec']
    $cfg['restartCooldownSec'] = [int]$cfg['restartCooldownSec']
    $cfg['restartBackoffMaxSec'] = [int]$cfg['restartBackoffMaxSec']
    if ($cfg['token'] -eq '') { $cfg['token'] = $null }
    return $cfg
}

function Read-WatchesDoc {
    param([string]$ManagerRoot)
    $dir = Get-ManagerDir -ManagerRoot $ManagerRoot
    $path = Join-Path $dir 'watches.json'
    $obj = Read-JsonFile -Path $path
    if ($null -eq $obj) { return (Get-DefaultWatchesDoc) }
    $map = ConvertTo-PlainMap $obj
    $doc = Get-DefaultWatchesDoc
    if ($map.ContainsKey('schema') -and $map['schema']) { $doc['schema'] = [string]$map['schema'] }
    if ($map.ContainsKey('debounceMs') -and $null -ne $map['debounceMs']) {
        $doc['debounceMs'] = [int]$map['debounceMs']
    }
    $items = @()
    if ($map.ContainsKey('items') -and $null -ne $map['items']) {
        $raw = $map['items']
        if ($raw -is [System.Array]) {
            foreach ($it in @($raw)) { $items += ,(ConvertTo-PlainMap $it) }
        }
        elseif ($raw) {
            $items += ,(ConvertTo-PlainMap $raw)
        }
    }
    $doc['items'] = $items
    return $doc
}

function Save-WatchesDoc {
    param([string]$ManagerRoot, $Doc)
    $dir = Get-ManagerDir -ManagerRoot $ManagerRoot
    $path = Join-Path $dir 'watches.json'
    $itemsOut = New-Object System.Collections.Generic.List[object]
    foreach ($it in @($Doc['items'])) {
        $m = ConvertTo-PlainMap $it
        $ordered = [ordered]@{}
        foreach ($k in @('id', 'paths', 'glob', 'targets', 'enabled')) {
            if ($m.ContainsKey($k)) { $ordered[$k] = $m[$k] }
        }
        foreach ($k in @($m.Keys | Sort-Object)) {
            if (-not $ordered.Contains($k)) { $ordered[$k] = $m[$k] }
        }
        $itemsOut.Add($ordered)
    }
    # Force array for PS 5.1 ConvertTo-Json
    $itemsArr = @($itemsOut.ToArray())
    $out = [ordered]@{
        schema     = [string]$Doc['schema']
        debounceMs = [int]$Doc['debounceMs']
        items      = $itemsArr
    }
    Write-JsonFile -Path $path -Doc $out
}

function Write-ManagerLog {
    param([string]$ManagerRoot, [string]$Level = 'INFO', [string]$Message)
    $dir = Get-ManagerDir -ManagerRoot $ManagerRoot
    $path = Join-Path $dir 'manager.log'
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[{0}] [{1}] {2}" -f $ts, $Level.ToUpperInvariant(), $Message
    try {
        Add-Content -Path $path -Value $line -Encoding UTF8
    }
    catch { }
    $verboseVar = Get-Variable -Name ManagerVerbose -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $verboseVar -and $verboseVar.Value) {
        Write-Host $line
    }
}

function Read-ManagerStateDoc {
    param([string]$ManagerRoot)
    $dir = Get-ManagerDir -ManagerRoot $ManagerRoot
    $path = Join-Path $dir 'state.json'
    $obj = Read-JsonFile -Path $path
    $entries = @{}
    $schema = 'windows-autostart-state/1'
    if ($null -eq $obj) {
        return @{ Schema = $schema; Entries = $entries }
    }
    if ($obj.schema) { $schema = [string]$obj.schema }
    if ($obj.entries) {
        foreach ($p in $obj.entries.PSObject.Properties) {
            $entries[$p.Name] = (ConvertTo-PlainMap $p.Value)
        }
    }
    return @{ Schema = $schema; Entries = $entries }
}

function Save-ManagerStateDoc {
    param([string]$ManagerRoot, $State)
    $dir = Get-ManagerDir -ManagerRoot $ManagerRoot
    $path = Join-Path $dir 'state.json'
    $orderedEntries = [ordered]@{}
    foreach ($k in @($State.Entries.Keys | Sort-Object)) {
        $raw = ConvertTo-PlainMap $State.Entries[$k]
        $oe = [ordered]@{}
        foreach ($fk in @($raw.Keys | Sort-Object)) { $oe[$fk] = $raw[$fk] }
        $orderedEntries[$k] = $oe
    }
    $doc = [ordered]@{
        schema  = $State.Schema
        entries = $orderedEntries
    }
    Write-JsonFile -Path $path -Doc $doc
}

function Update-ManagerEntryState {
    <#
      Merge fields into state.entries[name]. Never deletes desiredEnabled unless
      explicitly passed in Fields.
    #>
    param(
        [string]$ManagerRoot,
        [string]$Name,
        [hashtable]$Fields
    )
    $state = Read-ManagerStateDoc -ManagerRoot $ManagerRoot
    $cur = @{}
    if ($state.Entries.ContainsKey($Name)) {
        $cur = ConvertTo-PlainMap $state.Entries[$Name]
    }
    foreach ($k in @($Fields.Keys)) {
        $cur[$k] = $Fields[$k]
    }
    $state.Entries[$Name] = $cur
    Save-ManagerStateDoc -ManagerRoot $ManagerRoot -State $state
    return $cur
}

function Get-ManagerEntryState {
    param([string]$ManagerRoot, [string]$Name)
    $state = Read-ManagerStateDoc -ManagerRoot $ManagerRoot
    if (-not $state.Entries.ContainsKey($Name)) { return $null }
    return (ConvertTo-PlainMap $state.Entries[$Name])
}

function Get-ManagerPauseFilePath {
    param([string]$ManagerRoot)
    return (Join-Path (Get-ManagerDir -ManagerRoot $ManagerRoot) 'PAUSE')
}

function Test-ManagerPaused {
    <#
      Global pause for health probes and watch restarts (tray menu / flag file).
      Presence of _manager/PAUSE means paused.
    #>
    param([string]$ManagerRoot)
    $path = Get-ManagerPauseFilePath -ManagerRoot $ManagerRoot
    return (Test-Path -Path $path -PathType Leaf)
}

function Set-ManagerPaused {
    param([string]$ManagerRoot, [bool]$Paused)
    $path = Get-ManagerPauseFilePath -ManagerRoot $ManagerRoot
    if ($Paused) {
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -Path $dir -PathType Container)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }
        Set-Content -Path $path -Value ((Get-Date).ToString('o')) -Encoding UTF8
        Write-ManagerLog -ManagerRoot $ManagerRoot -Level 'INFO' -Message 'PAUSE flag set (health+watch skipped)'
    }
    else {
        if (Test-Path -Path $path -PathType Leaf) {
            Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
            Write-ManagerLog -ManagerRoot $ManagerRoot -Level 'INFO' -Message 'PAUSE flag cleared'
        }
    }
}
