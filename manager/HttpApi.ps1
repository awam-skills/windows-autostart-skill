#Requires -Version 5.1
# Minimal localhost HTTP API via System.Net.HttpListener (PS 5.1).

Set-StrictMode -Version 2.0

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
                    # GET /api/v1/entries
                    if ($method -ne 'GET') { Send-ApiJson -Response $Response -StatusCode 405 -Body @{ ok = $false; error = 'method_not_allowed' }; return }
                    $list = Invoke-CliList -CliPath $CliPath -PackagesRoot $PackagesRoot
                    $enriched = New-Object System.Collections.Generic.List[object]
                    foreach ($e in @($list.Entries)) {
                        $em = ConvertTo-PlainMap $e
                        $name = [string]$em['name']
                        $st = Get-ManagerEntryState -ManagerRoot $ManagerRoot -Name $name
                        $row = [ordered]@{}
                        foreach ($k in @($em.Keys)) { $row[$k] = $em[$k] }
                        $row['managerState'] = $st
                        $portsInfo = Read-EntryExposedPorts -PackagesRoot $PackagesRoot -Name $name
                        $row['exposedPorts'] = @($portsInfo.exposedPorts)
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
                    # GET /api/v1/entries/{name}
                    if ($method -ne 'GET') { Send-ApiJson -Response $Response -StatusCode 405 -Body @{ ok = $false; error = 'method_not_allowed' }; return }
                    $st = Invoke-CliStatus -CliPath $CliPath -Name $name -PackagesRoot $PackagesRoot
                    $slice = Get-ManagerEntryState -ManagerRoot $ManagerRoot -Name $name
                    Send-ApiJson -Response $Response -StatusCode 200 -Body @{
                        ok           = ($st.result -eq 'ok')
                        cli          = @{ result = $st.result; error = $st.error; data = $st.data }
                        managerState = $slice
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

                $cliResult = $null
                switch ($action) {
                    'start' {
                        $cliResult = Invoke-CliRun -CliPath $CliPath -Name $name -PackagesRoot $PackagesRoot
                        Send-ApiJson -Response $Response -StatusCode 200 -Body @{ ok = ($cliResult.result -eq 'ok' -or $cliResult.result -eq 'partial'); result = $cliResult.result; error = $cliResult.error; data = $cliResult.data }
                        return
                    }
                    'stop' {
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
    <# 校验为 1–65535 的整数，去重后升序。非法项忽略。 #>
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
        $w = Write-EntryExposedPorts -PackagesRoot $PackagesRoot -Name $Name -PortsBody $incoming
        if (-not $w.ok) {
            Send-ApiJson -Response $Response -StatusCode 404 -Body @{ ok = $false; error = $w.error }
            return
        }
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
        $w = Write-EntryKeepalive -PackagesRoot $PackagesRoot -Name $Name -KeepaliveBody $kaBody
        if (-not $w.ok) {
            Send-ApiJson -Response $Response -StatusCode 404 -Body @{ ok = $false; error = $w.error }
            return
        }
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
