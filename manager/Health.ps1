#Requires -Version 5.1
# Health loop: TCP / HTTP / process probes → consecutive failures → Restart-Entry.

Set-StrictMode -Version 2.0

function Test-ManagerTcpPort {
    param(
        [string]$HostName = '127.0.0.1',
        [int]$Port,
        [int]$TimeoutMs = 800
    )
    if ($script:TcpProbeHook -is [scriptblock]) {
        return [bool](& $script:TcpProbeHook -HostName $HostName -Port $Port -TimeoutMs $TimeoutMs)
    }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $ok) { return $false }
        try { $client.EndConnect($iar) } catch { return $false }
        return $true
    }
    catch {
        return $false
    }
    finally {
        try { $client.Close() } catch { }
    }
}

function Test-ManagerHttpHealth {
    param(
        [string]$Url,
        [int[]]$ExpectStatus = @(200),
        [int]$TimeoutSec = 5
    )
    if ($script:HttpProbeHook -is [scriptblock]) {
        return [bool](& $script:HttpProbeHook -Url $Url -ExpectStatus $ExpectStatus -TimeoutSec $TimeoutSec)
    }
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        $code = [int]$resp.StatusCode
        return ($ExpectStatus -contains $code)
    }
    catch {
        # Some hosts throw on non-2xx; try to read status from exception response
        try {
            $exResp = $_.Exception.Response
            if ($exResp) {
                $code = [int]$exResp.StatusCode
                return ($ExpectStatus -contains $code)
            }
        }
        catch { }
        return $false
    }
}

function Test-ManagerProcessAlive {
    param(
        [string]$ImageName,
        [string]$CommandLineContains
    )
    if ($script:ProcessProbeHook -is [scriptblock]) {
        return [bool](& $script:ProcessProbeHook -ImageName $ImageName -CommandLineContains $CommandLineContains)
    }
    if (-not $ImageName) { return $false }
    $leaf = [System.IO.Path]::GetFileName($ImageName)
    try {
        # WQL filter by name: avoids enumerating every Win32_Process on the box
        # on each probe (the old full scan blocked the serve loop for seconds).
        $nameClauses = New-Object System.Collections.Generic.List[string]
        foreach ($n in @($leaf, [string]$ImageName)) {
            $s = [string]$n
            if (-not $s) { continue }
            $nameClauses.Add(("Name = '{0}'" -f $s.Replace("'", "''")))
        }
        $filter = ($nameClauses -join ' OR ')
        $procs = @(Get-CimInstance -ClassName Win32_Process -Filter $filter -ErrorAction Stop |
            Where-Object {
                if ($CommandLineContains) {
                    $cl = [string]$_.CommandLine
                    if (-not $cl) { return $false }
                    return ($cl -like ("*{0}*" -f $CommandLineContains))
                }
                return $true
            })
        return ($procs.Count -gt 0)
    }
    catch {
        # Fallback: Get-Process by base name (no command line filter)
        try {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($ImageName)
            $gp = @(Get-Process -Name $base -ErrorAction SilentlyContinue)
            if ($CommandLineContains) {
                # Without CIM we cannot filter command line reliably
                return ($gp.Count -gt 0)
            }
            return ($gp.Count -gt 0)
        }
        catch { return $false }
    }
}

function Get-EntryManifestPath {
    param([string]$PackagesRoot, [string]$Name)
    $root = Join-Path $PackagesRoot $Name
    return (Join-Path $root ($Name + '.json'))
}

