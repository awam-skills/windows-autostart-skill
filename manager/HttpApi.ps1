#Requires -Version 5.1
# Minimal localhost HTTP API via System.Net.HttpListener (PS 5.1).

Set-StrictMode -Version 2.0

# Scheduled-task state index cache (taskName -> State string).
# One Get-ScheduledTask enumeration serves the whole /entries request and is
# reused across requests for a few seconds; mutating actions invalidate it.
$script:ManagerSchedTaskCacheTtlSec = 5
$script:ManagerSchedTaskCache = $null

function ConvertTo-JsonResponseBytes {
    param($Obj, [int]$Depth = 12)
    $json = ($Obj | ConvertTo-Json -Depth $Depth -Compress)
    return [System.Text.Encoding]::UTF8.GetBytes($json)
}

function Read-RequestBodyText {
    param($Request)
    if (-not $Request.HasEntityBody) { return '' }
    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try { return $reader.ReadToEnd() }
    finally { $reader.Close() }
}

function Send-ApiJson {
    param(
        $Response,
        [int]$StatusCode,
        $Body
    )
    $bytes = ConvertTo-JsonResponseBytes -Obj $Body
    $Response.StatusCode = $StatusCode
    $Response.ContentType = 'application/json; charset=utf-8'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Test-ApiToken {
    param($Request, $Cfg)
    $token = $Cfg['token']
    if ($null -eq $token -or $token -eq '') { return $true }
    $hdr = $Request.Headers['X-Win-Autostart-Token']
    return ($hdr -eq [string]$token)
}

function Get-ApiPathSegments {
    param([string]$AbsolutePath)
    # Return a real [string[]] as ONE pipeline object (unary comma).
    # Caller must NOT wrap with @() — that would nest the array and break Count/indexing.
    if ([string]::IsNullOrEmpty($AbsolutePath) -or $AbsolutePath -eq '/') {
        return ,[string[]]@()
    }
    $p = $AbsolutePath.TrimEnd('/')
    if (-not $p) {
        return ,[string[]]@()
    }
    [string[]]$parts = @($p.Split('/') | Where-Object { $_ -ne '' })
    if ($null -eq $parts) { $parts = [string[]]@() }
    return ,[string[]]$parts
}

function Invoke-ApiHandler {
    param(
        $Request,
        $Response,
        [string]$ManagerRoot,
        [string]$CliPath,
        [string]$PackagesRoot,
        [datetime]$StartedAt,
        [switch]$DryRun,
        $Cfg,
        [string]$WwwRoot
    )

    $method = $Request.HttpMethod.ToUpperInvariant()
    $segs = Get-ApiPathSegments -AbsolutePath $Request.Url.AbsolutePath
    if ($null -eq $segs) { $segs = [string[]]@() }

    # Static panel (no token) for GET/HEAD when WwwRoot is configured
    if ($segs.Count -lt 2 -or $segs[0] -ne 'api' -or $segs[1] -ne 'v1') {
        if (($method -eq 'GET' -or $method -eq 'HEAD') -and $WwwRoot -and (Test-Path -Path $WwwRoot -PathType Container)) {
            Send-StaticWwwFile -Request $Request -Response $Response -WwwRoot $WwwRoot
            return
        }
        Send-ApiJson -Response $Response -StatusCode 404 -Body @{ ok = $false; error = 'not_found' }
        return
    }

    if (-not (Test-ApiToken -Request $Request -Cfg $Cfg)) {
        Send-ApiJson -Response $Response -StatusCode 401 -Body @{ ok = $false; error = 'unauthorized' }
        return
    }

    $resource = if ($segs.Count -ge 3) { $segs[2] } else { '' }

    try {
        switch ($resource) {
            'health' {
                if ($method -ne 'GET') { Send-ApiJson -Response $Response -StatusCode 405 -Body @{ ok = $false; error = 'method_not_allowed' }; return }
                $paused = Test-ManagerPaused -ManagerRoot $ManagerRoot
                Send-ApiJson -Response $Response -StatusCode 200 -Body @{
                    ok        = $true
                    startedAt = $StartedAt.ToString('o')
                    paused    = $paused
                }
                return
            }
            'pause' {
                # POST /api/v1/pause  | POST /api/v1/pause/resume (convenience for panel)
                if ($method -ne 'POST') { Send-ApiJson -Response $Response -StatusCode 405 -Body @{ ok = $false; error = 'method_not_allowed' }; return }
                $sub = if ($segs.Count -ge 4) { $segs[3] } else { '' }
                if ($sub -eq 'resume' -or $sub -eq 'clear') {
                    Set-ManagerPaused -ManagerRoot $ManagerRoot -Paused $false
                    Send-ApiJson -Response $Response -StatusCode 200 -Body @{ ok = $true; paused = $false }
                    return
                }
                Set-ManagerPaused -ManagerRoot $ManagerRoot -Paused $true
                Send-ApiJson -Response $Response -StatusCode 200 -Body @{ ok = $true; paused = $true }
                return
            }
            'entries' {
                if ($segs.Count -eq 3) {
                    # GET /api/v1/entries — in-process fast list, no CLI spawn
                    if ($method -ne 'GET') { Send-ApiJson -Response $Response -StatusCode 405 -Body @{ ok = $false; error = 'method_not_allowed' }; return }
                    $fast = Get-ManagerEntriesFast -PackagesRoot $PackagesRoot
                    $stateDoc = Read-ManagerStateDoc -ManagerRoot $ManagerRoot
                    $enriched = New-Object System.Collections.Generic.List[object]
                    # PS 5.1: do NOT wrap List[object] with @() — binder cache bug raises 参数类型不匹配; foreach binds via PSEnumerableBinder instead.
                    foreach ($e in $fast['entries']) {
                        $em = ConvertTo-PlainMap $e
                        $name = [string]$em['name']
                        $st = $null
                        if ($stateDoc.Entries.ContainsKey($name)) {
                            $st = ConvertTo-PlainMap $stateDoc.Entries[$name]
                        }
                        $row = [ordered]@{}
                        foreach ($k in @($em.Keys)) { $row[$k] = $em[$k] }
                        $row['managerState'] = $st
                        $enriched.Add($row)
                    }
                    Send-ApiJson -Response $Response -StatusCode 200 -Body @{
                        ok      = $true
                        entries = @($enriched.ToArray())
                    }
                    return
                }

                $name = [System.Uri]::UnescapeDataString($segs[3])
                $action = if ($segs.Count -ge 5) { $segs[4] } else { $null }

                if (-not $action) {
                    # GET /api/v1/entries/{name} — one response includes keepalive + exposedPorts
                    if ($method -ne 'GET') { Send-ApiJson -Response $Response -StatusCode 405 -Body @{ ok = $false; error = 'method_not_allowed' }; return }
                    $st = Invoke-CliStatus -CliPath $CliPath -Name $name -PackagesRoot $PackagesRoot
                    $slice = Get-ManagerEntryState -ManagerRoot $ManagerRoot -Name $name
                    $ka = Read-EntryKeepalive -PackagesRoot $PackagesRoot -Name $name
                    $portsInfo = Read-EntryExposedPorts -PackagesRoot $PackagesRoot -Name $name
                    Send-ApiJson -Response $Response -StatusCode 200 -Body @{
                        ok           = ($st.result -eq 'ok')
                        cli          = @{ result = $st.result; error = $st.error; data = $st.data }
                        managerState = $slice
                        keepalive    = $(if ($ka.ok) { $ka.keepalive } else { $null })
                        landing      = $(if ($ka.ok) { [string]$ka.landing } else { $null })
                        exposedPorts = $(if ($portsInfo.ok) { @($portsInfo.exposedPorts) } else { @() })
                    }
                    return
                }

                if ($action -eq 'keepalive') {
                    Invoke-KeepaliveApi -Method $method -Name $name -Request $Request -Response $Response `
                        -PackagesRoot $PackagesRoot -ManagerRoot $ManagerRoot
                    return
                }

                if ($action -eq 'ports') {
                    Invoke-PortsApi -Method $method -Name $name -Request $Request -Response $Response `
                        -PackagesRoot $PackagesRoot -ManagerRoot $ManagerRoot
                    return
                }

                if ($method -ne 'POST') {
                    Send-ApiJson -Response $Response -StatusCode 405 -Body @{ ok = $false; error = 'method_not_allowed' }
                    return
                }

                # Mutating action: drop read caches so the next read sees fresh state
                Clear-CliStatusCache
                Clear-ManagerScheduledTaskIndexCache

                $cliResult = $null
                switch ($action) {
                    'start' {
                        $cliResult = Invoke-CliRun -CliPath $CliPath -Name $name -PackagesRoot $PackagesRoot
                        Send-ApiJson -Response $Response -StatusCode 200 -Body @{ ok = ($cliResult.result -eq 'ok' -or $cliResult.result -eq 'partial'); result = $cliResult.result; error = $cliResult.error; data = $cliResult.data }
                        return
                    }
                    'stop' {
                        # 控制面自身：写 STOP 优雅退出，避免 CLI stop 按 powershell.exe 误杀全机 PowerShell
                        if (Test-IsControlPlaneSelfEntry -Name $name -PackagesRoot $PackagesRoot) {
                            $null = Request-ManagerGracefulStop -ManagerRoot $ManagerRoot
                            Write-ManagerLog -ManagerRoot $ManagerRoot -Level 'INFO' -Message ("API stop self '{0}': graceful STOP" -f $name)
                            Send-ApiJson -Response $Response -StatusCode 200 -Body @{
                                ok     = $true
                                result = 'ok'
                                error  = $null
                                data   = @{ name = $name; gracefulSelfStop = $true }
                            }
                            return
                        }
                        $cliResult = Invoke-CliStop -CliPath $CliPath -Name $name -PackagesRoot $PackagesRoot
                        Send-ApiJson -Response $Response -StatusCode 200 -Body @{ ok = ($cliResult.result -eq 'ok' -or $cliResult.result -eq 'partial'); result = $cliResult.result; error = $cliResult.error; data = $cliResult.data }
                        return
                    }
                    'restart' {
                        $rr = Restart-Entry -ManagerRoot $ManagerRoot -CliPath $CliPath -PackagesRoot $PackagesRoot -Name $name -Reason 'api' -DryRun:$DryRun -Cfg $Cfg
                        Send-ApiJson -Response $Response -StatusCode 200 -Body @{ ok = [bool]$rr.ok; restart = $rr }
                        return
                    }
                    'enable' {
                        $cliResult = Invoke-CliEnable -CliPath $CliPath -Name $name -PackagesRoot $PackagesRoot
                        Send-ApiJson -Response $Response -StatusCode 200 -Body @{ ok = ($cliResult.result -eq 'ok'); result = $cliResult.result; error = $cliResult.error; data = $cliResult.data }
                        return
                    }
                    'disable' {
                        $cliResult = Invoke-CliDisable -CliPath $CliPath -Name $name -PackagesRoot $PackagesRoot
                        Send-ApiJson -Response $Response -StatusCode 200 -Body @{ ok = ($cliResult.result -eq 'ok'); result = $cliResult.result; error = $cliResult.error; data = $cliResult.data }
                        return
                    }
                    default {
                        Send-ApiJson -Response $Response -StatusCode 404 -Body @{ ok = $false; error = 'not_found' }
                        return
                    }
                }
            }
            'watches' {
                if ($segs.Count -eq 3) {
                    if ($method -eq 'GET') {
                        $doc = Read-WatchesDoc -ManagerRoot $ManagerRoot
                        Send-ApiJson -Response $Response -StatusCode 200 -Body @{
                            ok         = $true
                            schema     = $doc['schema']
                            debounceMs = $doc['debounceMs']
                            items      = @($doc['items'])
                        }
                        return
                    }
                    if ($method -eq 'PUT') {
                        $bodyText = Read-RequestBodyText -Request $Request
                        $incoming = $bodyText | ConvertFrom-Json
                        $doc = Get-DefaultWatchesDoc
                        if ($incoming.schema) { $doc['schema'] = [string]$incoming.schema }
                        if ($null -ne $incoming.debounceMs) { $doc['debounceMs'] = [int]$incoming.debounceMs }
                        $items = @()
                        if ($null -ne $incoming.items) {
                            $raw = $incoming.items
                            if ($raw -is [System.Array]) {
                                foreach ($it in @($raw)) { $items += ,(ConvertTo-PlainMap $it) }
                            }
                            else { $items += ,(ConvertTo-PlainMap $raw) }
                        }
                        $doc['items'] = $items
                        Save-WatchesDoc -ManagerRoot $ManagerRoot -Doc $doc
                        # 重挂 FSW，使 CRUD 立即生效（仅写 JSON 不够）
                        $wc = 0
                        try { $wc = Start-ManagerWatchLoop -ManagerRoot $ManagerRoot } catch { $wc = -1 }
                        Send-ApiJson -Response $Response -StatusCode 200 -Body @{ ok = $true; saved = $true; watchers = $wc }
                        return
                    }
                    if ($method -eq 'POST') {
                        $bodyText = Read-RequestBodyText -Request $Request
                        $incoming = $bodyText | ConvertFrom-Json
                        $item = ConvertTo-PlainMap $incoming
                        if (-not $item.ContainsKey('id') -or -not $item['id']) {
                            $item['id'] = [guid]::NewGuid().ToString('N').Substring(0, 12)
                        }
                        if (-not $item.ContainsKey('enabled')) { $item['enabled'] = $true }
                        if (-not $item.ContainsKey('paths')) { $item['paths'] = @() }
                        if (-not $item.ContainsKey('targets')) { $item['targets'] = @() }
                        $doc = Read-WatchesDoc -ManagerRoot $ManagerRoot
                        $list = @($doc['items'])
                        $list += ,$item
                        $doc['items'] = $list
                        Save-WatchesDoc -ManagerRoot $ManagerRoot -Doc $doc
                        $wc = 0
                        try { $wc = Start-ManagerWatchLoop -ManagerRoot $ManagerRoot } catch { $wc = -1 }
                        Send-ApiJson -Response $Response -StatusCode 200 -Body @{ ok = $true; item = $item; watchers = $wc }
                        return
                    }
                    Send-ApiJson -Response $Response -StatusCode 405 -Body @{ ok = $false; error = 'method_not_allowed' }
                    return
                }

                # DELETE /api/v1/watches/{id}
                if ($segs.Count -ge 4 -and $method -eq 'DELETE') {
                    $wid = [System.Uri]::UnescapeDataString($segs[3])
                    $doc = Read-WatchesDoc -ManagerRoot $ManagerRoot
                    $kept = @()
                    $removed = $false
                    foreach ($it in @($doc['items'])) {
                        $m = ConvertTo-PlainMap $it
                        if ([string]$m['id'] -eq $wid) { $removed = $true; continue }
                        $kept += ,$m
                    }
                    $doc['items'] = $kept
                    Save-WatchesDoc -ManagerRoot $ManagerRoot -Doc $doc
                    $wc = 0
                    try { $wc = Start-ManagerWatchLoop -ManagerRoot $ManagerRoot } catch { $wc = -1 }
                    Send-ApiJson -Response $Response -StatusCode 200 -Body @{ ok = $true; removed = $removed; id = $wid; watchers = $wc }
                    return
                }

                Send-ApiJson -Response $Response -StatusCode 404 -Body @{ ok = $false; error = 'not_found' }
                return
            }
            default {
                Send-ApiJson -Response $Response -StatusCode 404 -Body @{ ok = $false; error = 'not_found' }
                return
            }
        }
    }
    catch {
        Write-ManagerLog -ManagerRoot $ManagerRoot -Level 'ERROR' -Message ("API error: {0}" -f $_.Exception.Message)
        try {
            Send-ApiJson -Response $Response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
        }
        catch { }
    }
}

function Start-ManagerHttpListener {
    param(
        [string]$ListenHost,
        [int]$Port,
        [string]$ManagerRoot,
        [string]$CliPath,
        [string]$PackagesRoot,
        [datetime]$StartedAt,
        [switch]$DryRun,
        $Cfg
    )

    if ($ListenHost -ne '127.0.0.1' -and $ListenHost -ne 'localhost') {
        throw "Refusing to bind non-localhost listen address '$ListenHost' (design: 127.0.0.1 only)."
    }

    $prefix = "http://{0}:{1}/" -f $ListenHost, $Port
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($prefix)

    try {
        $listener.Start()
    }
    catch {
        $msg = "Failed to bind {0}: {1}. Port may be in use, or URLACL missing (netsh http add urlacl url={0} user=Everyone)." -f $prefix, $_.Exception.Message
        throw $msg
    }

    Write-ManagerLog -ManagerRoot $ManagerRoot -Level 'INFO' -Message ("HTTP listening on {0}" -f $prefix)
    return $listener
}

function Process-ManagerHttpRequest {
    param(
        $Listener,
        [string]$ManagerRoot,
        [string]$CliPath,
        [string]$PackagesRoot,
        [datetime]$StartedAt,
        [switch]$DryRun,
        $Cfg,
        [string]$WwwRoot,
        [int]$WaitMs = 50
    )
    # .NET Framework HttpListener has no Pending(); use BeginGetContext + short wait.
    if (-not $Listener -or -not $Listener.IsListening) { return $false }

    if ($null -eq (Get-Variable -Name HttpAsyncResult -Scope Script -ErrorAction SilentlyContinue)) {
        $script:HttpAsyncResult = $null
    }

    if ($null -eq $script:HttpAsyncResult) {
        try {
            $script:HttpAsyncResult = $Listener.BeginGetContext($null, $null)
        }
        catch {
            return $false
        }
    }

    $ar = $script:HttpAsyncResult
    if (-not $ar.AsyncWaitHandle.WaitOne($WaitMs)) {
        return $false
    }

    $ctx = $null
    try {
        $ctx = $Listener.EndGetContext($ar)
    }
    catch {
        $script:HttpAsyncResult = $null
        return $false
    }
    finally {
        $script:HttpAsyncResult = $null
    }

    if ($null -eq $ctx) { return $false }

    try {
        Invoke-ApiHandler -Request $ctx.Request -Response $ctx.Response `
            -ManagerRoot $ManagerRoot -CliPath $CliPath -PackagesRoot $PackagesRoot `
            -StartedAt $StartedAt -DryRun:$DryRun -Cfg $Cfg -WwwRoot $WwwRoot
    }
    catch {
        try {
            Send-ApiJson -Response $ctx.Response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
        }
        catch { }
    }
    return $true
}


function Get-DefaultKeepaliveForApi {
    param([string]$Landing)
    $taskRestart = ($Landing -eq 'scheduled-task')
    return [ordered]@{
        taskRestart = $taskRestart
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

function Read-EntryKeepalive {
    param([string]$PackagesRoot, [string]$Name)
    $manifest = Read-EntryManifestForManager -PackagesRoot $PackagesRoot -Name $Name
    if ($null -eq $manifest) {
        return @{ ok = $false; error = 'entry_not_found'; keepalive = $null; path = $null }
    }
    $landing = 'scheduled-task'
    if ($manifest.PSObject.Properties.Name -contains 'landing' -and $manifest.landing) {
        $landing = [string]$manifest.landing
    }
    $ka = $null
    if ($manifest.PSObject.Properties.Name -contains 'keepalive' -and $null -ne $manifest.keepalive) {
        $ka = $manifest.keepalive
    }
    else {
        $ka = Get-DefaultKeepaliveForApi -Landing $landing
    }
    $path = Get-EntryManifestPath -PackagesRoot $PackagesRoot -Name $Name
    return @{ ok = $true; error = $null; keepalive = $ka; path = $path; landing = $landing; manifest = $manifest }
}

function Write-EntryKeepalive {
    param([string]$PackagesRoot, [string]$Name, $KeepaliveBody)
    $path = Get-EntryManifestPath -PackagesRoot $PackagesRoot -Name $Name
    if (-not (Test-Path -Path $path -PathType Leaf)) {
        return @{ ok = $false; error = 'entry_not_found' }
    }
    $raw = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $map = ConvertTo-PlainMap $raw
    $incoming = ConvertTo-PlainMap $KeepaliveBody

    $landing = 'scheduled-task'
    if ($map.ContainsKey('landing') -and $map['landing']) { $landing = [string]$map['landing'] }
    $ka = Get-DefaultKeepaliveForApi -Landing $landing
    if ($map.ContainsKey('keepalive') -and $null -ne $map['keepalive']) {
        $existing = ConvertTo-PlainMap $map['keepalive']
        foreach ($k in @($existing.Keys)) { $ka[$k] = $existing[$k] }
    }
    foreach ($k in @($incoming.Keys)) { $ka[$k] = $incoming[$k] }

    # Normalize nested process/health if hashtables / PSCustomObject
    if ($ka.Contains('process') -and $null -ne $ka['process']) {
        $ka['process'] = (ConvertTo-PlainMap $ka['process'])
    }
    if ($ka.Contains('health') -and $null -ne $ka['health']) {
        $h = ConvertTo-PlainMap $ka['health']
        if ($h.ContainsKey('tcpPorts') -and $null -ne $h['tcpPorts']) {
            $tp = $h['tcpPorts']
            if ($tp -is [System.Array]) { $h['tcpPorts'] = @($tp | ForEach-Object { [int]$_ }) }
            elseif ($null -ne $tp -and "$tp" -ne '') { $h['tcpPorts'] = @([int]$tp) }
            else { $h['tcpPorts'] = @() }
        }
        if ($h.ContainsKey('http') -and $null -ne $h['http'] -and "$($h['http'])" -ne '') {
            $h['http'] = (ConvertTo-PlainMap $h['http'])
        }
        $ka['health'] = $h
    }

    $map['keepalive'] = $ka
    if (-not $map.ContainsKey('schema') -or -not $map['schema']) {
        $map['schema'] = 'windows-autostart/2'
    }
    elseif ([string]$map['schema'] -eq 'windows-autostart/1') {
        $map['schema'] = 'windows-autostart/2'
    }

    $ordered = [ordered]@{}
    foreach ($k in @('schema', 'name', 'command', 'workdir', 'mode', 'landing', 'elevated', 'root', 'createdAt', 'keepalive', 'exposedPorts')) {
        if ($map.ContainsKey($k)) { $ordered[$k] = $map[$k] }
    }
    foreach ($k in @($map.Keys | Sort-Object)) {
        if (-not $ordered.Contains($k)) { $ordered[$k] = $map[$k] }
    }
    Write-JsonFile -Path $path -Doc $ordered -Depth 12
    return @{ ok = $true; error = $null; keepalive = $ka; path = $path }
}

function Normalize-ExposedPorts {
    <# Normalize to unique ints in 1-65535, ascending. Invalid items dropped. #>
    param($Raw)
    $seen = @{}
    $list = New-Object System.Collections.Generic.List[int]
    if ($null -eq $Raw) {
        return ,[int[]]@()
    }
    $items = @()
    if ($Raw -is [System.Array]) { $items = @($Raw) }
    elseif ("$Raw" -ne '') { $items = @($Raw) }
    foreach ($x in $items) {
        $n = 0
        if (-not [int]::TryParse([string]$x, [ref]$n)) { continue }
        if ($n -lt 1 -or $n -gt 65535) { continue }
        if ($seen.ContainsKey($n)) { continue }
        $seen[$n] = $true
        $list.Add($n)
    }
    if ($list.Count -eq 0) {
        return ,[int[]]@()
    }
    return ,[int[]]@($list | Sort-Object)
}

function ConvertTo-IntPortArray {
    <# Unwrap Normalize-ExposedPorts unary-comma result without nesting via @(). #>
    param($Raw)
    $n = Normalize-ExposedPorts -Raw $Raw
    if ($null -eq $n) { return ,[int[]]@() }
    if ($n -is [int[]]) { return ,$n }
    if ($n -is [System.Array]) {
        $tmp = New-Object System.Collections.Generic.List[int]
        foreach ($x in $n) { $tmp.Add([int]$x) }
        if ($tmp.Count -eq 0) { return ,[int[]]@() }
        return ,[int[]]@($tmp.ToArray())
    }
    return ,[int[]]@([int]$n)
}

function Get-ManifestDeclaredPortClaims {
    <# Collect exposedPorts + health.tcpPorts claims from a manifest. #>
    param($Manifest, [string]$Name)
    $claims = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Manifest) { return @() }
    if ($Manifest.PSObject.Properties.Name -contains 'exposedPorts') {
        $eps = ConvertTo-IntPortArray -Raw $Manifest.exposedPorts
        foreach ($p in $eps) {
            $claims.Add([ordered]@{ port = [int]$p; entry = $Name; source = 'exposedPorts' })
        }
    }
    if (($Manifest.PSObject.Properties.Name -contains 'keepalive') -and $Manifest.keepalive) {
        $ka = $Manifest.keepalive
        if (($ka.PSObject.Properties.Name -contains 'health') -and $ka.health) {
            $h = $ka.health
            if (($h.PSObject.Properties.Name -contains 'tcpPorts') -and $null -ne $h.tcpPorts) {
                $tps = ConvertTo-IntPortArray -Raw $h.tcpPorts
                foreach ($p in $tps) {
                    $claims.Add([ordered]@{ port = [int]$p; entry = $Name; source = 'health.tcpPorts' })
                }
            }
        }
    }
    return @($claims.ToArray())
}

function Get-ForeignPortClaimIndex {
    <#
      Port claim index for other entries: port -> @(claim...).
      Includes manager.json listen port (owner win-autostart-manager / manager.listen).
    #>
    param(
        [string]$PackagesRoot,
        [string]$ExcludeName,
        [string]$ManagerRoot
    )
    $index = @{}
    if ($PackagesRoot -and (Test-Path -Path $PackagesRoot -PathType Container)) {
        foreach ($d in @(Get-ChildItem -Path $PackagesRoot -Directory -ErrorAction SilentlyContinue)) {
            $n = $d.Name
            if ($n -eq '_manager') { continue }
            if ($ExcludeName -and ($n -eq $ExcludeName)) { continue }
            $mf = Read-EntryManifestForManager -PackagesRoot $PackagesRoot -Name $n
            if ($null -eq $mf) { continue }
            foreach ($c in @(Get-ManifestDeclaredPortClaims -Manifest $mf -Name $n)) {
                $p = [int]$c['port']
                if (-not $index.ContainsKey($p)) { $index[$p] = New-Object System.Collections.Generic.List[object] }
                $index[$p].Add($c)
            }
        }
    }
    if ($ManagerRoot) {
        try {
            $cfg = Read-ManagerConfig -ManagerRoot $ManagerRoot
            $mgrPort = [int]$cfg['port']
            if ($mgrPort -ge 1 -and $mgrPort -le 65535) {
                $owner = 'win-autostart-manager'
                if (-not ($ExcludeName -and ($ExcludeName -eq $owner))) {
                    if (-not $index.ContainsKey($mgrPort)) {
                        $index[$mgrPort] = New-Object System.Collections.Generic.List[object]
                    }
                    $already = $false
                    # PS 5.1: do not wrap List[object] with @() — "Argument types do not match"
                    foreach ($ex in $index[$mgrPort]) {
                        if ([string]$ex['entry'] -eq $owner) { $already = $true; break }
                    }
                    if (-not $already) {
                        $index[$mgrPort].Add([ordered]@{
                            port   = $mgrPort
                            entry  = $owner
                            source = 'manager.listen'
                        })
                    }
                }
            }
        }
        catch { }
    }
    return $index
}

function Get-EntryPortOwnerHints {
    <# Hints to decide if a Listen owner belongs to this entry (process + command paths). #>
    param($Manifest, [string]$Name, [string]$PackagesRoot)
    $imageNames = New-Object System.Collections.Generic.List[string]
    $markers = New-Object System.Collections.Generic.List[string]
    if ($Name) { $markers.Add($Name) }
    $pkgRoot = $null
    if ($PackagesRoot -and $Name) {
        $pkgRoot = Join-Path $PackagesRoot $Name
        if ($pkgRoot) { $markers.Add($pkgRoot) }
    }
    if ($null -ne $Manifest) {
        if (($Manifest.PSObject.Properties.Name -contains 'keepalive') -and $Manifest.keepalive) {
            $proc = $Manifest.keepalive.process
            if ($proc) {
                if (($proc.PSObject.Properties.Name -contains 'imageName') -and $proc.imageName) {
                    $img = [string]$proc.imageName
                    $imageNames.Add($img)
                    $leaf = [System.IO.Path]::GetFileName($img)
                    if ($leaf) { $imageNames.Add($leaf) }
                    $base = [System.IO.Path]::GetFileNameWithoutExtension($img)
                    if ($base) { $imageNames.Add($base) }
                }
                if (($proc.PSObject.Properties.Name -contains 'commandLineContains') -and $proc.commandLineContains) {
                    $markers.Add([string]$proc.commandLineContains)
                }
            }
        }
        if (($Manifest.PSObject.Properties.Name -contains 'workdir') -and $Manifest.workdir) {
            $markers.Add([string]$Manifest.workdir)
        }
        if (($Manifest.PSObject.Properties.Name -contains 'command') -and $Manifest.command) {
            $cmd = [string]$Manifest.command
            $markers.Add($cmd)
            if ($cmd -match '(?i)(?:^|[\s"])([^"\s]+?\.(?:py|ps1|js|mjs|cmd|bat|exe))(?=["\s]|$)') {
                $markers.Add($Matches[1].Trim('"'))
            }
            if ($cmd -match '(?i)-File\s+"([^"]+)"') {
                $markers.Add($Matches[1])
            }
            elseif ($cmd -match '(?i)-File\s+(\S+)') {
                $markers.Add($Matches[1].Trim('"'))
            }
            if ($cmd -match '(?i)-m\s+(\S+)') {
                $markers.Add($Matches[1])
            }
            # First executable token from command
            $tok = ($cmd -replace '^"', '' -split '\s+')[0]
            if ($tok) {
                $tok = $tok.Trim('"')
                $leaf = [System.IO.Path]::GetFileName($tok)
                if ($leaf) { $imageNames.Add($leaf) }
                $base = [System.IO.Path]::GetFileNameWithoutExtension($tok)
                if ($base) { $imageNames.Add($base) }
            }
        }
        if ($pkgRoot) {
            foreach ($leafName in @(($Name + '.cmd'), ($Name + '.vbs'), ($Name + '.json'))) {
                $markers.Add((Join-Path $pkgRoot $leafName))
            }
        }
    }
    $imgOut = @($imageNames | Where-Object { $_ -and "$_".Trim() -ne '' } | ForEach-Object { "$_".Trim() } | Select-Object -Unique)
    $markOut = @($markers | Where-Object { $_ -and ("$_".Trim().Length -ge 3) } | ForEach-Object { "$_".Trim() } | Select-Object -Unique)
    return @{
        imageNames = $imgOut
        markers    = $markOut
    }
}

function Get-LocalPortListeners {
    <# Listeners on any local address for this port (incl 0.0.0.0 / ::). Hook: PortListenProbeHook. #>
    param([int]$Port)
    if ($script:PortListenProbeHook -is [scriptblock]) {
        $hooked = & $script:PortListenProbeHook -Port $Port
        if ($null -eq $hooked) { return @() }
        return @($hooked)
    }
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        $conns = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { [int]$_.LocalPort -eq $Port })
    }
    catch {
        $conns = @()
    }
    $seenPid = @{}
    foreach ($c in $conns) {
        $procId = 0
        try { $procId = [int]$c.OwningProcess } catch { continue }
        if ($procId -le 0) { continue }
        if ($seenPid.ContainsKey($procId)) { continue }
        $seenPid[$procId] = $true
        $procName = $null
        $cmdLine = $null
        try {
            $wp = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f $procId) -ErrorAction SilentlyContinue
            if ($wp) {
                $procName = [string]$wp.Name
                $cmdLine = [string]$wp.CommandLine
            }
        }
        catch { }
        if (-not $procName) {
            try {
                $gp = Get-Process -Id $procId -ErrorAction SilentlyContinue
                if ($gp) { $procName = [string]$gp.ProcessName + '.exe' }
            }
            catch { }
        }
        $rows.Add([ordered]@{
            pid          = $procId
            processName  = $procName
            commandLine  = $cmdLine
            localAddress = [string]$c.LocalAddress
        })
    }
    return @($rows.ToArray())
}

