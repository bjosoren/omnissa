<#
.SYNOPSIS
    11-final-cleanup.ps1
    Final cleanup before the VM is used as a golden image/template.
    Removes build artifacts, temp files, and prepares the image.
#>

$ErrorActionPreference = "Continue"
Write-Output "=== Final Cleanup ==="

# Remove Packer temp files from C:\Temp
Write-Output "Cleaning C:\Temp..."
Get-ChildItem "C:\Temp" -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
}

# Remove OSOT install directory
Write-Output "Cleaning C:\Temp install files..."
Remove-Item "C:\Temp\*.exe" -Force -ErrorAction SilentlyContinue
Remove-Item "C:\Temp\*.msi" -Force -ErrorAction SilentlyContinue
Remove-Item "C:\Temp\*.txt" -Force -ErrorAction SilentlyContinue
Remove-Item "C:\Temp\*.xml" -Force -ErrorAction SilentlyContinue
Remove-Item "C:\Temp\*.cmd" -Force -ErrorAction SilentlyContinue
Remove-Item "C:\Temp\*.json" -Force -ErrorAction SilentlyContinue

# Remove Windows Update cache
Write-Output "Cleaning Windows Update cache..."
Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
Remove-Item "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
Start-Service wuauserv -ErrorAction SilentlyContinue

# Clear Windows temp
Write-Output "Cleaning Windows temp..."
Remove-Item "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

# Clear event logs
Write-Output "Clearing event logs..."
Get-WinEvent -ListLog * -ErrorAction SilentlyContinue | ForEach-Object {
    [System.Diagnostics.Eventing.Reader.EventLogSession]::GlobalSession.ClearLog($_.LogName) 2>$null
}

# Remove setup scripts (no longer needed)
Write-Output "Removing setup scripts..."
Remove-Item "C:\Windows\Setup\Scripts\setup.ps1" -Force -ErrorAction SilentlyContinue

# Clear pagefile on next boot (optional, reduces image size)
$pagefilePath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"
Set-ItemProperty -Path $pagefilePath -Name "ClearPageFileAtShutdown" -Value 1 -ErrorAction SilentlyContinue

# Reset AutoLogon count to 0
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" `
    -Name "AutoLogonCount" -Value 0 -ErrorAction SilentlyContinue

Write-Output "=== Final Cleanup complete ==="
Write-Output "VM is ready to be used as a golden image."
