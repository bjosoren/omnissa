<#
.SYNOPSIS
    Invoke-OSOTStep.ps1
    Pauses the Packer build for a manual OSOT step on the VM console.
    Uses Yaakov's pause file technique - Packer polls until pause file is deleted.

    Flow:
    1. Print instructions for which OSOT cmd to run manually
    2. Create C:\Temp\PAUSE_OSOT-<STEP>.txt
    3. Poll every 10 seconds until the file is deleted
    4. Once deleted - resume build

    To resume from PAW console:
      Remove-Item "C:\Temp\PAUSE_OSOT-<STEP>.txt" -Force

    Reference: https://blog.yaakov.online/pausing-packers-powershell-process/

    Environment variable:
      STEP = OPTIMIZE | GENERALIZE | FINALIZE
#>

$ErrorActionPreference = "Continue"

$Step = $env:STEP
if (-not $Step) { Write-Error "STEP environment variable not set"; exit 1 }
$Step = $Step.ToUpper()

# Convert to title case for filenames: OPTIMIZE -> Optimize
$stepTitle = (Get-Culture).TextInfo.ToTitleCase($Step.ToLower())

$cmdFile   = "C:\Temp\Run-OSOT${stepTitle}.cmd"
$logFile   = "C:\Temp\OSOT-logs\OSOT-${stepTitle}.log"
$pauseFile = "C:\Temp\PAUSE_OSOT-${Step}.txt"

New-Item -ItemType Directory -Path "C:\Temp\OSOT-logs" -Force | Out-Null

Write-Output "======================================================"
Write-Output "MANUAL STEP REQUIRED: OSOT $Step"
Write-Output "======================================================"
Write-Output ""
Write-Output "Run the following on the VM console:"
Write-Output ""
Write-Output "  $cmdFile"
Write-Output ""

switch ($Step) {
    "OPTIMIZE" {
        Write-Output "  Or run OSOT directly:"
        Write-Output "  C:\Temp\osot.exe -o -ApplyOptimization ""C:\Temp\Windows 10, 11 and Server 2019, 2022 2026-07-08-085321.json"" -v"
        Write-Output ""
        Write-Output "  Log will be written to: $logFile"
    }
    "GENERALIZE" {
        Write-Output "  Or run OSOT directly:"
        Write-Output "  C:\Temp\osot.exe -g C:\Temp\w11sysprep.xml -shutdown -v"
        Write-Output ""
        Write-Output "  NOTE: VM will shut down after Generalize - this is expected."
        Write-Output "  Packer will reconnect automatically after reboot."
        Write-Output "  Log will be written to: $logFile"
    }
    "FINALIZE" {
        Write-Output "  Or run OSOT directly:"
        Write-Output "  C:\Temp\osot.exe -Finalize 0 1 2 3 4 5 6 7 9 10 -v"
        Write-Output ""
        Write-Output "  Log will be written to: $logFile"
    }
}

Write-Output ""
Write-Output "When OSOT $Step is complete, resume Packer by deleting the pause file:"
Write-Output ""
Write-Output "  On VM console:"
Write-Output "  Remove-Item -Path '$pauseFile' -Force"
Write-Output ""
Write-Output "======================================================"

# Create pause file - Packer polls until this is deleted
"Packer paused for manual OSOT $Step at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Set-Content $pauseFile -Force
Write-Output "Pause file created: $pauseFile"
Write-Output "Waiting for pause file to be deleted..."
Write-Output ""

$elapsed = 0
Do {
    Start-Sleep -Seconds 10
    $elapsed += 10
    if ($elapsed % 120 -eq 0) {
        Write-Output "  Still waiting... ($([int]($elapsed/60)) min). Delete '$pauseFile' to continue."
    }
} While (Test-Path $pauseFile)

Write-Output "Pause file deleted - resuming build."

# Re-stabilize WinRM after OSOT may have restored audit.exe to Winlogon
Write-Output "Re-checking Winlogon Userinit for audit.exe..."
$winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$userinit = (Get-ItemProperty $winlogon -ErrorAction SilentlyContinue).Userinit
if ($userinit -like "*audit*") {
    $clean = ($userinit -split "," | Where-Object { $_ -notlike "*audit*" }) -join ","
    Set-ItemProperty -Path $winlogon -Name "Userinit" -Value "$clean," -Force
    Write-Output "Removed audit.exe from Userinit - WinRM stabilized."
} else {
    Write-Output "Userinit clean - no audit.exe found."
}
winrm set winrm/config/service "@{AllowUnencrypted="true"}" 2>$null | Out-Null
winrm set winrm/config/service/auth "@{Basic="true"}" 2>$null | Out-Null

# Show log if it was produced
if (Test-Path $logFile) {
    Write-Output ""
    Write-Output "--- OSOT $Step log (last 20 lines) ---"
    Get-Content $logFile | Select-Object -Last 20
    Write-Output "---"
}

Write-Output ""
Write-Output "======================================================"
Write-Output "OSOT $Step phase complete - continuing build."
Write-Output "======================================================"