function Test-ListenerBelongsToEntry {
    param(
        $Listener,
        $Hints
    )
    if ($null -eq $Listener -or $null -eq $Hints) { return $false }
    $pn = [string]$Listener['processName']
    if (-not $pn) { $pn = [string]$Listener.processName }
    $cl = [string]$Listener['commandLine']
    if (-not $cl) { $cl = [string]$Listener.commandLine }

    $markers = @($Hints['markers'])
    if ($markers.Count -eq 0) { $markers = @($Hints.markers) }
    foreach ($m in $markers) {
        if (-not $m) { continue }
        if ($cl -and ($cl.IndexOf([string]$m, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)) {
            return $true
        }
    }

    $images = @($Hints['imageNames'])
    if ($images.Count -eq 0) { $images = @($Hints.imageNames) }
    $imgHit = $false
    foreach ($img in $images) {
        if (-not $img -or -not $pn) { continue }
        if ($pn -ieq $img) { $imgHit = $true; break }
        if ($pn -ieq ($img + '.exe')) { $imgHit = $true; break }
        $base = [System.IO.Path]::GetFileNameWithoutExtension($img)
        $pnBase = [System.IO.Path]::GetFileNameWithoutExtension($pn)
        if ($base -and $pnBase -and ($base -ieq $pnBase)) { $imgHit = $true; break }
    }
    if (-not $imgHit) { return $false }
    # Image-only hit: allow if no cmdline; if cmdline present require a marker (avoid python/node false self)
    if (-not $cl) { return $true }
    if ($markers.Count -eq 0) { return $true }
    return $false
}

function Format-PortConflictsError {
    <# ASCII-only for PS 5.1 script encoding safety; UI formats Chinese from conflicts[]. #>
    param([object[]]$Conflicts)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($c in @($Conflicts)) {
        $kind = [string]$c['kind']
        $port = [int]$c['port']
        if ($kind -eq 'declared') {
            $parts.Add(('port {0} claimed by {1} ({2})' -f $port, $c['entry'], $c['source']))
        }
        elseif ($kind -eq 'listen') {
            $who = ('PID {0}' -f $c['pid'])
            if ($c['processName']) { $who = $who + (', {0}' -f $c['processName']) }
            $parts.Add(('port {0} in use by local process ({1}), not matched to this entry' -f $port, $who))
        }
        else {
            $parts.Add(('port {0} conflict' -f $port))
        }
    }
    if ($parts.Count -eq 0) { return 'port conflict' }
    return ('port conflict: ' + ($parts -join '; '))
}

function Test-ProposedPortsConflicts {
    <#
      Conflict check for proposed ports:
      1) vs other entries' exposedPorts / health.tcpPorts (and manager.listen) -> reject
      2) vs local Listen on any address without self-match -> reject
      Self Listen ownership -> allow
    #>
    param(
        [string]$PackagesRoot,
        [string]$ManagerRoot,
        [string]$Name,
        [int[]]$ProposedPorts,
        $Manifest
    )
    $conflicts = New-Object System.Collections.Generic.List[object]
    $ports = ConvertTo-IntPortArray -Raw $ProposedPorts
    if ($null -eq $ports -or $ports.Count -eq 0) {
        return @{ ok = $true; conflicts = @(); error = $null }
    }
    $foreign = Get-ForeignPortClaimIndex -PackagesRoot $PackagesRoot -ExcludeName $Name -ManagerRoot $ManagerRoot
    $hints = Get-EntryPortOwnerHints -Manifest $Manifest -Name $Name -PackagesRoot $PackagesRoot
    foreach ($p in $ports) {
        if ($foreign.ContainsKey([int]$p)) {
            # PS 5.1: do not wrap List[object] with @() — "Argument types do not match"
            foreach ($claim in $foreign[[int]$p]) {
                $conflicts.Add([ordered]@{
                    kind   = 'declared'
                    port   = [int]$p
                    entry  = [string]$claim['entry']
                    source = [string]$claim['source']
                })
            }
            continue
        }
        $listeners = @(Get-LocalPortListeners -Port ([int]$p))
        if ($listeners.Count -eq 0) { continue }
        $allSelf = $true
        foreach ($lis in $listeners) {
            if (-not (Test-ListenerBelongsToEntry -Listener $lis -Hints $hints)) {
                $allSelf = $false
                $conflicts.Add([ordered]@{
                    kind        = 'listen'
                    port        = [int]$p
                    pid         = [int]$lis['pid']
                    processName = [string]$lis['processName']
                    commandLine = [string]$lis['commandLine']
                })
            }
        }
        if ($allSelf) { continue }
    }
    if ($conflicts.Count -eq 0) {
        return @{ ok = $true; conflicts = @(); error = $null }
    }
    $arr = @($conflicts.ToArray())
    return @{
        ok        = $false
        conflicts = $arr
        error     = (Format-PortConflictsError -Conflicts $arr)
    }
}

