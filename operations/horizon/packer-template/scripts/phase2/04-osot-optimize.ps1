<#
.SYNOPSIS
    04-osot-optimize.ps1
    Runs OSOT Optimize using ApplyOptimization JSON settings file.
    Tries scheduled task first (interactive context), falls back to
    cmd.exe-based invocation if the scheduled task fails.
    Version 1.2.2603.23605577104

    Per official Omnissa docs (OSOT -h):
      -o                              Execute optimization
      -ApplyOptimization <json>       Import saved optimization selections
      -v                              Verbose mode
      -o -v > logfile.txt 2>&1       Official logging syntax

    NOTE: -ApplyOptimization cannot be used with Common Options at the same time.
#>

$ErrorActionPreference = "Continue"

New-Item -ItemType Directory -Path "C:\Temp\OSOT-logs" -Force | Out-Null

$osotExe     = "C:\Temp\OmnissaHorizonOSOptimizationTool-x86_64-1.2.2603.23605577104.exe"
$osotJson    = "C:\Temp\Windows 10, 11 and Server 2019, 2022 2026-07-08-085321.json"
$osotLog     = "C:\Temp\OSOT-logs\OSOT-Optimize.log"
$osotReport  = "C:\Temp\OSOT-logs\OSOT-Optimize-report.txt"
$taskName    = "PackerOSOTOptimize"
$timeoutSecs = 1200  # 20 minutes

Write-Output "=== OSOT: Optimize Phase (v1.2.2603) ==="
Write-Output "OSOT executable     : $osotExe"
Write-Output "OSOT settings JSON  : $osotJson"
Write-Output "Log file            : $osotLog"
Write-Output "Timeout             : $timeoutSecs seconds"

if (-not (Test-Path $osotExe)) {
    Write-Error "OSOT executable not found at $osotExe"
    exit 1
}

if (-not (Test-Path $osotJson)) {
    Write-Warning "Settings JSON not found at $osotJson - falling back to default template"
    $useJson = $false
} else {
    Write-Output "Settings JSON found - using ApplyOptimization"
    $useJson = $true
}

# Build OSOT arguments
# Per official docs: -o -ApplyOptimization <json> -v > logfile 2>&1
if ($useJson) {
    $osotArgs = "-o -ApplyOptimization `"$osotJson`" -v -r `"$osotReport`""
} else {
    $osotTemplate = "Omnissa Templates\Windows 10, 11 and Server 2022, 2025"
    $osotArgs = "-o -t `"$osotTemplate`" -v -r `"$osotReport`""
}

# Write cmd wrapper - uses cmd redirect (official Omnissa syntax: -o -v > log 2>&1)
$cmdWrapper = "C:\Temp\Run-OSOTOptimize.cmd"
@"
@echo off
echo [%DATE% %TIME%] Starting OSOT Optimize >> "$osotLog"
"$osotExe" $osotArgs >> "$osotLog" 2>&1
echo [%DATE% %TIME%] OSOT Optimize exit code: %ERRORLEVEL% >> "$osotLog"
exit %ERRORLEVEL%
"@ | Set-Content $cmdWrapper -Force -Encoding ASCII

# -- Attempt 1: Scheduled task (interactive user context) ---------------------
Write-Output ""
Write-Output "Attempt 1: Running OSOT via scheduled task (interactive context)..."

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

$action    = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$cmdWrapper`""
$principal = New-ScheduledTaskPrincipal -UserId "Administrator" -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 25)

Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $taskName

$elapsed  = 0
$interval = 10
do {
    Start-Sleep -Seconds $interval
    $elapsed += $interval
    $state = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
    if ($elapsed % 60 -eq 0) {
        Write-Output "  Still running... ($elapsed s) State: $state"
    }
} while ($state -eq "Running" -and $elapsed -lt $timeoutSecs)

$taskResult = (Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue).LastTaskResult
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Write-Output "Scheduled task result: $taskResult"

# Check if OSOT log was produced and has content
$logProduced = (Test-Path $osotLog) -and ((Get-Item $osotLog).Length -gt 100)

if ($logProduced) {
    Write-Output "Attempt 1 succeeded - OSOT log produced."
} else {
    # -- Attempt 2: Direct cmd.exe invocation ---------------------------------
    Write-Output ""
    Write-Output "Attempt 2: Scheduled task produced no output. Trying cmd.exe directly..."

    $proc = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c `"$cmdWrapper`"" `
        -Wait -PassThru -NoNewWindow

    Write-Output "cmd.exe exit code: $($proc.ExitCode)"
    $logProduced = (Test-Path $osotLog) -and ((Get-Item $osotLog).Length -gt 100)

    if (-not $logProduced) {
        Write-Warning "Attempt 2 also produced no log output."
        Write-Warning "OSOT may require an interactive desktop session."
        Write-Warning "Please run OSOT manually from the vSphere console when Packer pauses."
    }
}

# -- Show log output -----------------------------------------------------------
if (Test-Path $osotLog) {
    Write-Output ""
    Write-Output "--- OSOT Optimize log ---"
    Get-Content $osotLog
}

# -- Cleanup -------------------------------------------------------------------
Remove-Item $cmdWrapper -Force -ErrorAction SilentlyContinue

Write-Output ""
Write-Output "Log saved to      : $osotLog"
Write-Output "Report saved to   : $osotReport"
Write-Output "=== OSOT Optimize phase complete - Packer will pause for review ==="
