<#
.SYNOPSIS
    07-install-horizon-agent.ps1
    Installs Omnissa Horizon Agent 2603 silently using a settings file.

.NOTES
    Based on official Omnissa documentation:
    "Desktops and Applications in Omnissa Horizon 8"
    Release Version: Omnissa Horizon 8 - 2603, July 9, 2026
    Section: "Install Horizon Agent Silently Using a Settings File"

    Per official docs syntax:
      agent-installer.exe /s /v"/qn SETTINGS_FILE=C:\path\settings.txt"

    Settings file rules (per official docs):
      - Each parameter on its own line
      - Comments use # at start of line
      - Passwords must NOT be in file - pass on command line
      - File can be on local or network drive

    Reference:
    https://docs.omnissa.com/bundle/Desktops-and-Applications-in-Horizon/
    page/InstallHorizonAgentWindowsSilently.html

    Must run AFTER OSOT Generalize (sysprep) per Omnissa TechZone guide.
#>

$ErrorActionPreference = "Stop"

$HzAgentDir      = "C:\Temp"
$HzAgentExe      = "Omnissa-Horizon-Agent-x86_64-2603-8.18.0-24273927036.exe"
$HzAgentSettings = "C:\Temp\horizon-agent-settings.txt"
$HzAgentLog      = "C:\Temp\horizon-agent-install.log"
$CmdFile         = "C:\Temp\install-horizon-agent.cmd"

Write-Output "======================================================"
Write-Output "Installing Omnissa Horizon Agent 2603"
Write-Output "======================================================"
Write-Output "Installer     : $HzAgentDir\$HzAgentExe"
Write-Output "Settings file : $HzAgentSettings"
Write-Output "Log file      : $HzAgentLog"
Write-Output ""
Write-Output "Reference: Desktops and Applications in Omnissa Horizon 8"
Write-Output "           Release Version: Omnissa Horizon 8 - 2603"
Write-Output "           Section: Install Horizon Agent Silently Using a Settings File"
Write-Output "======================================================"

# Verify installer exists
if (-not (Test-Path "$HzAgentDir\$HzAgentExe")) {
    Write-Error "Installer not found at $HzAgentDir\$HzAgentExe"
    exit 1
}

# Verify settings file exists
if (-not (Test-Path $HzAgentSettings)) {
    Write-Error "Settings file not found at $HzAgentSettings"
    exit 1
}

# Unblock installer
Unblock-File "$HzAgentDir\$HzAgentExe" -Confirm:$false -ErrorAction SilentlyContinue

# Show settings file content
Write-Output ""
Write-Output "--- Settings file content ---"
Get-Content $HzAgentSettings | Where-Object { $_ -notmatch "^#" -and $_.Trim() -ne "" }
Write-Output "---"
Write-Output ""

# Check image state - should be post-sysprep
$imageState = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State" -ErrorAction SilentlyContinue).ImageState
Write-Output "Image state: $imageState"
if ($imageState -eq "IMAGE_STATE_UNDEPLOYABLE") {
    Write-Warning "WARNING: Still in audit mode! Agent should install post-sysprep."
}

# Write batch file using cmd syntax
# Per official docs: agent-installer.exe /s /v"/qn SETTINGS_FILE=path /l*v logfile"
# Note: /l*v must be outside SETTINGS_FILE per MSI conventions
[System.IO.File]::WriteAllText($CmdFile,
    "@echo off`r`n" +
    "echo [%DATE% %TIME%] Starting Horizon Agent 2603 installation >> `"$HzAgentLog`"`r`n" +
    "echo Settings file: $HzAgentSettings >> `"$HzAgentLog`"`r`n" +
    "`"$HzAgentDir\$HzAgentExe`" /s /v`"/qn " +
        "SETTINGS_FILE=`"`"$HzAgentSettings`"`" " +
        "/l*v `"`"$HzAgentLog`"`"`"`r`n" +
    "echo [%DATE% %TIME%] Horizon Agent install exit code: %ERRORLEVEL% >> `"$HzAgentLog`"`r`n" +
    "exit %ERRORLEVEL%`r`n"
)

Write-Output "Command file: $CmdFile"
Write-Output "Running installer..."

$proc = Start-Process -FilePath "cmd.exe" `
    -ArgumentList "/c `"$CmdFile`"" `
    -Wait -PassThru -NoNewWindow

$exitCode = $proc.ExitCode
Write-Output "Exit code: $exitCode"

# Show install log
if (Test-Path $HzAgentLog) {
    Write-Output ""
    Write-Output "--- Horizon Agent install log (last 30 lines) ---"
    Get-Content $HzAgentLog | Select-Object -Last 30
}

# Check vminst log for detailed errors
$vminstLog = Get-ChildItem "C:\ProgramData\Omnissa\Horizon\logs" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($vminstLog) {
    Write-Output ""
    Write-Output "--- vminst log: $($vminstLog.Name) ---"
    Get-Content $vminstLog.FullName | Select-String "error|fail|1603|exit|CoCreate" -CaseSensitive:$false | Select-Object -Last 10
}

# Acceptable exit codes per official docs:
# 0    = success
# 3010 = success, reboot required
if ($exitCode -notin @(0, 3010)) {
    Write-Error "Horizon Agent installation failed with exit code $exitCode"
    exit $exitCode
}

if ($exitCode -eq 3010) {
    Write-Output "Exit 3010: Install succeeded - reboot required (Packer handles this)."
}

# Verify service
$svc = Get-Service "vmware-viewagent" -ErrorAction SilentlyContinue
if ($svc) {
    Write-Output "Horizon Agent service: $($svc.Status) ($($svc.StartType))"
} else {
    Write-Warning "vmware-viewagent service not found - may appear after reboot."
}

Write-Output ""
Write-Output "======================================================"
Write-Output "Horizon Agent 2603 installation complete."
Write-Output "======================================================"