function Read-EntryExposedPorts {
    param([string]$PackagesRoot, [string]$Name)
    $manifest = Read-EntryManifestForManager -PackagesRoot $PackagesRoot -Name $Name
    if ($null -eq $manifest) {
        return @{ ok = $false; error = 'entry_not_found'; exposedPorts = ,[int[]]@(); path = $null }
    }
    $raw = $null
    if ($manifest.PSObject.Properties.Name -contains 'exposedPorts') {
        $raw = $manifest.exposedPorts
    }
    $ports = Normalize-ExposedPorts -Raw $raw
    $path = Get-EntryManifestPath -PackagesRoot $PackagesRoot -Name $Name
    return @{ ok = $true; error = $null; exposedPorts = $ports; path = $path }
}

function Get-ManagerScheduledTaskIndex {
    <# taskName -> State string, via one CIM enumeration; cached briefly. #>
    param([int]$TtlSec = 5)
    $now = Get-Date
    if ($null -ne $script:ManagerSchedTaskCache) {
        $age = (New-TimeSpan -Start $script:ManagerSchedTaskCache['at'] -End $now).TotalSeconds
        if ($age -lt [int]$TtlSec) {
            return $script:ManagerSchedTaskCache['index']
        }
    }
    $index = @{}
    try {
        foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
            $index[[string]$t.TaskName] = [string]$t.State
        }
    }
    catch { }
    $script:ManagerSchedTaskCache = @{ at = $now; index = $index }
    return $index
}

