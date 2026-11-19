<#
.SYNOPSIS
  Search Omnissa Horizon Connection Server debug logs for vGPU / provisioning failures.

.DESCRIPTION
  Mode 1 (default): pattern search across Connection Server debug logs in a UTC
  time window. Results are printed and exported to CSV with context lines.

  Mode 2 (-TraceError): find the first "No GPU capable host" error and print the
  preceding lines from the same thread, which is usually where the placement
  decision is logged (e.g. "[CPHost] VGPU_PROFILE is null or unknown").

  Without -ConnectionServers the script runs locally on the current server.
  With -ConnectionServers it runs remotely through Invoke-Command (WinRM).

.PARAMETER ConnectionServers
  Connection Servers to query remotely. Omit to run on the local server.

.PARAMETER From
  Start of the time window, UTC, ISO format (e.g. 2026-11-19T11:15). Default: 1 hour ago.

.PARAMETER To
  End of the time window, UTC, ISO format. Default: now.

.PARAMETER Pattern
  Regex to search for in mode 1.

.PARAMETER HoursBack
  Only scan log files written in the last N hours. Default: 6.

.PARAMETER TraceError
  Switch to mode 2.

.PARAMETER TraceLines
  Number of lines to look back from the error in mode 2. Default: 500.

.PARAMETER Local
  Force local execution even if -ConnectionServers is given.

.PARAMETER OutFile
  CSV output for mode 1. Default: .\horizon-gpu-debug.csv

.EXAMPLE
  .\Get-HorizonGpuDebug.ps1 -TraceError -Local

.EXAMPLE
  .\Get-HorizonGpuDebug.ps1 -TraceError -ConnectionServers cs01.domain.local, cs02.domain.local

.EXAMPLE
  .\Get-HorizonGpuDebug.ps1 -From '2026-11-19T11:15' -To '2026-11-19T11:25'

.NOTES
  Author : bjosoren - https://tech.iot-it.no
  License: MIT
#>
[CmdletBinding()]
param(
    [string[]]$ConnectionServers,

    # UTC, compared against the ISO timestamp at the start of each log line
    [string]$From = (Get-Date).ToUniversalTime().AddHours(-1).ToString('yyyy-MM-ddTHH:mm'),
    [string]$To   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm'),

    [string]$Pattern = 'nvidia_|vgpu|GPU capable|VGPU_PROFILE|UNKNOWN_FAULT|Resync|cp-template|cp-replica|cp-parent|InsufficientResources|NoCompatibleHost|PlacementSpec|HostSelect|graphics',

    [int]$HoursBack = 6,
    [switch]$TraceError,
    [int]$TraceLines = 500,
    [switch]$Local,
    [string]$OutFile = '.\horizon-gpu-debug.csv'
)

$scan = {
    param($From, $To, $Pattern, $HoursBack, $TraceError, $TraceLines)

    $dirs = 'C:\ProgramData\Omnissa\Horizon\logs', 'C:\ProgramData\VMware\VDM\logs' |
            Where-Object { Test-Path $_ }
    if (-not $dirs) { Write-Warning "$env:COMPUTERNAME : no Horizon log folder found"; return }

    $files = Get-ChildItem -Path $dirs -Filter 'debug*' -File |
             Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-$HoursBack) } |
             Sort-Object LastWriteTime
    if (-not $files) { Write-Warning "$env:COMPUTERNAME : no debug logs written in the last $HoursBack h"; return }

    if ($TraceError) {
        $hit = $files | Select-String -Pattern 'No GPU capable host' | Select-Object -First 1
        if (-not $hit) { Write-Warning "$env:COMPUTERNAME : no 'No GPU capable host' in the last $HoursBack h"; return }

        $tid   = [regex]::Match($hit.Line, '\(([0-9A-F]{4}-[0-9A-F]{4})\)').Groups[1].Value
        $lines = Get-Content -LiteralPath $hit.Path
        $start = [Math]::Max(0, $hit.LineNumber - $TraceLines)

        "=== $env:COMPUTERNAME  $([IO.Path]::GetFileName($hit.Path))  line $($hit.LineNumber)  thread $tid ==="
        $lines[$start..($hit.LineNumber - 1)] | Where-Object { $_ -match [regex]::Escape($tid) }
        return
    }

    foreach ($f in $files) {
        Select-String -LiteralPath $f.FullName -Pattern $Pattern -Context 2, 2 | ForEach-Object {
            $ts = if ($_.Line.Length -ge 23) { $_.Line.Substring(0, 23) } else { '' }
            if ($ts -ge $From -and $ts -le "$To~") {
                [pscustomobject]@{
                    CS     = $env:COMPUTERNAME
                    Time   = $ts
                    File   = $f.Name
                    LineNo = $_.LineNumber
                    Text   = $_.Line
                    Before = $_.Context.PreContext -join "`n"
                    After  = $_.Context.PostContext -join "`n"
                }
            }
        }
    }
}

$argsList = $From, $To, $Pattern, $HoursBack, [bool]$TraceError, $TraceLines

$result = if ($Local -or -not $ConnectionServers) {
    & $scan @argsList
} else {
    Invoke-Command -ComputerName $ConnectionServers -ScriptBlock $scan -ArgumentList $argsList
}

if ($TraceError) {
    $result
    return
}

if (-not $result) {
    Write-Host "No hits between $From and $To (UTC)." -ForegroundColor Yellow
    return
}

$result = $result | Sort-Object Time
$result | Select-Object CS, Time, Text | Format-Table -Wrap -AutoSize
$result | Select-Object CS, Time, File, LineNo, Text, Before, After |
    Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
Write-Host "`n$(@($result).Count) hits -> $OutFile" -ForegroundColor Cyan
