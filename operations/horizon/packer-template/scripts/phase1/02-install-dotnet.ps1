<#
.SYNOPSIS
    02-install-dotnet.ps1
    Installs .NET Framework 3.5 via DISM.
    Falls back to local source on the Windows ISO if Windows Update is unavailable.
#>

$ErrorActionPreference = "Continue"
Write-Output "=== Installing .NET Framework ==="

# Try via Windows Update first
Write-Output "Installing .NET Framework 3.5 via DISM..."
$result = DISM /Online /Enable-Feature /FeatureName:NetFx3 /All /NoRestart 2>&1
$exitCode = $LASTEXITCODE
Write-Output "DISM exit code: $exitCode"

if ($exitCode -ne 0) {
    Write-Output "WARNING: .NET 3.5 install via Windows Update failed (code $exitCode). Trying local source..."

    # Try local source from Windows ISO (D:\sources\sxs or E:\sources\sxs)
    $sxsPaths = @("D:\sources\sxs", "E:\sources\sxs", "C:\Windows\Temp\sxs")
    $sxsFound = $sxsPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($sxsFound) {
        Write-Output "Using local source: $sxsFound"
        DISM /Online /Enable-Feature /FeatureName:NetFx3 /All /LimitAccess /Source:"$sxsFound" /NoRestart 2>&1
    } else {
        Write-Warning ".NET 3.5 local source not found. Skipping - may be installed later via Windows Update."
    }
}

# Check .NET 4.x
$netFx4Key = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ErrorAction SilentlyContinue
if ($netFx4Key) {
    Write-Output ".NET Framework 4.x Release key: $($netFx4Key.Release)"
    if ($netFx4Key.Release -ge 528040) {
        Write-Output ".NET Framework 4.8 or later is present."
    }
}

Write-Output "=== .NET Framework setup complete ==="