function Clear-ManagerScheduledTaskIndexCache {
    $script:ManagerSchedTaskCache = $null
}

function Get-ManagerEntryEnabledFast {
    <#
      In-process mirror of CLI Get-EntryEnabled using the cached task index.
      scheduled-task: State Disabled -> false, other -> true, missing -> null.
      startup: .lnk -> true, .lnk.disabled -> false, else null.
      run-key: registry value present -> true, else false.
    #>
    param([string]$Name, [string]$Landing, $TaskIndex)
    if (-not $Landing) { return $null }
    if ($Landing -eq 'scheduled-task') {
        if (-not $TaskIndex.ContainsKey($Name)) { return $null }
        $state = [string]$TaskIndex[$Name]
        if ($state -eq 'Disabled') { return $false }
        return $true
    }
    if ($Landing -eq 'startup') {
        $startupDir = [Environment]::GetFolderPath('Startup')
        $lnkPath = Join-Path $startupDir ($Name + '.lnk')
        if (Test-Path -Path $lnkPath -PathType Leaf) { return $true }
        if (Test-Path -Path ($lnkPath + '.disabled') -PathType Leaf) { return $false }
        return $null
    }
    if ($Landing -eq 'run-key') {
        try {
            $key = Get-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
            if (-not $key) { return $false }
            return ($null -ne $key.GetValue($Name, $null))
        }
        catch { return $false }
    }
    return $null
}

