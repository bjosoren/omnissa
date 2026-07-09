<#
.SYNOPSIS
    05-cleanup-appx.ps1
    Removes unwanted AppX packages before OSOT Generalize (sysprep).
    Cleans up packages that would block sysprep or bloat the golden image.
#>

$ErrorActionPreference = "Continue"
Write-Output "=== AppX Cleanup (pre-Sysprep) ==="

# Packages to remove
$packagesToRemove = @(
    "Microsoft.XboxGamingOverlay",
    "Microsoft.Xbox.TCUI",
    "Microsoft.XboxIdentityProvider",
    "Microsoft.XboxSpeechToTextOverlay",
    "Microsoft.GamingApp",
    "Microsoft.BingWeather",
    "Microsoft.GetHelp",
    "Microsoft.MicrosoftSolitaireCollection",
    "Microsoft.WindowsFeedbackHub",
    "Microsoft.YourPhone",
    "Microsoft.ZuneMusic",
    "Microsoft.Todos",
    "Microsoft.PowerAutomateDesktop",
    "MicrosoftCorporationII.QuickAssist",
    "Clipchamp.Clipchamp",
    "Microsoft.WindowsCamera"
)

Write-Output "Removing provisioned AppX packages..."
foreach ($packageName in $packagesToRemove) {
    # Remove provisioned package (prevents reinstall for new users)
    $provisioned = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $packageName }
    if ($provisioned) {
        Write-Output "  Removing provisioned package: $packageName"
        Remove-AppxProvisionedPackage -Online -PackageName $provisioned.PackageName -ErrorAction SilentlyContinue | Out-Null
    }

    # Remove installed package for all users
    $installed = Get-AppxPackage -AllUsers | Where-Object { $_.Name -eq $packageName }
    if ($installed) {
        Write-Output "  Removing installed package: $packageName"
        Remove-AppxPackage -Package $installed.PackageFullName -AllUsers -ErrorAction SilentlyContinue
    }
}

# Clear AppX staging area
Write-Output "Clearing AppX staging area..."
Remove-Item "C:\Windows\WinSxS\AppxStaging\*" -Recurse -Force -ErrorAction SilentlyContinue

# Check for CleanupState entries that block sysprep
Write-Output "Checking for CleanupState entries that block sysprep..."
$cleanupKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned"
if (Test-Path $cleanupKey) {
    $entries = Get-ChildItem $cleanupKey -ErrorAction SilentlyContinue
    if ($entries) {
        Write-Output "Deprovisioned entries found (good):"
        $entries | ForEach-Object { Write-Output "  $($_.PSChildName)" }
    }
}

Write-Output "=== AppX cleanup complete ==="
