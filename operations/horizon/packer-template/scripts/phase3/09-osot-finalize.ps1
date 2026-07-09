<#
.SYNOPSIS
    09-osot-finalize.ps1
    Runs OSOT Finalize with correct 2603 CLI syntax.
    Version 1.2.2603.23605577104

    CLI syntax (from OSOT -h):
      -Finalize [all|0|1|2|3|4|5|6|7|8|9|10|11]
      -v                                Verbose mode
      -r $report_file_path              Save analysis report

    Finalize options (from OSOT -h):
      all = run all finalize steps
      0-11 = individual step numbers
      Step 7 = Compact/sdelete (very slow, excluded by default)
#>

$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Path "C:\Temp\OSOT-logs" -Force | Out-Null

$osotExe     = "C:\Temp\OmnissaHorizonOSOptimizationTool-x86_64-1.2.2603.23605577104.exe"
$osotLog     = "C:\Temp\OSOT-logs\OSOT-Finalize.log"
$osotReport  = "C:\Temp\OSOT-logs\OSOT-Finalize-report.txt"
$osotErrLog  = "C:\Temp\OSOT-logs\OSOT-Finalize-err.log"
$timeoutSecs = 1200  # 20 minutes

# Steps used:
# 0=.NET optimize, 1=WinSxS, 2=CompactOS, 3=Temp files, 4=Event logs
# 5=Superfetch, 9=KMS, 10=DNS flush, 11=Release IP
# Excluded: 6=Clean Default User Profile (keep for VDI), 8=LGPO (no tool)
$finalizeSteps = "0 1 2 3 4 5 7 9 10 11"

Write-Output "=== OSOT: Finalize Phase (v1.2.2603) ==="
Write-Output "Finalize steps : $finalizeSteps (step 7=sdelete requires sdelete64.exe in System32)"
Write-Output "Log file       : $osotLog"
Write-Output "Report file    : $osotReport"

if (-not (Test-Path $osotExe)) {
    Write-Error "OSOT executable not found at $osotExe"
    exit 1
}

# 2603 syntax: -Finalize <steps> -v -r <report>
$osotArgs = "-Finalize $finalizeSteps -v -r `"$osotReport`""
Write-Output "Running: $osotExe $osotArgs"

$proc = Start-Process -FilePath $osotExe `
    -ArgumentList $osotArgs `
    -PassThru -NoNewWindow `
    -RedirectStandardOutput $osotLog `
    -RedirectStandardError $osotErrLog

Write-Output "OSOT Finalize started with PID: $($proc.Id)"

$elapsed = 0
$interval = 10
while (-not $proc.HasExited -and $elapsed -lt $timeoutSecs) {
    Start-Sleep -Seconds $interval
    $elapsed += $interval
    if ($elapsed % 60 -eq 0) {
        Write-Output "  OSOT still running... ($elapsed seconds elapsed)"
    }
}

if (-not $proc.HasExited) {
    Write-Warning "OSOT Finalize timed out after $timeoutSecs seconds. Killing process."
    $proc.Kill()
    Get-Content $osotLog -Tail 20 -ErrorAction SilentlyContinue
    exit 0
}

Write-Output "OSOT Finalize exit code: $($proc.ExitCode)"
Write-Output ""
Write-Output "--- OSOT Finalize output ---"
Get-Content $osotLog -ErrorAction SilentlyContinue

if (Test-Path $osotErrLog) {
    $errContent = Get-Content $osotErrLog -ErrorAction SilentlyContinue
    if ($errContent) {
        Write-Output "--- OSOT stderr ---"
        $errContent
    }
}

Write-Output ""
Write-Output "Logs saved to: C:\Temp\OSOT-logs\"
Write-Output "=== OSOT Finalize complete ==="