function Get-ManagerEntriesFast {
    <#
      In-process /entries source: dir scan + manifest JSON read, no CLI spawn.
      Mirrors CLI Invoke-List entry shape (name/landing/mode/enabled/schema/root)
      and pre-computes exposedPorts; landing fallback probes use the cached
      scheduled-task index instead of per-entry CIM calls.
    #>
    param([string]$PackagesRoot)
    $entries = New-Object System.Collections.Generic.List[object]
    if (-not $PackagesRoot -or -not (Test-Path -Path $PackagesRoot -PathType Container)) {
        return @{ parent = $PackagesRoot; entries = $entries }
    }
    $taskIndex = Get-ManagerScheduledTaskIndex
    $startupDir = [Environment]::GetFolderPath('Startup')
    $runKey = $null
    try {
        $runKey = Get-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
    }
    catch { }

    foreach ($d in @(Get-ChildItem -Path $PackagesRoot -Directory -ErrorAction SilentlyContinue)) {
        $name = $d.Name
        if ($name -eq '_manager') { continue }
        $root = $d.FullName
        $manifest = Read-EntryManifestForManager -PackagesRoot $PackagesRoot -Name $name
        $vbsPath = Join-Path $root ($name + '.vbs')
        $cmdPath = Join-Path $root ($name + '.cmd')
        $hasArtifacts = (Test-Path -Path $vbsPath -PathType Leaf) -or (Test-Path -Path $cmdPath -PathType Leaf)
        if ($null -eq $manifest -and -not $hasArtifacts) { continue }

        $landing = $null
        $mode = $null
        $schema = $null
        $rawPorts = $null
        if ($null -ne $manifest) {
            $props = $manifest.PSObject.Properties.Name
            if (($props -contains 'landing') -and $manifest.landing) { $landing = [string]$manifest.landing }
            if (($props -contains 'mode') -and $manifest.mode) { $mode = [string]$manifest.mode }
            if (($props -contains 'schema') -and $manifest.schema) { $schema = [string]$manifest.schema }
            if ($props -contains 'exposedPorts') { $rawPorts = $manifest.exposedPorts }
        }
        if (-not $landing) {
            $lnkPath = Join-Path $startupDir ($name + '.lnk')
            if ($taskIndex.ContainsKey($name)) { $landing = 'scheduled-task' }
            elseif ((Test-Path -Path $lnkPath -PathType Leaf) -or (Test-Path -Path ($lnkPath + '.disabled') -PathType Leaf)) { $landing = 'startup' }
            elseif ($runKey -and ($null -ne $runKey.GetValue($name, $null))) { $landing = 'run-key' }
        }
        $enabled = Get-ManagerEntryEnabledFast -Name $name -Landing $landing -TaskIndex $taskIndex
        $entries.Add([ordered]@{
            name         = $name
            landing      = $landing
            mode         = $mode
            enabled      = $enabled
            schema       = $schema
            root         = $root
            exposedPorts = $(Normalize-ExposedPorts -Raw $rawPorts)
        })
    }
    return @{ parent = $PackagesRoot; entries = $entries }
}

