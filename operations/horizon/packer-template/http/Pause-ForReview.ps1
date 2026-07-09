<#
.SYNOPSIS
    Pause-ForReview.ps1
    Pauses the Packer build after an OSOT step so logs can be reviewed.
    Packer polls this script every 30s via restart_check_command.
    Each call is a short independent WinRM connection - no 401 from audit.exe.

    Exit 0 = ready to continue
    Exit 1 = still paused (Packer keeps polling)

.PARAMETER PauseName
    Name of the pause point (e.g. POST-OPTIMIZE, POST-GENERALIZE, POST-FINALIZE)
#>

param(
    [Parameter(Mandatory)][string]$PauseName
)

$readyFile   = "C:\Temp\PAUSE_${PauseName}_READY.txt"
$waitingFile = "C:\Temp\PAUSE_${PauseName}_WAITING.txt"
$logFile     = "C:\Temp\OSOT-logs\Pause-${PauseName}.log"

New-Item -ItemType Directory -Path "C:\Temp\OSOT-logs" -Force | Out-Null

function Write-Log {
    param([string]$Msg)
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $Msg"
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
}

# Write waiting instructions on first check
if (-not (Test-Path $waitingFile)) {
    $osotLogs = Get-ChildItem "C:\Temp\OSOT-logs" -ErrorAction SilentlyContinue |
        Select-Object Name, LastWriteTime | Format-Table -AutoSize | Out-String

    $instructions = @"
========================================
PACKER BUILD PAUSED - $PauseName
========================================
Time paused: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

OSOT logs are in: C:\Temp\OSOT-logs\

$osotLogs

Review the logs, then signal Packer to continue:

  From your Packer host (replace IP):
  Invoke-Command -ComputerName <VM-IP> -Credential `$cred ``
    -Authentication Basic ``
    -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck) ``
    -ScriptBlock { New-Item -ItemType File -Path '$readyFile' -Force }

  Or on the VM console:
  New-Item -ItemType File -Path '$readyFile' -Force
========================================
"@
    Set-Content -Path $waitingFile -Value $instructions -Force
    Write-Log "Paused at $PauseName - waiting for review"
    Write-Output $instructions
}

# Check if ready to continue
if (Test-Path $readyFile) {
    Write-Log "Ready file found - continuing build."
    Remove-Item $readyFile -Force -ErrorAction SilentlyContinue
    Remove-Item $waitingFile -Force -ErrorAction SilentlyContinue
    Write-Output "READY - continuing build."
    exit 0
} else {
    Write-Log "Still paused."
    exit 1
}
