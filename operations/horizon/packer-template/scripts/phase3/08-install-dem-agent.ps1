<#
.SYNOPSIS
    08-install-dem-agent.ps1
    Installs Omnissa Dynamic Environment Manager (DEM) Agent 2603 silently.

.NOTES
    Based on official Omnissa documentation:
    "Omnissa Dynamic Environment Manager Installation and Configuration Guide"
    Release Version: Omnissa Dynamic Environment Manager - 2603, July 9, 2026
    Section: "Unattended Installation of Omnissa Dynamic Environment Manager"

    Per official docs - typical unattended installation command:
      msiexec.exe /i "Omnissa Dynamic Environment Manager Enterprise 2603 10.19 x64.msi"
        /qn
        /l* InstallDEM.log

    Default ADDLOCAL (per docs) installs:
      FlexEngine              - Core DEM engine
      FlexMigrate             - Application Migration + FlexEngine
      FlexProfilesSelfSupport - DEM Self-Support tool + FlexEngine

    Available ADDLOCAL values (per docs):
      ALL                     - Install everything
      FlexEngine              - Installs FlexEngine only
      FlexMigrate             - Installs Application Migration and FlexEngine
      FlexProfilesSelfSupport - Installs Self-Support tool and FlexEngine
      FlexManagementConsole   - Installs DEM Management Console

    Note: Property values are case-sensitive per official docs.
    Note: Log flag is /l* (not /l*v) per official DEM docs syntax.

    Reference:
    https://docs.omnissa.com/bundle/DEMInstallConfigGuide/page/
    UnattendedInstallationofOmnissaDynamicEnvironmentManager.html
#>

$ErrorActionPreference = "Stop"

$DemMsi  = "Omnissa Dynamic Environment Manager Enterprise 2603 10.19 x64.msi"
$DemDir  = "C:\Temp"
$DemLog  = "C:\Temp\dem-agent-install.log"

Write-Output "======================================================"
Write-Output "Installing Omnissa DEM Agent 2603"
Write-Output "======================================================"
Write-Output "Installer : $DemDir\$DemMsi"
Write-Output "Log file  : $DemLog"
Write-Output ""
Write-Output "Reference: Omnissa DEM Installation and Configuration Guide - 2603"
Write-Output "           Section: Unattended Installation of DEM"
Write-Output "           ADDLOCAL: FlexEngine, FlexProfilesSelfSupport (FlexMigrate excluded)"
Write-Output "======================================================"

# Verify installer exists
if (-not (Test-Path "$DemDir\$DemMsi")) {
    Write-Error "DEM installer not found at $DemDir\$DemMsi"
    exit 1
}

# Unblock installer
Unblock-File "$DemDir\$DemMsi" -Confirm:$false -ErrorAction SilentlyContinue

# Per official docs - typical unattended installation
# Explicit ADDLOCAL - FlexMigrate excluded (no application migration needed)
# Log flag: /l* per official DEM docs (not /l*v)
$msiArgs = "/i `"$DemDir\$DemMsi`" /qn /norestart ADDLOCAL=FlexEngine,FlexProfilesSelfSupport /l* `"$DemLog`""

Write-Output "Running: msiexec.exe $msiArgs"
Write-Output ""

try {
    $proc = Start-Process -FilePath "msiexec.exe" `
        -ArgumentList $msiArgs `
        -Wait -PassThru -NoNewWindow

    $exitCode = $proc.ExitCode
    Write-Output "Exit code: $exitCode"

} catch {
    Write-Error "Failed to launch DEM installer: $_"
    exit 1
}

# Show install log
if (Test-Path $DemLog) {
    Write-Output ""
    Write-Output "--- DEM Agent install log (last 30 lines) ---"
    Get-Content $DemLog | Select-Object -Last 30
}

# Acceptable exit codes:
# 0    = success
# 3010 = success, reboot required
if ($exitCode -notin @(0, 3010)) {
    Write-Error "DEM Agent installation failed with exit code $exitCode"
    exit $exitCode
}

if ($exitCode -eq 3010) {
    Write-Output "Exit 3010: Install succeeded - reboot required (Packer handles this)."
}

# Verify installation
$installed = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like "*Dynamic Environment Manager*" }
if ($installed) {
    Write-Output "DEM Agent installed: $($installed.DisplayName) $($installed.DisplayVersion)"
} else {
    Write-Warning "DEM Agent not found in registry - may appear after reboot."
}

Write-Output ""
Write-Output "======================================================"
Write-Output "DEM Agent 2603 installation complete."
Write-Output "======================================================"