function Write-EntryExposedPorts {
    param([string]$PackagesRoot, [string]$Name, $PortsBody)
    $path = Get-EntryManifestPath -PackagesRoot $PackagesRoot -Name $Name
    if (-not (Test-Path -Path $path -PathType Leaf)) {
        return @{ ok = $false; error = 'entry_not_found'; exposedPorts = ,[int[]]@(); path = $null }
    }
    $raw = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $map = ConvertTo-PlainMap $raw
    $incoming = $PortsBody
    if ($PortsBody -is [hashtable] -or $PortsBody -is [System.Collections.IDictionary]) {
        $incoming = ConvertTo-PlainMap $PortsBody
        if ($incoming.ContainsKey('exposedPorts')) { $incoming = $incoming['exposedPorts'] }
    }
    elseif ($null -ne $PortsBody -and ($PortsBody.PSObject.Properties.Name -contains 'exposedPorts')) {
        $incoming = $PortsBody.exposedPorts
    }
    $ports = Normalize-ExposedPorts -Raw $incoming
    $map['exposedPorts'] = @($ports)
    if (-not $map.ContainsKey('schema') -or -not $map['schema']) {
        $map['schema'] = 'windows-autostart/2'
    }
    elseif ([string]$map['schema'] -eq 'windows-autostart/1') {
        $map['schema'] = 'windows-autostart/2'
    }
    $ordered = [ordered]@{}
    foreach ($k in @('schema', 'name', 'command', 'workdir', 'mode', 'landing', 'elevated', 'root', 'createdAt', 'keepalive', 'exposedPorts')) {
        if ($map.ContainsKey($k)) { $ordered[$k] = $map[$k] }
    }
    foreach ($k in @($map.Keys | Sort-Object)) {
        if (-not $ordered.Contains($k)) { $ordered[$k] = $map[$k] }
    }
    Write-JsonFile -Path $path -Doc $ordered -Depth 12
    return @{ ok = $true; error = $null; exposedPorts = $ports; path = $path }
}

