<#
.SYNOPSIS
    setup.ps1
    Configures WinRM for Packer connectivity.
    Called from autounattend.xml FirstLogonCommands and RunOnce after sysprep.

    IMPORTANT: Does NOT re-register itself in RunOnce.
    The RunOnce key is set once in autounattend.xml FirstLogonCommands
    and fires once after the sysprep /audit reboot.
    After that it is consumed and not re-added, preventing WinRM
    from restarting mid-build and dropping the Packer connection.
#>

$ErrorActionPreference = "Continue"

# Set network to Private
try {
    Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
} catch {}

# Disable firewall during build
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False

# Configure WinRM
winrm quickconfig -quiet -force
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/client '@{AllowUnencrypted="true"}'
winrm set winrm/config/client/auth '@{Basic="true"}'
winrm set winrm/config/client '@{TrustedHosts="*"}'
winrm set winrm/config '@{MaxTimeoutms="1800000"}'

Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM

# Allow remote admin
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v LocalAccountTokenFilterPolicy /t REG_DWORD /d 1 /f | Out-Null
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v FilterAdministratorToken /t REG_DWORD /d 0 /f | Out-Null

# Ensure Administrator is active with correct password
net user Administrator SommerFerie2020! /active:yes | Out-Null

# Disable power saving
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change monitor-timeout-ac 0

Write-Output "WinRM setup complete"
