#Requires -Version 5.1
<#
.SYNOPSIS
  Register win-autostart-manager as a logon scheduled-task via the registration CLI.

.DESCRIPTION
  Follows ADR-0003: does NOT silently fall back to Startup if scheduled-task fails.
  Prints the exact retry instruction with -Landing startup for the user to confirm.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\register-manager.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File .\register-manager.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$CliPath,
    [string]$ManagerPath,
    [string]$Name = 'win-autostart-manager',
    [switch]$Force,
    [switch]$NoRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ManagerPath) {
    $ManagerPath = Join-Path $here 'win-autostart-manager.ps1'
}
if (-not $CliPath) {
    $CliPath = Join-Path $here 'windows-autostart.ps1'
}

if (-not (Test-Path -Path $ManagerPath -PathType Leaf)) {
    throw "Manager script not found: $ManagerPath"
}
if (-not (Test-Path -Path $CliPath -PathType Leaf)) {
    throw "CLI script not found: $CliPath"
}

$managerFull = (Resolve-Path -Path $ManagerPath).Path
$cliFull = (Resolve-Path -Path $CliPath).Path
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Business command: host the manager serve loop
$command = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" serve' -f $psExe, $managerFull

# Call operator keeps -Command as one argv; Start-Process ArgumentList splits on spaces.
$argList = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', $cliFull,
    'add',
    '-Name', $Name,
    '-Mode', 'logon',
    '-Command', $command,
    '-Landing', 'scheduled-task'
)
if ($Force) { $argList += '-Force' }
if ($NoRun) { $argList += '-NoRun' }

Write-Host "Registering manager via CLI:"
Write-Host ("  exe={0}" -f $psExe)
Write-Host ("  name={0} landing=scheduled-task norun={1}" -f $Name, ([bool]$NoRun))

$outPath = Join-Path $env:TEMP 'win-autostart-register-manager.out.json'
$errPath = Join-Path $env:TEMP 'win-autostart-register-manager.err.txt'
Remove-Item -LiteralPath $outPath, $errPath -Force -ErrorAction SilentlyContinue

$stdout = & $psExe @argList 2> $errPath
if ($null -eq $stdout) { $stdout = '' }
elseif ($stdout -is [System.Array]) { $stdout = ($stdout | ForEach-Object { "$_" }) -join "`n" }
else { $stdout = [string]$stdout }
Set-Content -LiteralPath $outPath -Value $stdout -Encoding UTF8

$stderr = if (Test-Path -LiteralPath $errPath) { Get-Content -LiteralPath $errPath -Raw -ErrorAction SilentlyContinue } else { '' }

if ($stdout) { Write-Host $stdout }

$ok = $false
$envelope = $null
try {
    if ($stdout) { $envelope = $stdout | ConvertFrom-Json }
    if ($envelope -and $envelope.result -eq 'ok') { $ok = $true }
    if ($envelope -and $envelope.result -eq 'partial') { $ok = $true }
}
catch { }

if (-not $ok) {
    Write-Host ''
    Write-Host 'ERROR: scheduled-task registration failed (ADR-0003: no silent Startup fallback).' -ForegroundColor Red
    if ($envelope -and $envelope.error) {
        Write-Host ("CLI error: {0}" -f $envelope.error)
    }
    elseif ($stderr) {
        Write-Host $stderr
    }
    Write-Host ''
    Write-Host 'If you accept Startup landing (no task-level RestartCount), re-run manually:'
    Write-Host ''
    $startupCmd = @(
        "powershell -NoProfile -ExecutionPolicy Bypass -File `"$cliFull`" add -Name $Name -Mode logon -Landing startup -Command '$command'"
    ) -join ''
    if ($Force) { $startupCmd += ' -Force' }
    Write-Host $startupCmd
    Write-Host ''
    exit 1
}

Write-Host "Registered '$Name' as scheduled-task. Manager serve command:"
Write-Host "  $command"
exit 0
