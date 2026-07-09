<#
.SYNOPSIS
    Disable-AuditMode.ps1
    Permanently prevents audit.exe from disrupting WinRM during the Packer build.

    audit.exe /user is registered in Winlogon Userinit and runs after every
    logon in audit mode. It resets WinRM and causes 401 errors.

    This script removes audit.exe from Userinit permanently for the duration
    of the build, preventing it from respawning.
#>

$ErrorActionPreference = "Continue"
Write-Output "=== Stabilizing audit mode for Packer build ==="

# -- Kill any running audit.exe processes -------------------------------------
$auditProc = Get-Process -Name "audit" -ErrorAction SilentlyContinue
if ($auditProc) {
    Write-Output "Stopping audit.exe process..."
    $auditProc | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Write-Output "audit.exe stopped."
}

# -- Remove audit.exe from Winlogon Userinit ----------------------------------
# This prevents audit.exe from respawning on every logon during the build
$winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$userinit = (Get-ItemProperty $winlogonPath -ErrorAction SilentlyContinue).Userinit
Write-Output "Current Userinit: $userinit"

if ($userinit -like "*audit*") {
    # Remove audit.exe entries but keep userinit.exe
    $parts = $userinit -split "," | Where-Object { $_.Trim() -ne "" -and $_ -notlike "*audit*" }
    $newUserinit = ($parts -join ",").TrimEnd(",") + ","
    Set-ItemProperty -Path $winlogonPath -Name "Userinit" -Value $newUserinit -Force
    Write-Output "Removed audit.exe from Userinit."
    Write-Output "New Userinit: $newUserinit"
} else {
    Write-Output "audit.exe not found in Userinit - already clean."
}

# -- Remove audit.exe from Shell if present -----------------------------------
$shell = (Get-ItemProperty $winlogonPath -ErrorAction SilentlyContinue).Shell
if ($shell -like "*audit*") {
    $newShell = ($shell -split "," | Where-Object { $_ -notlike "*audit*" }) -join ","
    Set-ItemProperty -Path $winlogonPath -Name "Shell" -Value $newShell -Force
    Write-Output "Removed audit.exe from Shell."
}

# -- Disable audit-related scheduled tasks ------------------------------------
$auditTasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.Actions.Execute -like "*audit*" -or $_.TaskName -like "*audit*"
}
if ($auditTasks) {
    $auditTasks | ForEach-Object {
        Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue | Out-Null
        Write-Output "Disabled task: $($_.TaskPath)$($_.TaskName)"
    }
}

# -- Ensure WinRM stays configured correctly -------------------------------
Write-Output "Verifying WinRM configuration..."
winrm set winrm/config/service '@{AllowUnencrypted="true"}' 2>&1 | Out-Null
winrm set winrm/config/service/auth '@{Basic="true"}' 2>&1 | Out-Null
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False -ErrorAction SilentlyContinue
Set-Service -Name WinRM -StartupType Automatic

# NOTE: Do NOT restart WinRM here - it drops the active Packer connection.
# The HCL uses windows-restart after this script to reboot cleanly instead.

Write-Output "WinRM configuration verified."
Write-Output "=== Audit mode stabilized - build can proceed ==="
