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
    $p = $AbsolutePath.TrimEnd('/')
    if (-not $p) { $p = '/' }
    $parts = $p.Split('/') | Where-Object { $_ -ne '' }
    return @($parts)
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
        $Cfg
    )

    if (-not (Test-ApiToken -Request $Request -Cfg $Cfg)) {
        Send-ApiJson -Response $Response -StatusCode 401 -Body @{ ok = $false; error = 'unauthorized' }
        return
    }

    $method = $Request.HttpMethod.ToUpperInvariant()
    $segs = Get-ApiPathSegments -AbsolutePath $Request.Url.AbsolutePath

    # Expect api/v1/...
    if ($segs.Count -lt 2 -or $segs[0] -ne 'api' -or $segs[1] -ne 'v1') {
        Send-ApiJson -Response $Response -StatusCode 404 -Body @{ ok = $false; error = 'not_found' }
        return
    }

    $resource = if ($segs.Count -ge 3) { $segs[2] } else { '' }

    try {
        switch ($resource) {
            'health' {
                if ($method -ne 'GET') { Send-ApiJson -Response $Response -StatusCode 405 -Body @{ ok = $false; error = 'method_not_allowed' }; return }
                Send-ApiJson -Response $Response -StatusCode 200 -Body @{
                    ok        = $true
                    startedAt = $StartedAt.ToString('o')
                }
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
                        Send-ApiJson -Response $Response -StatusCode 200 -Body @{ ok = $true; saved = $true }
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
                        Send-ApiJson -Response $Response -StatusCode 200 -Body @{ ok = $true; item = $item }
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
                    Send-ApiJson -Response $Response -StatusCode 200 -Body @{ ok = $true; removed = $removed; id = $wid }
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
            -StartedAt $StartedAt -DryRun:$DryRun -Cfg $Cfg
    }
    catch {
        try {
            Send-ApiJson -Response $ctx.Response -StatusCode 500 -Body @{ ok = $false; error = $_.Exception.Message }
        }
        catch { }
    }
    return $true
}

function Get-ManagerApiRouteTable {
    <# Contract helper for tests: documented routes. #>
    return @(
        @{ Method = 'GET';  Path = '/api/v1/health' }
        @{ Method = 'GET';  Path = '/api/v1/entries' }
        @{ Method = 'GET';  Path = '/api/v1/entries/{name}' }
        @{ Method = 'POST'; Path = '/api/v1/entries/{name}/start' }
        @{ Method = 'POST'; Path = '/api/v1/entries/{name}/stop' }
        @{ Method = 'POST'; Path = '/api/v1/entries/{name}/restart' }
        @{ Method = 'POST'; Path = '/api/v1/entries/{name}/enable' }
        @{ Method = 'POST'; Path = '/api/v1/entries/{name}/disable' }
        @{ Method = 'GET';  Path = '/api/v1/watches' }
        @{ Method = 'PUT';  Path = '/api/v1/watches' }
        @{ Method = 'POST'; Path = '/api/v1/watches' }
        @{ Method = 'DELETE'; Path = '/api/v1/watches/{id}' }
    )
}