function Read-EntryManifestForManager {
    param([string]$PackagesRoot, [string]$Name)
    $path = Get-EntryManifestPath -PackagesRoot $PackagesRoot -Name $Name
    if (-not (Test-Path -Path $path -PathType Leaf)) { return $null }
    try {
        return (Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch { return $null }
}

function Get-KeepaliveProbePlan {
    <#
      Returns $null if no health/process probe enabled; else hashtable of checks.
    #>
    param($Manifest, $Cfg)
    if ($null -eq $Manifest) { return $null }
    $ka = $null
    if ($Manifest.PSObject.Properties.Name -contains 'keepalive') { $ka = $Manifest.keepalive }
    if ($null -eq $ka) { return $null }

    $healthEnabled = $false
    $processEnabled = $false
    $intervalSec = [int]$Cfg['healthDefaultIntervalSec']
    $failureThreshold = 3
    $tcpPorts = @()
    $http = $null
    $imageName = $null
    $cmdContains = $null

    if ($ka.PSObject.Properties.Name -contains 'health' -and $ka.health) {
        $h = $ka.health
        if ($h.PSObject.Properties.Name -contains 'enabled') { $healthEnabled = [bool]$h.enabled }
        if ($h.PSObject.Properties.Name -contains 'intervalSec' -and $null -ne $h.intervalSec) {
            $intervalSec = [int]$h.intervalSec
        }
        if ($h.PSObject.Properties.Name -contains 'failureThreshold' -and $null -ne $h.failureThreshold) {
            $failureThreshold = [int]$h.failureThreshold
        }
        if ($h.PSObject.Properties.Name -contains 'tcpPorts' -and $null -ne $h.tcpPorts) {
            $raw = $h.tcpPorts
            if ($raw -is [System.Array]) { $tcpPorts = @($raw | ForEach-Object { [int]$_ }) }
            elseif ($null -ne $raw) { $tcpPorts = @([int]$raw) }
        }
        if ($h.PSObject.Properties.Name -contains 'http' -and $null -ne $h.http) {
            $http = $h.http
        }
    }
    if ($ka.PSObject.Properties.Name -contains 'process' -and $ka.process) {
        $p = $ka.process
        if ($p.PSObject.Properties.Name -contains 'enabled') { $processEnabled = [bool]$p.enabled }
        if ($p.PSObject.Properties.Name -contains 'imageName') { $imageName = $p.imageName }
        if ($p.PSObject.Properties.Name -contains 'commandLineContains') { $cmdContains = $p.commandLineContains }
    }

    if (-not $healthEnabled -and -not $processEnabled) { return $null }
    if ($intervalSec -lt 1) { $intervalSec = [int]$Cfg['healthDefaultIntervalSec'] }
    if ($failureThreshold -lt 1) { $failureThreshold = 1 }

    return @{
        healthEnabled     = $healthEnabled
        processEnabled    = $processEnabled
        intervalSec       = $intervalSec
        failureThreshold  = $failureThreshold
        tcpPorts          = $tcpPorts
        http              = $http
        imageName         = $imageName
        commandLineContains = $cmdContains
    }
}

function Invoke-EntryHealthCheck {
    param($Plan)
    $failures = New-Object System.Collections.Generic.List[string]
    $oks = New-Object System.Collections.Generic.List[string]

    if ($Plan.healthEnabled) {
        foreach ($port in @($Plan.tcpPorts)) {
            $open = Test-ManagerTcpPort -HostName '127.0.0.1' -Port ([int]$port)
            if ($open) { $oks.Add("tcp:$port") }
            else { $failures.Add("tcp:$port") }
        }
        if ($null -ne $Plan.http) {
            $url = $null
            $expect = @(200)
            $h = $Plan.http
            if ($h -is [hashtable] -or $h -is [System.Collections.Specialized.OrderedDictionary]) {
                $url = [string]$h['url']
                if ($h.ContainsKey('expectStatus') -and $null -ne $h['expectStatus']) {
                    $es = $h['expectStatus']
                    if ($es -is [System.Array]) { $expect = @($es | ForEach-Object { [int]$_ }) }
                    else { $expect = @([int]$es) }
                }
            }
            else {
                if ($h.PSObject.Properties.Name -contains 'url') { $url = [string]$h.url }
                if ($h.PSObject.Properties.Name -contains 'expectStatus' -and $null -ne $h.expectStatus) {
                    $es = $h.expectStatus
                    if ($es -is [System.Array]) { $expect = @($es | ForEach-Object { [int]$_ }) }
                    else { $expect = @([int]$es) }
                }
            }
            if ($url) {
                $ok = Test-ManagerHttpHealth -Url $url -ExpectStatus $expect
                if ($ok) { $oks.Add("http:$url") }
                else { $failures.Add("http:$url") }
            }
        }
    }

    if ($Plan.processEnabled) {
        $alive = Test-ManagerProcessAlive -ImageName ([string]$Plan.imageName) -CommandLineContains ([string]$Plan.commandLineContains)
        if ($alive) { $oks.Add('process') }
        else { $failures.Add('process') }
    }

    # Concrete checks: any tcp port, http block, or process probe.
    # No concrete checks configured → treat as healthy (misconfig should not restart-storm).
    $hasHttp = $false
    if ($null -ne $Plan.http) {
        if ($Plan.http -is [hashtable] -or $Plan.http -is [System.Collections.Specialized.OrderedDictionary]) {
            $hasHttp = [bool]$Plan.http['url']
        }
        elseif ($Plan.http.PSObject.Properties.Name -contains 'url') {
            $hasHttp = [bool]$Plan.http.url
        }
    }
    $networkConfigured = ((@($Plan.tcpPorts).Count -gt 0) -or $hasHttp) -and [bool]$Plan.healthEnabled
    $hasConcrete = ($networkConfigured -or [bool]$Plan.processEnabled)

    # When TCP/HTTP is configured, network probes are authoritative.
    # Process probe is advisory only (WMI CommandLine is often empty for python.exe).
    $netFailCount = 0
    $procFailed = $false
    foreach ($f in @($failures.ToArray())) {
        if ($f -like 'tcp:*' -or $f -like 'http:*') { $netFailCount++ }
        elseif ($f -eq 'process') { $procFailed = $true }
    }
    $procHardFail = ((-not $networkConfigured) -and $procFailed)

    if (-not $hasConcrete) {
        $healthy = $true
    }
    elseif ($networkConfigured) {
        $healthy = ($netFailCount -eq 0)
    }
    else {
        $healthy = (-not $procHardFail)
    }

    $soft = New-Object System.Collections.Generic.List[string]
    if ($networkConfigured -and $procFailed) {
        $soft.Add('process')
    }

    return [ordered]@{
        healthy      = $healthy
        failures     = @($failures.ToArray())
        oks          = @($oks.ToArray())
        softFailures = @($soft.ToArray())
    }
}

function Invoke-HealthTick {
    <#
      One health pass over packages under PackagesRoot (skip _manager).
      Respects per-entry intervalSec via lastHealthCheckAt in state.
      Returns list of actions taken.
    #>
    param(
        [string]$ManagerRoot,
        [string]$CliPath,
        [string]$PackagesRoot,
        [switch]$DryRun,
        [switch]$ForceInterval,
        $Cfg
    )

    if (-not $Cfg) { $Cfg = Read-ManagerConfig -ManagerRoot $ManagerRoot }
    if (-not $PackagesRoot) {
        $PackagesRoot = Join-Path $(if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { (Get-Location).Path }) '.win-autostart'
    }

    $actions = New-Object System.Collections.Generic.List[object]
    if (Test-ManagerPaused -ManagerRoot $ManagerRoot) {
        $actions.Add([ordered]@{ name = '*'; action = 'skip'; detail = 'paused' })
        return @($actions.ToArray())
    }
    if (-not (Test-Path -Path $PackagesRoot -PathType Container)) {
        return @($actions.ToArray())
    }

    $dirs = Get-ChildItem -Path $PackagesRoot -Directory -ErrorAction SilentlyContinue
    foreach ($d in @($dirs)) {
        $name = $d.Name
        if ($name -eq '_manager') { continue }

        if (-not (Test-EntryDesiredEnabled -ManagerRoot $ManagerRoot -Name $name)) {
            $actions.Add([ordered]@{ name = $name; action = 'skip'; detail = 'desiredEnabled=false' })
            continue
        }

        $manifest = Read-EntryManifestForManager -PackagesRoot $PackagesRoot -Name $name
        $plan = Get-KeepaliveProbePlan -Manifest $manifest -Cfg $Cfg
        if ($null -eq $plan) { continue }

        $slice = Get-ManagerEntryState -ManagerRoot $ManagerRoot -Name $name
        if ($null -eq $slice) { $slice = @{} }

        if (-not $ForceInterval) {
            $lastCheck = $null
            if ($slice.ContainsKey('lastHealthCheckAt') -and $slice['lastHealthCheckAt']) {
                try { $lastCheck = [datetime]::Parse([string]$slice['lastHealthCheckAt'], $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { }
            }
            if ($lastCheck) {
                $elapsed = ((Get-Date) - $lastCheck).TotalSeconds
                if ($elapsed -lt [int]$plan.intervalSec) {
                    $actions.Add([ordered]@{ name = $name; action = 'defer'; detail = ("interval {0}s" -f $plan.intervalSec) })
                    continue
                }
            }
        }

        $check = Invoke-EntryHealthCheck -Plan $plan
        $nowIso = (Get-Date).ToString('o')
        $failures = 0
        if ($slice.ContainsKey('consecutiveHealthFailures') -and $null -ne $slice['consecutiveHealthFailures']) {
            $failures = [int]$slice['consecutiveHealthFailures']
        }

        if ($check.healthy) {
            Reset-EntryBackoffOnHealthOk -ManagerRoot $ManagerRoot -Name $name
            $detailParts = @($check.oks)
            if ($check.softFailures -and @($check.softFailures).Count -gt 0) {
                $detailParts += @($check.softFailures | ForEach-Object { "soft:$_" })
            }
            $okDetail = ($detailParts -join ',')
            Update-ManagerEntryState -ManagerRoot $ManagerRoot -Name $name -Fields @{
                lastHealthCheckAt         = $nowIso
                consecutiveHealthFailures = 0
                lastHealthDetail          = $okDetail
            }
            $actions.Add([ordered]@{ name = $name; action = 'ok'; detail = $okDetail })
            continue
        }

        $failures = $failures + 1
        Update-ManagerEntryState -ManagerRoot $ManagerRoot -Name $name -Fields @{
            lastHealthCheckAt         = $nowIso
            consecutiveHealthFailures = $failures
            lastHealthDetail          = ($check.failures -join ',')
        }
        Write-ManagerLog -ManagerRoot $ManagerRoot -Level 'WARN' -Message ("Health fail '{0}' count={1}/{2} detail={3}" -f $name, $failures, $plan.failureThreshold, ($check.failures -join ','))

        if ($failures -ge [int]$plan.failureThreshold) {
            $rr = Restart-Entry -ManagerRoot $ManagerRoot -CliPath $CliPath -PackagesRoot $PackagesRoot -Name $name -Reason 'health' -DryRun:$DryRun -Cfg $Cfg
            $actions.Add([ordered]@{ name = $name; action = 'restart'; detail = $rr; failures = $failures })
        }
        else {
            $actions.Add([ordered]@{ name = $name; action = 'fail'; detail = ($check.failures -join ','); failures = $failures })
        }
    }

    return @($actions.ToArray())
}
