<#
.SYNOPSIS
    06-osot-generalize.ps1
    Runs OSOT Generalize with correct 2603 CLI syntax.
    Version 1.2.2603.23605577104

    CLI syntax (from OSOT -h):
      -Generalize [$answer_file_path]   Generalize Windows image
      -v                                Verbose mode
      -r $report_file_path              Save analysis report

    Requirements per docs:
      - Windows must be in audit mode (IMAGE_STATE_UNDEPLOYABLE)
      - Reboot required after completion (handled by sysprep)
#>

$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Path "C:\Temp\OSOT-logs" -Force | Out-Null

$osotExe    = "C:\Temp\OmnissaHorizonOSOptimizationTool-x86_64-1.2.2603.23605577104.exe"
$sysprepXml = "C:\Temp\w11sysprep.xml"
$osotLog    = "C:\Temp\OSOT-logs\OSOT-Generalize.log"
$osotReport = "C:\Temp\OSOT-logs\OSOT-Generalize-report.txt"
$osotErrLog = "C:\Temp\OSOT-logs\OSOT-Generalize-err.log"

Write-Output "=== OSOT: Generalize Phase (v1.2.2603) ==="

if (-not (Test-Path $osotExe)) {
    Write-Error "OSOT executable not found at $osotExe"
    exit 1
}

if (-not (Test-Path $sysprepXml)) {
    Write-Error "Sysprep XML not found at $sysprepXml"
    exit 1
}

# Verify image state
$imageState = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State" -ErrorAction SilentlyContinue).ImageState
Write-Output "Current image state: $imageState"

if ($imageState -ne "IMAGE_STATE_UNDEPLOYABLE") {
    Write-Warning "Expected IMAGE_STATE_UNDEPLOYABLE (audit mode) but got: $imageState"
    Write-Warning "OSOT Generalize requires audit mode. Check sysprep /audit ran correctly."
}

# Disable BitLocker
Write-Output "Checking BitLocker..."
try {
    Get-BitLockerVolume -ErrorAction SilentlyContinue |
        Where-Object { $_.ProtectionStatus -eq "On" } |
        ForEach-Object {
            Disable-BitLocker -MountPoint $_.MountPoint -ErrorAction SilentlyContinue | Out-Null
            Write-Output "BitLocker disabled on $($_.MountPoint)"
        }
} catch {
    Write-Warning "BitLocker check skipped: $_"
}

# 2603 syntax: -Generalize <xml> -v -r <report>
$osotArgs = "-Generalize `"$sysprepXml`" -v -r `"$osotReport`""
Write-Output "Running: $osotExe $osotArgs"
Write-Output "Log file  : $osotLog"
Write-Output "Report    : $osotReport"
Write-Output "VM will shut down after sysprep. Packer reconnects after reboot."

$proc = Start-Process -FilePath $osotExe `
    -ArgumentList $osotArgs `
    -Wait -PassThru -NoNewWindow `
    -RedirectStandardOutput $osotLog `
    -RedirectStandardError $osotErrLog

Write-Output "OSOT Generalize exit code: $($proc.ExitCode)"

if (Test-Path $osotLog) {
    Write-Output "--- OSOT Generalize output ---"
    Get-Content $osotLog
}
if (Test-Path $osotErrLog) {
    $errContent = Get-Content $osotErrLog -ErrorAction SilentlyContinue
    if ($errContent) {
        Write-Output "--- OSOT Generalize stderr ---"
        $errContent
    }
}

Write-Output "=== OSOT Generalize triggered. System shutting down via sysprep... ==="