function Invoke-PortsApi {
    param(
        [string]$Method,
        [string]$Name,
        $Request,
        $Response,
        [string]$PackagesRoot,
        [string]$ManagerRoot
    )
    if ($Method -eq 'GET') {
        $r = Read-EntryExposedPorts -PackagesRoot $PackagesRoot -Name $Name
        if (-not $r.ok) {
            Send-ApiJson -Response $Response -StatusCode 404 -Body @{ ok = $false; error = $r.error }
            return
        }
        Send-ApiJson -Response $Response -StatusCode 200 -Body @{
            ok           = $true
            name         = $Name
            exposedPorts = @($r.exposedPorts)
            path         = $r.path
        }
        return
    }
    if ($Method -eq 'PUT') {
        $bodyText = Read-RequestBodyText -Request $Request
        if (-not $bodyText) {
            Send-ApiJson -Response $Response -StatusCode 400 -Body @{ ok = $false; error = 'empty_body' }
            return
        }
        try {
            $incoming = $bodyText | ConvertFrom-Json
        }
        catch {
            Send-ApiJson -Response $Response -StatusCode 400 -Body @{ ok = $false; error = 'invalid_json' }
            return
        }
        if ($null -eq $incoming -or -not ($incoming.PSObject.Properties.Name -contains 'exposedPorts')) {
            Send-ApiJson -Response $Response -StatusCode 400 -Body @{ ok = $false; error = 'missing_exposedPorts' }
            return
        }
        $proposed = ConvertTo-IntPortArray -Raw $incoming.exposedPorts
        $manifest = Read-EntryManifestForManager -PackagesRoot $PackagesRoot -Name $Name
        if ($null -eq $manifest) {
            Send-ApiJson -Response $Response -StatusCode 404 -Body @{ ok = $false; error = 'entry_not_found' }
            return
        }
        $chk = Test-ProposedPortsConflicts -PackagesRoot $PackagesRoot -ManagerRoot $ManagerRoot `
            -Name $Name -ProposedPorts $proposed -Manifest $manifest
        if (-not $chk.ok) {
            Send-ApiJson -Response $Response -StatusCode 409 -Body @{
                ok        = $false
                error     = $chk.error
                conflicts = @($chk.conflicts)
            }
            return
        }
        $w = Write-EntryExposedPorts -PackagesRoot $PackagesRoot -Name $Name -PortsBody $incoming
        if (-not $w.ok) {
            Send-ApiJson -Response $Response -StatusCode 404 -Body @{ ok = $false; error = $w.error }
            return
        }
        Clear-CliStatusCache
        Write-ManagerLog -ManagerRoot $ManagerRoot -Level 'INFO' -Message ("exposedPorts updated for '{0}'" -f $Name)
        Send-ApiJson -Response $Response -StatusCode 200 -Body @{
            ok           = $true
            name         = $Name
            exposedPorts = @($w.exposedPorts)
            path         = $w.path
        }
        return
    }
    Send-ApiJson -Response $Response -StatusCode 405 -Body @{ ok = $false; error = 'method_not_allowed' }
}

function Invoke-KeepaliveApi {
    param(
        [string]$Method,
        [string]$Name,
        $Request,
        $Response,
        [string]$PackagesRoot,
        [string]$ManagerRoot
    )
    if ($Method -eq 'GET') {
        $r = Read-EntryKeepalive -PackagesRoot $PackagesRoot -Name $Name
        if (-not $r.ok) {
            Send-ApiJson -Response $Response -StatusCode 404 -Body @{ ok = $false; error = $r.error }
            return
        }
        Send-ApiJson -Response $Response -StatusCode 200 -Body @{
            ok        = $true
            name      = $Name
            landing   = $r.landing
            keepalive = $r.keepalive
            path      = $r.path
        }
        return
    }
    if ($Method -eq 'PUT') {
        $bodyText = Read-RequestBodyText -Request $Request
        if (-not $bodyText) {
            Send-ApiJson -Response $Response -StatusCode 400 -Body @{ ok = $false; error = 'empty_body' }
            return
        }
        try {
            $incoming = $bodyText | ConvertFrom-Json
        }
        catch {
            Send-ApiJson -Response $Response -StatusCode 400 -Body @{ ok = $false; error = 'invalid_json' }
            return
        }
        # Accept either { keepalive: {...} } or bare keepalive object
        $kaBody = $incoming
        if ($incoming.PSObject.Properties.Name -contains 'keepalive' -and $null -ne $incoming.keepalive) {
            $kaBody = $incoming.keepalive
        }
        $manifest = Read-EntryManifestForManager -PackagesRoot $PackagesRoot -Name $Name
        if ($null -eq $manifest) {
            Send-ApiJson -Response $Response -StatusCode 404 -Body @{ ok = $false; error = 'entry_not_found' }
            return
        }
        # Proposed health.tcpPorts use the same conflict rules as exposedPorts
        $proposedTcp = @()
        $kaMap = ConvertTo-PlainMap $kaBody
        if ($kaMap.ContainsKey('health') -and $null -ne $kaMap['health']) {
            $hMap = ConvertTo-PlainMap $kaMap['health']
            if ($hMap.ContainsKey('tcpPorts')) {
                $proposedTcp = ConvertTo-IntPortArray -Raw $hMap['tcpPorts']
            }
        }
        if ($null -ne $proposedTcp -and $proposedTcp.Count -gt 0) {
            $chk = Test-ProposedPortsConflicts -PackagesRoot $PackagesRoot -ManagerRoot $ManagerRoot `
                -Name $Name -ProposedPorts $proposedTcp -Manifest $manifest
            if (-not $chk.ok) {
                Send-ApiJson -Response $Response -StatusCode 409 -Body @{
                    ok        = $false
                    error     = $chk.error
                    conflicts = @($chk.conflicts)
                }
                return
            }
        }
        $w = Write-EntryKeepalive -PackagesRoot $PackagesRoot -Name $Name -KeepaliveBody $kaBody
        if (-not $w.ok) {
            Send-ApiJson -Response $Response -StatusCode 404 -Body @{ ok = $false; error = $w.error }
            return
        }
        Clear-CliStatusCache
        Write-ManagerLog -ManagerRoot $ManagerRoot -Level 'INFO' -Message ("keepalive updated for '{0}'" -f $Name)
        Send-ApiJson -Response $Response -StatusCode 200 -Body @{
            ok        = $true
            name      = $Name
            keepalive = $w.keepalive
            path      = $w.path
        }
        return
    }
    Send-ApiJson -Response $Response -StatusCode 405 -Body @{ ok = $false; error = 'method_not_allowed' }
}

