<#
.SYNOPSIS
    03b-disable-copilot.ps1
    Checks for and disables/removes Microsoft Copilot for all users.
    Run during audit mode in Phase 1, before OSOT Optimize.

    Methods applied (belt-and-suspenders for 24H2 Enterprise):
      1. Remove Microsoft.Copilot AppX package for all users
      2. Remove provisioned Copilot package (prevents reinstall for new users)
      3. Set TurnOffWindowsCopilot policy via HKLM registry (machine-wide)
      4. Set TurnOffWindowsCopilot in default user profile (new user sessions)
      5. Hide Copilot taskbar button via default user registry
      6. Disable Copilot scheduled tasks and services where present

    NOTE: Windows updates may re-enable Copilot. For long-term enforcement
    in a Horizon environment, also configure via GPO/Intune after deployment.
#>

$ErrorActionPreference = "Continue"
Write-Output "=== Disabling Microsoft Copilot ==="

# -- 1. Remove Microsoft.Copilot AppX package for all users -------------------
Write-Output "Checking for Microsoft.Copilot AppX package..."

$copilotPackages = Get-AppxPackage -AllUsers | Where-Object { $_.Name -ilike "*Copilot*" }

if ($copilotPackages) {
    foreach ($pkg in $copilotPackages) {
        Write-Output "  Removing: $($pkg.PackageFullName)"
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction SilentlyContinue
            Write-Output "  Removed: $($pkg.Name)"
        } catch {
            Write-Warning "  Could not remove $($pkg.Name): $_"
        }
    }
} else {
    Write-Output "  Microsoft.Copilot AppX package not found (may not be installed)."
}

# -- 2. Remove provisioned Copilot package ------------------------------------
Write-Output "Checking for provisioned Copilot package..."

$provisionedCopilot = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -ilike "*Copilot*" }

if ($provisionedCopilot) {
    foreach ($pkg in $provisionedCopilot) {
        Write-Output "  Removing provisioned: $($pkg.DisplayName)"
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction SilentlyContinue | Out-Null
            Write-Output "  Provisioned package removed."
        } catch {
            Write-Warning "  Could not remove provisioned package: $_"
        }
    }
} else {
    Write-Output "  No provisioned Copilot package found."
}

# -- 3. Disable via HKLM policy (machine-wide, all users) ---------------------
Write-Output "Setting TurnOffWindowsCopilot machine policy..."

$copilotPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"
if (-not (Test-Path $copilotPolicyPath)) {
    New-Item -Path $copilotPolicyPath -Force | Out-Null
}
Set-ItemProperty -Path $copilotPolicyPath -Name "TurnOffWindowsCopilot" -Value 1 -Type DWord -Force
Write-Output "  HKLM TurnOffWindowsCopilot = 1"

# -- 4. Apply to default user profile (new Horizon desktop sessions) -----------
Write-Output "Applying Copilot disable to default user profile..."

$defaultUserHive = "C:\Users\Default\NTUSER.DAT"
if (Test-Path $defaultUserHive) {
    try {
        reg load "HKU\TempDefault" $defaultUserHive | Out-Null

        # TurnOffWindowsCopilot for new users
        $defaultCopilotPath = "HKU\TempDefault\Software\Policies\Microsoft\Windows\WindowsCopilot"
        reg add $defaultCopilotPath /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f | Out-Null

        # Hide Copilot taskbar button for new users
        $defaultTaskbarPath = "HKU\TempDefault\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        reg add $defaultTaskbarPath /v ShowCopilotButton /t REG_DWORD /d 0 /f | Out-Null

        reg unload "HKU\TempDefault" | Out-Null
        Write-Output "  Default user profile updated."
    } catch {
        Write-Warning "  Could not update default user profile: $_"
        # Force unload if still loaded
        reg unload "HKU\TempDefault" 2>$null | Out-Null
    }
} else {
    Write-Warning "  Default user hive not found at $defaultUserHive"
}

# -- 5. Hide Copilot taskbar button for current session ------------------------
Write-Output "Hiding Copilot taskbar button..."
$taskbarPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
Set-ItemProperty -Path $taskbarPath -Name "ShowCopilotButton" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
Write-Output "  ShowCopilotButton = 0"

# -- 6. Disable Copilot-related scheduled tasks --------------------------------
Write-Output "Disabling Copilot scheduled tasks..."
$copilotTasks = Get-ScheduledTask | Where-Object { $_.TaskName -ilike "*Copilot*" -or $_.TaskPath -ilike "*Copilot*" }
if ($copilotTasks) {
    foreach ($task in $copilotTasks) {
        try {
            Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue | Out-Null
            Write-Output "  Disabled task: $($task.TaskPath)$($task.TaskName)"
        } catch {
            Write-Warning "  Could not disable task $($task.TaskName): $_"
        }
    }
} else {
    Write-Output "  No Copilot scheduled tasks found."
}

# -- 7. Prevent silent reinstall via Windows Update ---------------------------
Write-Output "Preventing Copilot silent reinstall..."
$contentDeliveryPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
if (-not (Test-Path $contentDeliveryPath)) {
    New-Item -Path $contentDeliveryPath -Force | Out-Null
}
Set-ItemProperty -Path $contentDeliveryPath -Name "DisableWindowsConsumerFeatures" -Value 1 -Type DWord -Force
Set-ItemProperty -Path $contentDeliveryPath -Name "DisableCloudOptimizedContent" -Value 1 -Type DWord -Force
Write-Output "  DisableWindowsConsumerFeatures = 1"
Write-Output "  DisableCloudOptimizedContent = 1"

# -- Summary -------------------------------------------------------------------
Write-Output ""
Write-Output "=== Copilot disable summary ==="
$remaining = Get-AppxPackage -AllUsers | Where-Object { $_.Name -ilike "*Copilot*" }
if ($remaining) {
    Write-Warning "Copilot AppX package still present: $($remaining.PackageFullName)"
    Write-Warning "It may be re-removed by Windows Update or require a reboot to complete removal."
} else {
    Write-Output "Copilot AppX package: Not present"
}

$policyCheck = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Name "TurnOffWindowsCopilot" -ErrorAction SilentlyContinue
Write-Output "TurnOffWindowsCopilot (HKLM): $($policyCheck.TurnOffWindowsCopilot)"
Write-Output "=== Copilot disable complete ==="
