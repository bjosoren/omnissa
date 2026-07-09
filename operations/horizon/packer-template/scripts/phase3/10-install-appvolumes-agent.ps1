<#
.SYNOPSIS
    10-install-appvolumes-agent.ps1
    Installs Omnissa App Volumes Agent 2603 silently.
    Must be run LAST - after all other agents and OSOT Finalize.

.NOTES
    Based on official Omnissa documentation:
    "Omnissa App Volumes Install Guide"
    Release Version: Omnissa App Volumes - 2603, July 9, 2026
    Section: "Install App Volumes Agent Silently"

    Deployment mode: Managed (connects with App Volumes Manager)
    Package access mode: Shared Storage (default)

    Per official docs - Managed mode Shared Storage command:
      msiexec.exe /i "App Volumes Agent.msi" /qn
        MANAGER_ADDR=<FQDN or IP>
        MANAGER_PORT=<port>
        EnforceSSLCertificateValidation=<0 or 1>
        NONPERSISTENT=<0 or 1>
        EnablePIILogging=<0 or 1>
        LogLevel=<0 or 1>

    Parameters used (per official docs):
      MANAGER_ADDR                  App Volumes Manager FQDN or IP (mandatory)
      MANAGER_PORT                  Port for AVM communication (mandatory, default 443)
      NONPERSISTENT=1               Non-persistent VDI environment (available from 2406+)
      EnforceSSLCertificateValidation=0  SSL cert validation - disabled for lab
      EnablePIILogging=0            Do not log PII data
      LogLevel=1                    Verbose logging
      /l*v logfile                  MSI verbose log
      /norestart                    Suppress automatic reboot

    Reference:
    https://docs.omnissa.com/bundle/AppVolumesInstallGuide/page/
    InstallAppVolumesAgentSilently.html

    NOTE: Per official docs - PACKAGEMODELOCAL and NONPERSISTENT are mutually exclusive.
    NOTE: Do not install on the same machine as App Volumes Manager.
    NOTE: Must be installed LAST - after Horizon Agent, DEM Agent and OSOT Finalize.
#>

$ErrorActionPreference = "Stop"

$AppVolDir  = "C:\Temp"
$AppVolMsi  = "App Volumes Agent.msi"
$AppVolLog  = "C:\Temp\appvolumes-agent-install.log"

# App Volumes Manager connection details
$ManagerAddr = "appvol.example.com"
$ManagerPort = "443"

Write-Output "======================================================"
Write-Output "Installing Omnissa App Volumes Agent 2603"
Write-Output "======================================================"
Write-Output "Installer    : $AppVolDir\$AppVolMsi"
Write-Output "Manager FQDN : $ManagerAddr"
Write-Output "Manager port : $ManagerPort"
Write-Output "Mode         : Managed / Shared Storage / Non-persistent"
Write-Output "Log file     : $AppVolLog"
Write-Output ""
Write-Output "Reference: Omnissa App Volumes Install Guide - 2603"
Write-Output "           Section: Install App Volumes Agent Silently"
Write-Output "           Deploy in Managed mode / Shared Storage"
Write-Output "======================================================"

# Verify installer exists
if (-not (Test-Path "$AppVolDir\$AppVolMsi")) {
    Write-Error "Installer not found at $AppVolDir\$AppVolMsi"
    exit 1
}

# Unblock installer
Unblock-File "$AppVolDir\$AppVolMsi" -Confirm:$false -ErrorAction SilentlyContinue

# Per official docs - Managed mode Shared Storage MSI command
# Note: using msiexec directly as the file is an MSI (not EXE bootstrapper)
$msiArgs = "/i `"$AppVolDir\$AppVolMsi`" /qn " +
    "MANAGER_ADDR=$ManagerAddr " +
    "MANAGER_PORT=$ManagerPort " +
    "NONPERSISTENT=1 " +
    "EnforceSSLCertificateValidation=0 " +
    "EnablePIILogging=0 " +
    "LogLevel=1 " +
    "/norestart " +
    "/l*v `"$AppVolLog`""

Write-Output "Running: msiexec.exe $msiArgs"
Write-Output ""

try {
    $proc = Start-Process -FilePath "msiexec.exe" `
        -ArgumentList $msiArgs `
        -Wait -PassThru -NoNewWindow

    $exitCode = $proc.ExitCode
    Write-Output "Exit code: $exitCode"

} catch {
    Write-Error "Failed to launch App Volumes Agent installer: $_"
    exit 1
}

# Show install log
if (Test-Path $AppVolLog) {
    Write-Output ""
    Write-Output "--- App Volumes Agent install log (last 30 lines) ---"
    Get-Content $AppVolLog | Select-Object -Last 30
}

# Acceptable exit codes:
# 0    = success
# 3010 = success, reboot required
if ($exitCode -notin @(0, 3010)) {
    Write-Error "App Volumes Agent installation failed with exit code $exitCode"
    exit $exitCode
}

if ($exitCode -eq 3010) {
    Write-Output "Exit 3010: Install succeeded - reboot required (Packer handles this)."
}

# Verify service
$svc = Get-Service "svservice" -ErrorAction SilentlyContinue
if ($svc) {
    Write-Output "App Volumes Agent service (svservice): $($svc.Status)"
} else {
    Write-Warning "svservice not found - may appear after reboot."
}

Write-Output ""
Write-Output "======================================================"
Write-Output "App Volumes Agent 2603 installation complete."
Write-Output "======================================================"