function Resolve-ManagerWwwRoot {
    <# Prefer tray/www next to manager script; fall back to www/ sibling. #>
    param([string]$ManagerScriptPath, [string]$Override)
    if ($Override -and (Test-Path -Path $Override -PathType Container)) {
        return (Resolve-Path -Path $Override).Path
    }
    if (-not $ManagerScriptPath) { return $null }
    $root = Split-Path -Parent $ManagerScriptPath
    $candidates = @(
        (Join-Path (Join-Path $root 'tray') 'www'),
        (Join-Path $root 'www')
    )
    foreach ($c in $candidates) {
        if (Test-Path -Path $c -PathType Container) {
            return (Resolve-Path -Path $c).Path
        }
    }
    return $null
}

function Get-StaticContentType {
    param([string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($ext) {
        '.html' { return 'text/html; charset=utf-8' }
        '.htm'  { return 'text/html; charset=utf-8' }
        '.css'  { return 'text/css; charset=utf-8' }
        '.js'   { return 'application/javascript; charset=utf-8' }
        '.json' { return 'application/json; charset=utf-8' }
        '.svg'  { return 'image/svg+xml' }
        '.png'  { return 'image/png' }
        '.ico'  { return 'image/x-icon' }
        '.woff' { return 'font/woff' }
        '.woff2'{ return 'font/woff2' }
        '.map'  { return 'application/json' }
        default { return 'application/octet-stream' }
    }
}

function Send-StaticWwwFile {
    param($Request, $Response, [string]$WwwRoot)
    $rel = $Request.Url.AbsolutePath
    if (-not $rel -or $rel -eq '/') { $rel = '/index.html' }
    $rel = [System.Uri]::UnescapeDataString($rel)
    # Block path traversal
    $relNorm = $rel.Replace('\', '/').TrimStart('/')
    if ($relNorm -match '\.\.' -or $relNorm -match '^[a-zA-Z]:') {
        $Response.StatusCode = 400
        $Response.Close()
        return
    }
    $full = [System.IO.Path]::GetFullPath((Join-Path $WwwRoot ($relNorm -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
    $rootFull = [System.IO.Path]::GetFullPath($WwwRoot)
    if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        $Response.StatusCode = 403
        $Response.Close()
        return
    }
    if (-not (Test-Path -Path $full -PathType Leaf)) {
        # SPA-ish fallback: unknown paths → index.html for panel routes
        $index = Join-Path $WwwRoot 'index.html'
        if (Test-Path -Path $index -PathType Leaf) {
            $full = $index
        }
        else {
            Send-ApiJson -Response $Response -StatusCode 404 -Body @{ ok = $false; error = 'not_found' }
            return
        }
    }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($full)
        $Response.StatusCode = 200
        $Response.ContentType = (Get-StaticContentType -Path $full)
        $Response.ContentLength64 = $bytes.Length
        if ($Request.HttpMethod -ne 'HEAD') {
            $Response.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        $Response.OutputStream.Close()
    }
    catch {
        try {
            Send-ApiJson -Response $Response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
        }
        catch { }
    }
}

function Get-ManagerApiRouteTable {
    <# Contract helper for tests: documented routes. #>
    return @(
        @{ Method = 'GET';  Path = '/api/v1/health' }
        @{ Method = 'POST'; Path = '/api/v1/pause' }
        @{ Method = 'POST'; Path = '/api/v1/pause/resume' }
        @{ Method = 'GET';  Path = '/api/v1/entries' }
        @{ Method = 'GET';  Path = '/api/v1/entries/{name}' }
        @{ Method = 'POST'; Path = '/api/v1/entries/{name}/start' }
        @{ Method = 'POST'; Path = '/api/v1/entries/{name}/stop' }
        @{ Method = 'POST'; Path = '/api/v1/entries/{name}/restart' }
        @{ Method = 'POST'; Path = '/api/v1/entries/{name}/enable' }
        @{ Method = 'POST'; Path = '/api/v1/entries/{name}/disable' }
        @{ Method = 'GET';  Path = '/api/v1/entries/{name}/keepalive' }
        @{ Method = 'PUT';  Path = '/api/v1/entries/{name}/keepalive' }
        @{ Method = 'GET';  Path = '/api/v1/entries/{name}/ports' }
        @{ Method = 'PUT';  Path = '/api/v1/entries/{name}/ports' }
        @{ Method = 'GET';  Path = '/api/v1/watches' }
        @{ Method = 'PUT';  Path = '/api/v1/watches' }
        @{ Method = 'POST'; Path = '/api/v1/watches' }
        @{ Method = 'DELETE'; Path = '/api/v1/watches/{id}' }
    )
}
